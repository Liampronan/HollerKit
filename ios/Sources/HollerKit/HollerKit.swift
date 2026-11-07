import Foundation
import SwiftUI

@MainActor
public enum HollerKit {
    public static let quests = HollerKitQuestState()

    private static var state = HollerKitState()
    static let presenterState = HollerKitPresenterState()
    private static let lifecycleMonitor = OutboxLifecycleMonitor {
        Task { @MainActor in
            if HollerKit.reconcileEnablement() {
                _ = await HollerKit.flushOutbox()
                await HollerKit.quests.refresh()
            }
        }
    }

    public static func configure(
        server: URL,
        auth: @escaping @Sendable () async throws -> String?,
        isEnabled: @escaping @Sendable () -> Bool = { true },
        invocation: HollerKitInvocation = [],
        inputMode: HollerKitInputMode = .textAndAudio,
        audio: HollerKitAudioConfiguration = .transcriptOnly(
            maxDuration: 60,
            requireOnDeviceTranscription: false
        ),
        metadata: @escaping @Sendable () -> [String: String] = { [:] },
        initialImages: @escaping @Sendable () -> [HollerKitAttachment] = { [] },
        captureBreadcrumbs: Bool = true,
        quests: HollerKitQuestsConfiguration? = nil
    ) {
        configure(HollerKitConfiguration(
            server: server,
            auth: auth,
            isEnabled: isEnabled,
            invocation: invocation,
            inputMode: inputMode,
            audio: audio,
            metadata: metadata,
            initialImages: initialImages,
            captureBreadcrumbs: captureBreadcrumbs,
            quests: quests
        ))
    }

    public static func configure(_ configuration: HollerKitConfiguration) {
        state.configuration = configuration
        let targetOutboxURL = (configuration.outboxDirectoryURL ?? OutboxStore.defaultOutboxDirectoryURL()).standardizedFileURL
        if state.outboxStore.rootDirectoryURL.standardizedFileURL != targetOutboxURL {
            state.outboxStore = OutboxStore(rootDirectoryURL: configuration.outboxDirectoryURL)
        }

        lifecycleMonitor.start()
        if reconcileEnablement() {
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
            Task { @MainActor in
                _ = await flushOutbox()
                await quests.refresh(using: configuration)
            }
        }
    }

    @discardableResult
    public static func reconcileEnablement() -> Bool {
        let enabled = state.configuration?.isEnabled() ?? false
        if presenterState.isRuntimeEnabled != enabled {
            presenterState.isRuntimeEnabled = enabled
        }
        if !enabled {
            quests.reset()
            state.breadcrumbs = BreadcrumbStore()
            if presenterState.isPresented {
                presenterState.isPresented = false
            }
            if presenterState.isQuestsPresented {
                presenterState.isQuestsPresented = false
            }
            if !presenterState.pendingAttachments.isEmpty {
                presenterState.pendingAttachments = []
            }
        }
        return enabled
    }

    public static var isEnabled: Bool {
        reconcileEnablement()
    }

    public static func breadcrumb(
        _ message: String,
        category: String? = nil,
        metadata: [String: String] = [:],
        date: Date = Date()
    ) {
        guard reconcileEnablement(), state.configuration?.captureBreadcrumbs == true else { return }
        state.breadcrumbs.append(.init(
            timestamp: date,
            category: category,
            message: message,
            metadata: metadata
        ))
    }

    public static func presentationView() -> some View {
        BugReportSheet(
            configuration: state.configuration,
            breadcrumbs: state.breadcrumbs,
            outboxStore: state.outboxStore,
            invocationAttachments: presenterState.pendingAttachments
        )
    }

    public static func questBoardView() -> some View {
        QuestBoardView(questState: quests)
    }

    public static func questsPresentationView() -> some View {
        questBoardView()
    }

    public static func presentBugReport(attachments: [HollerKitAttachment] = []) {
        guard reconcileEnablement() else { return }
        presenterState.pendingAttachments = attachments
        presenterState.isPresented = true
    }

    public static func present(attachments: [HollerKitAttachment] = []) {
        presentBugReport(attachments: attachments)
    }

    public static func presentQuests() {
        guard reconcileEnablement() else { return }
        presenterState.isQuestsPresented = true
    }

    @discardableResult
    public static func flushOutbox() async -> OutboxFlushResult {
        guard reconcileEnablement(), let configuration = state.configuration else {
            return OutboxFlushResult()
        }
        let client = APIClient(configuration: configuration)
        return await state.outboxStore.flush(using: client)
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
        guard reconcileEnablement() else { return [] }
        return state.configuration?.invocation ?? []
    }

    static var pendingPresentationAttachments: [HollerKitAttachment] {
        presenterState.pendingAttachments
    }

    static func clearPresentationAttachments() {
        presenterState.pendingAttachments = []
    }
}

@MainActor
private struct HollerKitState {
    var configuration: HollerKitConfiguration?
    var breadcrumbs = BreadcrumbStore()
    var outboxStore = OutboxStore()
}

@MainActor
final class HollerKitPresenterState: ObservableObject {
    @Published var isRuntimeEnabled = false
    @Published var isPresented = false
    @Published var isQuestsPresented = false
    var pendingAttachments: [HollerKitAttachment] = []
}
