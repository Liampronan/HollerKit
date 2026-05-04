import SwiftUI

public struct AudioOnlyCaptureView: View {
    public init() {}

    public var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Text("00:00")
                .font(.system(size: 48, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Button("Record") {}
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            Spacer()
        }
        .padding()
        .accessibilityIdentifier("HollerKitAudioOnlyCaptureView")
    }
}
