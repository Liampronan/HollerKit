import HollerKit
import SwiftUI

struct ContentView: View {
    @ObservedObject private var questState = HollerKit.quests
    @State private var didOpenReport = false

    var body: some View {
        NavigationStack {
            CheckoutMockScreen()
                .navigationTitle("Checkout")
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
