import HollerKit
import SwiftUI

@MainActor
final class DemoNavigationState: ObservableObject {
    enum Screen: String {
        case checkout
        case profile
    }

    static let shared = DemoNavigationState()
    @Published var currentScreen: Screen = .checkout
}

@main
struct HollerKitDemoApp: App {
    init() {
        let demoQuests: [QuestDefinition] = [
            QuestDefinition(
                id: "checkout-promo-math",
                title: "Apply promo RUN2026 and verify total",
                area: "checkout",
                setup: ["Ensure cart has Run Club Pro ($79.00)"],
                steps: [
                    "Inspect Subtotal ($79.00) and Promo RUN2026 (-$12.00)",
                    "Verify Tax ($7.43) and Total calculation",
                    "Tap Pay button"
                ],
                expect: [
                    "Total equals $74.43 (currently shows $91.42 bug in mock)"
                ],
                needs: ["backend"],
                record: .suggested,
                start: "hollerkitdemo://checkout",
                source: QuestManifestSource(pr: 42, added: "2026-11-07")
            ),
            QuestDefinition(
                id: "profile-avatar-upload",
                title: "Upload a profile avatar photo",
                area: "profile",
                steps: [
                    "Open Profile Upload screen",
                    "Observe upload progress indicator"
                ],
                expect: [
                    "Upload completes within 5 seconds without stalling at 94%"
                ],
                needs: ["device"],
                record: .optional,
                start: "hollerkitdemo://profile",
                source: QuestManifestSource(pr: 43, added: "2026-11-07")
            )
        ]

        HollerKit.configure(
            // Replace with your own HollerKit /v1 server URL and auth provider.
            server: URL(string: "https://example.supabase.co/functions/v1/hollerkit")!,
            auth: { "demo-tester-jwt" },
            isEnabled: { HollerKitEnvironment.isDebugOrTestFlight },
            invocation: [.shake, .screenshot],
            inputMode: .textAndAudio,
            metadata: { ["environment": "demo"] },
            initialImages: DemoScreenshotFactory.attachments,
            quests: .definitions(demoQuests) { route in
                switch route {
                case "hollerkitdemo://checkout":
                    DemoNavigationState.shared.currentScreen = .checkout
                    HollerKit.breadcrumb("Navigated via quest route \(route)", category: "navigation")
                case "hollerkitdemo://profile":
                    DemoNavigationState.shared.currentScreen = .profile
                    HollerKit.breadcrumb("Navigated via quest route \(route)", category: "navigation")
                default:
                    break
                }
            }
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
