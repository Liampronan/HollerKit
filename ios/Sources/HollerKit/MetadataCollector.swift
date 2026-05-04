import Foundation

#if canImport(UIKit)
import UIKit
#endif

public enum MetadataCollector {
    private static let launchDate = Date()

    @MainActor
    public static func collect(extra: [String: String] = [:]) -> [String: String] {
        var metadata = extra
        metadata["locale"] = Locale.current.identifier
        metadata["timeZone"] = TimeZone.current.identifier
        metadata["appVersion"] = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        metadata["appBuild"] = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        metadata["osVersion"] = ProcessInfo.processInfo.operatingSystemVersionString
        metadata["appUptimeSeconds"] = String(Int(Date().timeIntervalSince(launchDate)))

        #if canImport(UIKit)
        metadata["deviceModel"] = UIDevice.current.model
        metadata["screenSize"] = "\(Int(UIScreen.main.bounds.width))x\(Int(UIScreen.main.bounds.height))"
        metadata["orientation"] = UIDevice.current.orientation.description
        #endif

        return metadata
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
