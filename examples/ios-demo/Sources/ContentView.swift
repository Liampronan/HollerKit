import HollerKit
import SwiftUI

struct ContentView: View {
    private let questState = HollerKit.quests
    private let navigation = DemoNavigationState.shared
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
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("All Triggers (Shake, Strokes, Press)") {
                            HollerKit.setInvocation([
                                .shake: .bugReport,
                                .screenshot: .bugReport,
                                .stroke(.leftToCenter): .bugReport,
                                .stroke(.rightToCenter): .quests,
                                .twoFingerLongPress: .quests
                            ])
                        }
                        Button("Strokes Only") {
                            HollerKit.setInvocation([
                                .stroke(.leftToCenter): .bugReport,
                                .stroke(.rightToCenter): .quests
                            ])
                        }
                        Button("Shake Only") {
                            HollerKit.setInvocation([.shake: .bugReport])
                        }
                        Button("Invocations Off") {
                            HollerKit.setInvocation([])
                        }
                    } label: {
                        Image(systemName: "flask")
                    }
                    .accessibilityIdentifier("DemoExperimentsMenu")
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
