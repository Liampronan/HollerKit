import HollerKit
import SwiftUI

@main
struct HollerKitDemoApp: App {
    init() {
        HollerKit.configure(
            // Replace with your own HollerKit /v1 server URL and auth provider.
            server: URL(string: "https://example.supabase.co/functions/v1/hollerkit")!,
            auth: { "demo-tester-jwt" },
            isEnabled: { HollerKitEnvironment.isDebugOrTestFlight },
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
