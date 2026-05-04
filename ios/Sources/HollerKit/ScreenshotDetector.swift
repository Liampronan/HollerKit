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
        onScreenshot(HollerKitScreenCapture.currentScreenshotAttachment())
    }
}

enum HollerKitScreenCapture {
    @MainActor
    static func currentScreenshotAttachment() -> HollerKitAttachment? {
        var keyWindow: UIWindow?
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            if let window = windowScene.windows.first(where: { $0.isKeyWindow }) {
                keyWindow = window
                break
            }
        }

        guard let window = keyWindow else { return nil }

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
