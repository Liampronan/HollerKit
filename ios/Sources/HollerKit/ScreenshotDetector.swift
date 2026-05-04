import SwiftUI

#if canImport(UIKit)
import UIKit

struct ScreenshotDetector: UIViewControllerRepresentable {
    var onScreenshot: () -> Void

    func makeUIViewController(context: Context) -> ScreenshotDetectorViewController {
        ScreenshotDetectorViewController(onScreenshot: onScreenshot)
    }

    func updateUIViewController(_ uiViewController: ScreenshotDetectorViewController, context: Context) {
        uiViewController.onScreenshot = onScreenshot
    }
}

final class ScreenshotDetectorViewController: UIViewController {
    var onScreenshot: () -> Void
    private var observer: NSObjectProtocol?

    init(onScreenshot: @escaping () -> Void) {
        self.onScreenshot = onScreenshot
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        observer = NotificationCenter.default.addObserver(
            forName: UIApplication.userDidTakeScreenshotNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.onScreenshot()
        }
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}
#endif
