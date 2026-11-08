import HollerKit
import SwiftUI

struct ContentView: View {
    @ObservedObject private var questState = HollerKit.quests
    @ObservedObject private var navigation = DemoNavigationState.shared
    @State private var didOpenReport = false

    var body: some View {
        NavigationStack {
            Group {
                switch navigation.currentScreen {
                case .checkout:
                    CheckoutMockScreen()
                case .profile:
                    ProfileUploadMockScreen()
                }
            }
            .navigationTitle(navigation.currentScreen == .checkout ? "Checkout" : "Profile Upload")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Quests (\(questState.pendingCount))") {
                        HollerKit.presentQuests()
                    }
                    .accessibilityIdentifier("DemoQuestsButton")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Report") {
                        HollerKit.presentBugReport()
                    }
                    .accessibilityIdentifier("DemoReportButton")
                }
            }
        }
        .task {
            guard !didOpenReport else { return }
            didOpenReport = true
            guard !ProcessInfo.processInfo.arguments.contains("--skip-auto-report") else { return }
            try? await Task.sleep(for: .milliseconds(650))
            HollerKit.presentBugReport()
        }
    }
}
