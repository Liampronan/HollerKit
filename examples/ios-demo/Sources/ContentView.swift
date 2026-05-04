import HollerKit
import SwiftUI

struct ContentView: View {
    @State private var didOpenReport = false

    var body: some View {
        NavigationStack {
            CheckoutMockScreen()
                .navigationTitle("Checkout")
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Report") {
                            HollerKit.present()
                        }
                    }
                }
        }
        .task {
            guard !didOpenReport else { return }
            didOpenReport = true
            try? await Task.sleep(for: .milliseconds(650))
            HollerKit.present()
        }
    }
}
