import Foundation

public enum HollerKitEnvironment: Sendable {
    /// Returns `true` when running in a Debug build, Simulator, internal/ad-hoc provisioned build,
    /// or a TestFlight (`sandboxReceipt` / beta-reports-active) build.
    /// Returns `false` in production App Store builds so HollerKit remains completely dormant.
    public static var isDebugOrTestFlight: Bool {
        #if DEBUG
        let isDebugBuild = true
        #else
        let isDebugBuild = false
        #endif

        #if targetEnvironment(simulator)
        let isSimulator = true
        #else
        let isSimulator = false
        #endif

        return evaluateIsDebugOrTestFlight(
            isDebugBuild: isDebugBuild,
            isSimulator: isSimulator,
            receiptURL: Bundle.main.appStoreReceiptURL,
            mobileProvisionURL: Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
            fileExists: { FileManager.default.fileExists(atPath: $0.path) }
        )
    }

    public static func evaluateIsDebugOrTestFlight(
        isDebugBuild: Bool,
        isSimulator: Bool,
        receiptURL: URL?,
        mobileProvisionURL: URL? = nil,
        fileExists: (URL) -> Bool = { _ in true }
    ) -> Bool {
        if isDebugBuild || isSimulator {
            return true
        }
        if let mobileProvisionURL, fileExists(mobileProvisionURL) {
            if isNonAppStoreProvisioningProfile(at: mobileProvisionURL) {
                return true
            }
        }
        guard let receiptURL, receiptURL.lastPathComponent == "sandboxReceipt" else {
            return false
        }
        return fileExists(receiptURL)
    }

    private static func isNonAppStoreProvisioningProfile(at url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            // App Store distribution strips `embedded.mobileprovision`; its presence alone indicates
            // a development, ad-hoc, enterprise, or TestFlight/internal build when unreadable in tests.
            return true
        }
        let content = String(decoding: data, as: UTF8.self)
        if content.contains("beta-reports-active")
            || content.contains("get-task-allow")
            || content.contains("ProvisionedDevices")
            || content.contains("ProvisionsAllDevices") {
            return true
        }
        return true
    }
}

public struct HollerKitQuestsConfiguration: @unchecked Sendable {
    public enum ManifestSource: Sendable, Equatable {
        case bundled(String)
        case fileURL(URL)
    }

    public var manifestSource: ManifestSource
    public var bundle: Bundle
    public var routes: (@Sendable @MainActor (String) -> Void)?

    public init(
        manifestSource: ManifestSource = .bundled("hollerkit-quests"),
        bundle: Bundle = .main,
        routes: (@Sendable @MainActor (String) -> Void)? = nil
    ) {
        self.manifestSource = manifestSource
        self.bundle = bundle
        self.routes = routes
    }

    public static func bundled(
        _ resourceName: String = "hollerkit-quests",
        in bundle: Bundle = .main,
        routes: (@Sendable @MainActor (String) -> Void)? = nil
    ) -> HollerKitQuestsConfiguration {
        HollerKitQuestsConfiguration(
            manifestSource: .bundled(resourceName),
            bundle: bundle,
            routes: routes
        )
    }
}

public struct HollerKitConfiguration: Sendable {
    public var server: URL
    public var auth: @Sendable () async throws -> String?
    public var isEnabled: @Sendable () -> Bool
    public var invocation: HollerKitInvocation
    public var inputMode: HollerKitInputMode
    public var audio: HollerKitAudioConfiguration
    public var metadata: @Sendable () -> [String: String]
    public var initialImages: @Sendable () -> [HollerKitAttachment]
    public var captureBreadcrumbs: Bool
    public var quests: HollerKitQuestsConfiguration?
    public var urlSession: URLSession
    public var outboxDirectoryURL: URL?

    public init(
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
        quests: HollerKitQuestsConfiguration? = nil,
        urlSession: URLSession = .shared,
        outboxDirectoryURL: URL? = nil
    ) {
        self.server = server
        self.auth = auth
        self.isEnabled = isEnabled
        self.invocation = invocation
        self.inputMode = inputMode
        self.audio = audio
        self.metadata = metadata
        self.initialImages = initialImages
        self.captureBreadcrumbs = captureBreadcrumbs
        self.quests = quests
        self.urlSession = urlSession
        self.outboxDirectoryURL = outboxDirectoryURL
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
