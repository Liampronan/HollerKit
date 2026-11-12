import Foundation
import Observation
import SwiftUI

@MainActor
public enum HollerKit {
    public static let quests = HollerKitQuestState()

    private static var state = HollerKitState()
    static let presenterState = HollerKitPresenterState()
    private static let lifecycleMonitor = OutboxLifecycleMonitor {
        Task { @MainActor in
            let wasConfiguredWhileEnabled = state.configuredWhileEnabled
            guard HollerKit.reconcileEnablement() else { return }
            guard wasConfiguredWhileEnabled, state.activationTask == nil else { return }
            let generation = state.activationGeneration
            _ = await HollerKit.flushOutbox()
            guard !Task.isCancelled,
                  state.configuredWhileEnabled,
                  state.activationGeneration == generation else { return }
            await HollerKit.quests.refresh()
        }
    }

    /// Configures HollerKit with the given server URL, authentication provider, and runtime options.
    public static func configure(
        server: URL,
        auth: @escaping @Sendable () async throws -> String?,
        isEnabled: @escaping @Sendable () -> Bool = { true },
        invocation: HollerKitInvocation = [],
        invocationProvider: (@Sendable () -> HollerKitInvocation)? = nil,
        inputMode: HollerKitInputMode = .textAndAudio,
        audio: HollerKitAudioConfiguration = .transcriptOnly(
            maxDuration: 60,
            requireOnDeviceTranscription: false
        ),
        afterSend: HollerKitAfterSendBehavior = .stayOpen,
        metadata: @escaping @Sendable () -> [String: String] = { [:] },
        initialImages: @escaping @Sendable () -> [HollerKitAttachment] = { [] },
        captureBreadcrumbs: Bool = true,
        maxBreadcrumbs: Int = 500,
        quests: HollerKitQuestsConfiguration? = nil
    ) {
        configure(HollerKitConfiguration(
            server: server,
            auth: auth,
            isEnabled: isEnabled,
            invocation: invocation,
            invocationProvider: invocationProvider,
            inputMode: inputMode,
            audio: audio,
            afterSend: afterSend,
            metadata: metadata,
            initialImages: initialImages,
            captureBreadcrumbs: captureBreadcrumbs,
            maxBreadcrumbs: maxBreadcrumbs,
            quests: quests
        ))
    }

    /// Configures HollerKit with an explicit `HollerKitConfiguration` value and reconciles enablement.
    public static func configure(_ configuration: HollerKitConfiguration) {
        state.configuration = configuration
        state.breadcrumbs.capacity = configuration.maxBreadcrumbs
        state.invocationOverride = nil
        state.invocationProvider = configuration.invocationProvider
        presenterState.currentInvocation = configuration.invocation
        state.activationGeneration &+= 1
        state.activationTask?.cancel()
        state.activationTask = nil
        state.configuredWhileEnabled = false
        let targetOutboxURL = (configuration.outboxDirectoryURL ?? OutboxStore.defaultOutboxDirectoryURL()).standardizedFileURL
        if state.outboxStore.rootDirectoryURL.standardizedFileURL != targetOutboxURL {
            state.outboxStore = OutboxStore(rootDirectoryURL: configuration.outboxDirectoryURL)
        }

        lifecycleMonitor.start()
        reconcileEnablement()
    }

    /// Sets the active invocation trigger configuration at runtime without restarting HollerKit or rebuilding views.
    ///
    /// If an `invocationProvider` has been configured, that dynamic provider takes precedence over this override
    /// whenever enablement or active triggers are evaluated.
    public static func setInvocation(_ invocation: HollerKitInvocation) {
        state.invocationOverride = invocation
        state.configuration?.invocation = invocation
        reconcileEnablement()
        breadcrumb("Updated invocation triggers at runtime", category: "invocation")
    }

    /// Sets a dynamic invocation provider closure that is re-evaluated on reconcileEnablement or trigger checks.
    public static func setInvocationProvider(_ provider: (@Sendable () -> HollerKitInvocation)?) {
        state.invocationProvider = provider
        reconcileEnablement()
    }

    /// Re-evaluates the `isEnabled` closure on the active configuration and activates or resets runtime state on transitions.
    @discardableResult
    public static func reconcileEnablement() -> Bool {
        let enabled = state.configuration?.isEnabled() ?? false
        if presenterState.isRuntimeEnabled != enabled {
            presenterState.isRuntimeEnabled = enabled
        }
        let activeInvocation = enabled ? currentInvocation : []
        if presenterState.currentInvocation != activeInvocation {
            presenterState.currentInvocation = activeInvocation
        }
        if enabled {
            if !state.configuredWhileEnabled, let configuration = state.configuration {
                state.configuredWhileEnabled = true
                activateRuntimeConfiguration(configuration)
            }
        } else {
            state.activationGeneration &+= 1
            state.activationTask?.cancel()
            state.activationTask = nil
            state.configuredWhileEnabled = false
            quests.reset()
            state.breadcrumbs = BreadcrumbStore(capacity: state.configuration?.maxBreadcrumbs ?? 500)
            presenterState.presentQuestsAfterBugReportDismiss = false
            if presenterState.isPresented {
                presenterState.isPresented = false
                presenterState.handleSheetDismissed(configuration: nil)
            } else if !presenterState.pendingAttachments.isEmpty {
                presenterState.pendingAttachments = []
            }
            if presenterState.isQuestsPresented {
                presenterState.isQuestsPresented = false
            }
        }
        return enabled
    }

    /// Configures local quest state and schedules a single initial outbox flush and quest refresh for the current activation generation.
    private static func activateRuntimeConfiguration(_ configuration: HollerKitConfiguration) {
        state.activationGeneration &+= 1
        state.activationTask?.cancel()
        let generation = state.activationGeneration

        let metadata = MetadataCollector.collect(extra: configuration.metadata())
        let build = MetadataCollector.currentBuild(from: metadata)
        let cacheDir = configuration.outboxDirectoryURL?.deletingLastPathComponent()
            .appendingPathComponent("QuestCache", isDirectory: true)
        quests.configure(
            questsConfiguration: configuration.quests,
            build: build,
            cacheDirectoryURL: cacheDir,
            serverURL: configuration.server
        )
        state.activationTask = Task { @MainActor in
            defer {
                if state.activationGeneration == generation {
                    state.activationTask = nil
                }
            }
            guard !Task.isCancelled,
                  state.configuredWhileEnabled,
                  state.activationGeneration == generation else { return }
            let client = APIClient(configuration: configuration)
            let flushResult = await state.outboxStore.flush(using: client)
            if !flushResult.rejectedErrors.isEmpty {
                quests.rollbackRejectedFeedbackIds(Set(flushResult.rejectedErrors.keys))
            }
            guard !Task.isCancelled,
                  state.configuredWhileEnabled,
                  state.activationGeneration == generation,
                  configuration.isEnabled() else { return }
            await quests.refresh(using: configuration)
        }
    }

    public static var isEnabled: Bool {
        reconcileEnablement()
    }

    /// Begins a timed span for measuring an operation or render step.
    ///
    /// Spans are gated by `isEnabled()`. When the returned span is ended via `span.end(...)`,
    /// one breadcrumb event is recorded with the elapsed duration in milliseconds (`durationMs`).
    @discardableResult
    public static func begin(
        _ name: String,
        category: String? = nil,
        fields: [String: HollerKitFieldValue] = [:],
        metadata: [String: String] = [:],
        startDate: Date = Date()
    ) -> HollerKitSpan {
        let enabled = reconcileEnablement() && state.configuration?.captureBreadcrumbs == true
        let generation = state.activationGeneration
        return HollerKitSpan(
            name: name,
            category: category,
            fields: fields,
            metadata: metadata,
            startDate: startDate,
            isEnabled: enabled,
            generation: generation
        )
    }

    static func recordSpanBreadcrumb(
        name: String,
        category: String?,
        fields: [String: HollerKitFieldValue],
        metadata: [String: String],
        durationMs: Double,
        startDate: Date,
        endDate: Date,
        generation: UInt64
    ) {
        guard reconcileEnablement(),
              state.configuration?.captureBreadcrumbs == true,
              generation == state.activationGeneration else { return }
        state.breadcrumbs.append(.init(
            timestamp: endDate,
            category: category,
            message: name,
            fields: fields,
            metadata: metadata,
            durationMs: durationMs,
            startDate: startDate
        ))
    }

    /// Records a structured log event with typed fields, string metadata, and optional timing.
    public static func breadcrumb(
        _ message: String,
        category: String? = nil,
        fields: [String: HollerKitFieldValue] = [:],
        metadata: [String: String] = [:],
        durationMs: Double? = nil,
        startOffsetSeconds: Double? = nil,
        date: Date = Date()
    ) {
        guard reconcileEnablement(), state.configuration?.captureBreadcrumbs == true else { return }
        state.breadcrumbs.append(.init(
            timestamp: date,
            category: category,
            message: message,
            fields: fields,
            metadata: metadata,
            durationMs: durationMs,
            startOffsetSeconds: startOffsetSeconds
        ))
    }

    /// Records a simple point breadcrumb with string metadata.
    public static func breadcrumb(
        _ message: String,
        category: String? = nil,
        metadata: [String: String] = [:],
        date: Date = Date()
    ) {
        breadcrumb(
            message,
            category: category,
            fields: [:],
            metadata: metadata,
            durationMs: nil,
            startOffsetSeconds: nil,
            date: date
        )
    }

    public static func presentationView() -> some View {
        BugReportSheet(
            configuration: state.configuration,
            breadcrumbs: state.breadcrumbs,
            outboxStore: state.outboxStore,
            invocationAttachments: presenterState.pendingAttachments,
            draft: presenterState.activeDraft,
            presentationId: presenterState.presentationId
        )
        .id(presenterState.presentationId)
    }

    public static func questBoardView() -> some View {
        QuestBoardView(questState: quests)
    }

    public static func questsPresentationView() -> some View {
        questBoardView()
    }

    public static func presentBugReport(
        attachments: [HollerKitAttachment] = [],
        trigger: HollerKitTrigger? = nil
    ) {
        guard reconcileEnablement() else { return }
        let triggerName = trigger?.description ?? "manual"
        breadcrumb("Invoked bug report via \(triggerName)", category: "invocation")
        presenterState.presentBugReport(
            configuration: state.configuration,
            attachments: attachments,
            triggerName: triggerName
        )
    }

    public static func present(
        attachments: [HollerKitAttachment] = [],
        trigger: HollerKitTrigger? = nil
    ) {
        presentBugReport(attachments: attachments, trigger: trigger)
    }

    public static func presentQuests(trigger: HollerKitTrigger? = nil) {
        guard reconcileEnablement() else { return }
        let triggerName = trigger?.description ?? "manual"
        breadcrumb("Invoked quests via \(triggerName)", category: "invocation")
        presenterState.isQuestsPresented = true
    }

    static func requestQuestsAfterBugReportDismiss() {
        guard reconcileEnablement() else { return }
        breadcrumb("Invoked quests via bugReport", category: "invocation")
        if presenterState.isPresented {
            presenterState.presentQuestsAfterBugReportDismiss = true
            presenterState.isPresented = false
        } else {
            presenterState.isQuestsPresented = true
        }
    }

    @discardableResult
    public static func flushOutbox() async -> OutboxFlushResult {
        guard reconcileEnablement(), let configuration = state.configuration else {
            return OutboxFlushResult()
        }
        let client = APIClient(configuration: configuration)
        let result = await state.outboxStore.flush(using: client)
        if !result.rejectedErrors.isEmpty {
            quests.rollbackRejectedFeedbackIds(Set(result.rejectedErrors.keys))
        }
        return result
    }

    public static func submitReport(
        _ payload: HollerKitReportPayload
    ) async throws -> OutboxSubmissionOutcome {
        guard reconcileEnablement(), let configuration = state.configuration else {
            throw HollerKitAPIError.missingAuthToken
        }
        let client = APIClient(configuration: configuration)
        let (request, attachments) = payload.toFeedbackSubmission()
        return try await state.outboxStore.submit(
            request: request,
            attachments: attachments,
            using: client
        )
    }

    public static var isPresentationRequested: Bool {
        presenterState.isPresented
    }

    public static var isQuestsPresentationRequested: Bool {
        presenterState.isQuestsPresented
    }

    static func beginQuestBreadcrumbs(startedAt: Date) {
        state.breadcrumbs.beginQuestRun(startedAt: startedAt)
    }

    static func endQuestBreadcrumbs() {
        state.breadcrumbs.endQuestRun()
    }

    static var currentConfiguration: HollerKitConfiguration? {
        state.configuration
    }

    static var currentBreadcrumbs: BreadcrumbStore {
        state.breadcrumbs
    }

    static var currentOutboxStore: OutboxStore {
        state.outboxStore
    }

    static var currentInvocation: HollerKitInvocation {
        guard state.configuration?.isEnabled() ?? false else { return [] }
        if let provider = state.invocationProvider {
            return provider()
        }
        if let override = state.invocationOverride {
            return override
        }
        return state.configuration?.invocation ?? []
    }

    static var pendingPresentationAttachments: [HollerKitAttachment] {
        presenterState.pendingAttachments
    }

    static var currentBugReportDraft: BugReportDraft {
        presenterState.activeDraft
    }

    static var currentPresentationId: UUID {
        presenterState.presentationId
    }

    static func clearPresentationAttachments() {
        presenterState.handleSheetDismissed(configuration: state.configuration)
    }
}

@MainActor
private struct HollerKitState {
    var configuration: HollerKitConfiguration?
    var invocationOverride: HollerKitInvocation?
    var invocationProvider: (@Sendable () -> HollerKitInvocation)?
    var configuredWhileEnabled = false
    var activationGeneration: UInt64 = 0
    var activationTask: Task<Void, Never>?
    var breadcrumbs = BreadcrumbStore()
    var outboxStore = OutboxStore()
}

@Observable
@MainActor
final class HollerKitPresenterState {
    var isRuntimeEnabled = false
    var isPresented = false
    var isQuestsPresented = false
    var presentQuestsAfterBugReportDismiss = false
    var currentInvocation: HollerKitInvocation = []
    var presentationId = UUID()
    var activeDraft = BugReportDraft()
    var pendingAttachments: [HollerKitAttachment] = []

    /// Resets the active draft and presents the bug report sheet with fresh state.
    func presentBugReport(
        configuration: HollerKitConfiguration?,
        attachments: [HollerKitAttachment],
        triggerName: String = "manual"
    ) {
        activeDraft.cancelCapture()
        activeDraft.cleanupTempFiles()
        presentQuestsAfterBugReportDismiss = false
        pendingAttachments = attachments
        presentationId = UUID()
        activeDraft = BugReportDraft(
            configuration: configuration,
            invocationAttachments: attachments,
            invokingTrigger: triggerName
        )
        isPresented = true
    }

    /// Cleans up attachments and resets the draft when the bug report sheet is dismissed.
    func handleSheetDismissed(configuration: HollerKitConfiguration?) {
        activeDraft.cancelCapture()
        activeDraft.cleanupTempFiles()
        pendingAttachments = []
        presentationId = UUID()
        let enabledConfiguration = (configuration?.isEnabled() == true) ? configuration : nil
        activeDraft = BugReportDraft(
            configuration: enabledConfiguration,
            invocationAttachments: []
        )
        if presentQuestsAfterBugReportDismiss {
            presentQuestsAfterBugReportDismiss = false
            if isRuntimeEnabled && enabledConfiguration != nil {
                isQuestsPresented = true
            }
        }
    }
}
