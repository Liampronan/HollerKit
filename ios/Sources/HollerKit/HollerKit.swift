import Foundation
import SwiftUI

@MainActor
public enum HollerKit {
    private static var state = HollerKitState()

    public static func configure(
        endpoint: URL,
        appSecret: String,
        invocation: HollerKitInvocation = [],
        inputMode: HollerKitInputMode = .textAndAudio,
        audio: HollerKitAudioConfiguration = .transcriptAndAttachment(
            maxDuration: 60,
            requireOnDeviceTranscription: false,
            maxAttachmentBytes: 2_000_000
        ),
        userID: @escaping @Sendable () -> String? = { nil },
        metadata: @escaping @Sendable () -> [String: String] = { [:] },
        captureBreadcrumbs: Bool = true
    ) {
        state.configuration = HollerKitConfiguration(
            endpoint: endpoint,
            appSecret: appSecret,
            invocation: invocation,
            inputMode: inputMode,
            audio: audio,
            userID: userID,
            metadata: metadata,
            captureBreadcrumbs: captureBreadcrumbs
        )
    }

    public static func configure(_ configuration: HollerKitConfiguration) {
        state.configuration = configuration
    }

    public static func breadcrumb(
        _ message: String,
        category: String? = nil,
        metadata: [String: String] = [:],
        date: Date = Date()
    ) {
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
            breadcrumbs: state.breadcrumbs
        )
    }

    public static func present() {
        state.isPresentationRequested = true
    }

    public static var isPresentationRequested: Bool {
        state.isPresentationRequested
    }
}

@MainActor
private struct HollerKitState {
    var configuration: HollerKitConfiguration?
    var breadcrumbs = BreadcrumbStore()
    var isPresentationRequested = false
}
