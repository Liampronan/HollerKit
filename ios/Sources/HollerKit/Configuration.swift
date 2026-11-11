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
        case definitions([QuestDefinition])
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

    public static func fileURL(
        _ url: URL,
        routes: (@Sendable @MainActor (String) -> Void)? = nil
    ) -> HollerKitQuestsConfiguration {
        HollerKitQuestsConfiguration(
            manifestSource: .fileURL(url),
            routes: routes
        )
    }

    public static func definitions(
        _ quests: [QuestDefinition],
        routes: (@Sendable @MainActor (String) -> Void)? = nil
    ) -> HollerKitQuestsConfiguration {
        HollerKitQuestsConfiguration(
            manifestSource: .definitions(quests),
            routes: routes
        )
    }
}

public struct HollerKitConfiguration: Sendable {
    public var server: URL
    public var auth: @Sendable () async throws -> String?
    public var isEnabled: @Sendable () -> Bool
    public var invocation: HollerKitInvocation
    public var invocationProvider: (@Sendable () -> HollerKitInvocation)?
    public var inputMode: HollerKitInputMode
    public var audio: HollerKitAudioConfiguration
    public var afterSend: HollerKitAfterSendBehavior
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
        quests: HollerKitQuestsConfiguration? = nil,
        urlSession: URLSession = .shared,
        outboxDirectoryURL: URL? = nil
    ) {
        self.server = server
        self.auth = auth
        self.isEnabled = isEnabled
        self.invocation = invocation
        self.invocationProvider = invocationProvider
        self.inputMode = inputMode
        self.audio = audio
        self.afterSend = afterSend
        self.metadata = metadata
        self.initialImages = initialImages
        self.captureBreadcrumbs = captureBreadcrumbs
        self.quests = quests
        self.urlSession = urlSession
        self.outboxDirectoryURL = outboxDirectoryURL
    }
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

/// Governs whether the bug report sheet remains presented after a report is sent or auto-dismisses.
public enum HollerKitAfterSendBehavior: Sendable, Equatable {
    /// Keeps the bug report sheet open after a successful submission, briefly displaying the sent confirmation
    /// before resetting to a blank draft for subsequent reports.
    case stayOpen(resetDelay: TimeInterval = 1.2)

    /// Automatically dismisses the bug report sheet after a successful submission once the confirmation delay elapses.
    case close(delay: TimeInterval = 1.2)

    public static let stayOpen = HollerKitAfterSendBehavior.stayOpen()
    public static let close = HollerKitAfterSendBehavior.close()

    /// Returns `true` if the sheet stays open after a successful send.
    public var isStayOpen: Bool {
        if case .stayOpen = self { return true }
        return false
    }

    /// Returns the delay in seconds before the sheet resets or closes.
    public var delay: TimeInterval {
        switch self {
        case .stayOpen(let resetDelay):
            return resetDelay
        case .close(let delay):
            return delay
        }
    }
}
