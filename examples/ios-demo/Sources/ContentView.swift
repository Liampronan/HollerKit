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
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Report") {
                        HollerKit.presentBugReport()
                    }
                }
            }
        }
        .task {
            guard !didOpenReport else { return }
            didOpenReport = true
            try? await Task.sleep(for: .milliseconds(650))
            HollerKit.presentBugReport()
        }
    }
}
