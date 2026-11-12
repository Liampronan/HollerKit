import SwiftUI

#if canImport(UIKit)
import UIKit

struct ScreenshotDetector: UIViewControllerRepresentable {
    var onScreenshot: (HollerKitAttachment?) -> Void

    func makeUIViewController(context: Context) -> ScreenshotDetectorViewController {
        ScreenshotDetectorViewController(onScreenshot: onScreenshot)
    }

    func updateUIViewController(_ uiViewController: ScreenshotDetectorViewController, context: Context) {
        uiViewController.onScreenshot = onScreenshot
    }
}

final class ScreenshotDetectorViewController: UIViewController {
    var onScreenshot: (HollerKitAttachment?) -> Void

    init(onScreenshot: @escaping (HollerKitAttachment?) -> Void) {
        self.onScreenshot = onScreenshot
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(userDidTakeScreenshot),
            name: UIApplication.userDidTakeScreenshotNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc @MainActor private func userDidTakeScreenshot() {
        let preferredScene = viewIfLoaded?.window?.windowScene
        onScreenshot(HollerKitScreenCapture.currentScreenshotAttachment(preferredScene: preferredScene))
    }
}

enum HollerKitScreenCapture {
    @MainActor
    private static func isEligibleCaptureWindow(_ window: UIWindow) -> Bool {
        !(window is PassthroughOverlayWindow)
            && !window.isHidden
            && window.alpha > 0
            && window.bounds.width > 0
            && window.bounds.height > 0
    }

    @MainActor
    private static func preferredNonKeyWindow(in windows: [UIWindow]) -> UIWindow? {
        windows.first(where: { $0.windowLevel == .normal }) ?? windows.first
    }

    @MainActor
    static func selectCaptureWindow(
        preferredScene: UIWindowScene? = nil,
        connectedScenes: [UIWindowScene] = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    ) -> UIWindow? {
        if let preferredScene {
            let eligibleWindows = preferredScene.windows.filter(isEligibleCaptureWindow)
            if let keyWindow = eligibleWindows.first(where: \.isKeyWindow) {
                return keyWindow
            }
            if let normalWindow = preferredNonKeyWindow(in: eligibleWindows) {
                return normalWindow
            }
        }

        let activeScenes = connectedScenes.filter { $0.activationState == .foregroundActive }
        let inactiveScenes = connectedScenes.filter { $0.activationState != .foregroundActive }

        for windowScene in activeScenes {
            let eligibleWindows = windowScene.windows.filter(isEligibleCaptureWindow)
            if let keyWindow = eligibleWindows.first(where: \.isKeyWindow) {
                return keyWindow
            }
        }

        for windowScene in activeScenes {
            let eligibleWindows = windowScene.windows.filter(isEligibleCaptureWindow)
            if let normalWindow = preferredNonKeyWindow(in: eligibleWindows) {
                return normalWindow
            }
        }

        for windowScene in inactiveScenes {
            let eligibleWindows = windowScene.windows.filter(isEligibleCaptureWindow)
            if let keyWindow = eligibleWindows.first(where: \.isKeyWindow) {
                return keyWindow
            }
        }

        for windowScene in inactiveScenes {
            let eligibleWindows = windowScene.windows.filter(isEligibleCaptureWindow)
            if let normalWindow = preferredNonKeyWindow(in: eligibleWindows) {
                return normalWindow
            }
        }

        return nil
    }

    @MainActor
    static func currentScreenshotAttachment(preferredScene: UIWindowScene? = nil) -> HollerKitAttachment? {
        guard let window = selectCaptureWindow(preferredScene: preferredScene) else { return nil }

        let format = UIGraphicsImageRendererFormat()
        format.scale = window.screen.scale
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds, format: format)
        let image = renderer.image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
        }

        guard let data = image.pngData() else { return nil }
        return HollerKitAttachment(
            filename: "screenshot-\(Int(Date().timeIntervalSince1970)).png",
            mimeType: "image/png",
            data: data
        )
    }
}
#endif
