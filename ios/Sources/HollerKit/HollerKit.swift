import Foundation
import SwiftUI

@MainActor
public enum HollerKit {
    private static var state = HollerKitState()
    static let presenterState = HollerKitPresenterState()

    public static func configure(
        endpoint: URL,
        appSecret: String,
        invocation: HollerKitInvocation = [],
        inputMode: HollerKitInputMode = .textAndAudio,
        audio: HollerKitAudioConfiguration = .transcriptOnly(
            maxDuration: 60,
            requireOnDeviceTranscription: false
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
        presenterState.isPresented = true
    }

    public static var isPresentationRequested: Bool {
        presenterState.isPresented
    }

    static var currentInvocation: HollerKitInvocation {
        state.configuration?.invocation ?? []
    }
}

@MainActor
private struct HollerKitState {
    var configuration: HollerKitConfiguration?
    var breadcrumbs = BreadcrumbStore()
}

@MainActor
final class HollerKitPresenterState: ObservableObject {
    @Published var isPresented = false
}
