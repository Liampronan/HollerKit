import Foundation

public struct HollerKitConfiguration: Sendable {
    public var endpoint: URL
    public var appSecret: String
    public var invocation: HollerKitInvocation
    public var inputMode: HollerKitInputMode
    public var audio: HollerKitAudioConfiguration
    public var userID: @Sendable () -> String?
    public var metadata: @Sendable () -> [String: String]
    public var initialImages: @Sendable () -> [HollerKitAttachment]
    public var captureBreadcrumbs: Bool

    public init(
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
        initialImages: @escaping @Sendable () -> [HollerKitAttachment] = { [] },
        captureBreadcrumbs: Bool = true
    ) {
        self.endpoint = endpoint
        self.appSecret = appSecret
        self.invocation = invocation
        self.inputMode = inputMode
        self.audio = audio
        self.userID = userID
        self.metadata = metadata
        self.initialImages = initialImages
        self.captureBreadcrumbs = captureBreadcrumbs
    }
}

public struct HollerKitInvocation: OptionSet, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let shake = HollerKitInvocation(rawValue: 1 << 0)
    public static let screenshot = HollerKitInvocation(rawValue: 1 << 1)
}

public enum HollerKitInputMode: Sendable, Equatable {
    case textAndAudio
    case textOnly
    case audioOnly(presentation: AudioOnlyPresentation = .fullScreen, maxDuration: TimeInterval = 60)

    public var wireValue: String {
        switch self {
        case .textAndAudio:
            return "text-and-audio"
        case .textOnly:
            return "text-only"
        case .audioOnly:
            return "audio-only"
        }
    }
}

public enum AudioOnlyPresentation: Sendable, Equatable {
    case fullScreen
}

public enum HollerKitAudioConfiguration: Sendable, Equatable {
    case off
    case transcriptOnly(maxDuration: TimeInterval, requireOnDeviceTranscription: Bool)

    public var isEnabled: Bool {
        if case .off = self { return false }
        return true
    }

    var maxDuration: TimeInterval {
        switch self {
        case .off:
            return 0
        case .transcriptOnly(let maxDuration, _):
            return maxDuration
        }
    }

    var requiresOnDeviceTranscription: Bool {
        switch self {
        case .off:
            return false
        case .transcriptOnly(_, let requireOnDeviceTranscription):
            return requireOnDeviceTranscription
        }
    }
}
