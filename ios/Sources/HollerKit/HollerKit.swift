import Foundation
import SwiftUI

@MainActor
public enum HollerKit {
    private static var state = HollerKitState()
    static let presenterState = HollerKitPresenterState()
    private static let lifecycleMonitor = OutboxLifecycleMonitor {
        Task { @MainActor in
            _ = await HollerKit.flushOutbox()
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
        state.outboxStore = OutboxStore(rootDirectoryURL: configuration.outboxDirectoryURL)

        if configuration.isEnabled() {
            lifecycleMonitor.start()
            Task { @MainActor in
                _ = await flushOutbox()
            }
        } else {
            lifecycleMonitor.stop()
            state.breadcrumbs = BreadcrumbStore()
            presenterState.isPresented = false
            presenterState.isQuestsPresented = false
            presenterState.pendingAttachments = []
        }
    }

    public static var isEnabled: Bool {
        state.configuration?.isEnabled() ?? false
    }

    public static func breadcrumb(
        _ message: String,
        category: String? = nil,
        metadata: [String: String] = [:],
        date: Date = Date()
    ) {
        guard isEnabled, state.configuration?.captureBreadcrumbs == true else { return }
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

    public static func presentBugReport(attachments: [HollerKitAttachment] = []) {
        guard isEnabled else { return }
        presenterState.pendingAttachments = attachments
        presenterState.isPresented = true
    }

    public static func present(attachments: [HollerKitAttachment] = []) {
        presentBugReport(attachments: attachments)
    }

    public static func presentQuests() {
        guard isEnabled else { return }
        presenterState.isQuestsPresented = true
    }

    @discardableResult
    public static func flushOutbox() async -> OutboxFlushResult {
        guard isEnabled, let configuration = state.configuration else {
            return OutboxFlushResult()
        }
        let client = APIClient(configuration: configuration)
        return await state.outboxStore.flush(using: client)
    }

    public static func submitReport(
        _ payload: HollerKitReportPayload
    ) async throws -> OutboxSubmissionOutcome {
        guard isEnabled, let configuration = state.configuration else {
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
        guard isEnabled else { return [] }
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
    @Published var isPresented = false
    @Published var isQuestsPresented = false
    var pendingAttachments: [HollerKitAttachment] = []
}
