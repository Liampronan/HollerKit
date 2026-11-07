import Foundation

#if canImport(UIKit)
import UIKit
#endif

public enum MetadataCollector {
    private static let launchDate = Date()

    @MainActor
    public static func collect(extra: [String: String] = [:]) -> [String: String] {
        var metadata: [String: String] = [:]
        metadata["locale"] = Locale.current.identifier
        metadata["timeZone"] = TimeZone.current.identifier
        if let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String, !appVersion.isEmpty {
            metadata["appVersion"] = appVersion
        }
        if let appBuild = Bundle.main.infoDictionary?["CFBundleVersion"] as? String, !appBuild.isEmpty {
            metadata["appBuild"] = appBuild
        }
        metadata["osVersion"] = ProcessInfo.processInfo.operatingSystemVersionString
        metadata["appUptimeSeconds"] = String(Int(Date().timeIntervalSince(launchDate)))

        #if canImport(UIKit)
        metadata["deviceModel"] = UIDevice.current.model
        metadata["screenSize"] = "\(Int(UIScreen.main.bounds.width))x\(Int(UIScreen.main.bounds.height))"
        metadata["orientation"] = UIDevice.current.orientation.description
        #endif

        for (key, value) in extra {
            metadata[key] = value
        }

        return metadata
    }

    public static func currentBuild(from metadata: [String: String] = [:]) -> String {
        if let build = metadata["appBuild"]?.trimmingCharacters(in: .whitespacesAndNewlines), !build.isEmpty {
            return build
        }
        if let bundleBuild = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !bundleBuild.isEmpty {
            return bundleBuild
        }
        return "1"
    }

    public static func currentAppVersion(from metadata: [String: String] = [:]) -> String? {
        if let version = metadata["appVersion"]?.trimmingCharacters(in: .whitespacesAndNewlines), !version.isEmpty {
            return version
        }
        if let bundleVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !bundleVersion.isEmpty {
            return bundleVersion
        }
        return nil
    }
}

#if canImport(UIKit)
private extension UIDeviceOrientation {
    var description: String {
        switch self {
        case .portrait:
            return "portrait"
        case .portraitUpsideDown:
            return "portrait-upside-down"
        case .landscapeLeft:
            return "landscape-left"
        case .landscapeRight:
            return "landscape-right"
        case .faceUp:
            return "face-up"
        case .faceDown:
            return "face-down"
        default:
            return "unknown"
        }
    }
}
#endif
