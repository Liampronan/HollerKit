import HollerKit
import SwiftUI

@main
struct HollerKitDemoApp: App {
    init() {
        HollerKit.configure(
            // Replace with your own endpoint and secret to actually post reports.
            endpoint: URL(string: "https://example.com/bug-report")!,
            appSecret: "demo-secret",
            invocation: [.shake, .screenshot],
            inputMode: .textAndAudio,
            metadata: { ["environment": "demo"] },
            initialImages: DemoScreenshotFactory.attachments
        )

        HollerKit.breadcrumb("Opened demo app", category: "lifecycle")
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .hollerKitPresenter()
        }
    }
}
