import HollerKit
import SwiftUI
import UIKit

struct CheckoutMockScreen: View {
    @State private var payTapCount = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Run Club Pro")
                    .font(.largeTitle.bold())
                Text("Checkout")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 14) {
                CheckoutRow(title: "Subtotal", value: "$79.00")
                CheckoutRow(title: "Promo RUN2026", value: "-$12.00", valueColor: .green)
                CheckoutRow(title: "Tax", value: "$7.43")
                Divider()
                CheckoutRow(title: "Total", value: "$91.42", valueColor: .red, isEmphasized: true)
            }
            .padding(18)
            .background(.background)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(.quaternary, lineWidth: 1)
            }

            Button("Pay $91.42") {
                payTapCount += 1
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .accessibilityIdentifier("DemoPayButton")
            .accessibilityValue("\(payTapCount)")

            Spacer()
        }
        .padding(24)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
    }
}

struct ProfileUploadMockScreen: View {
    var body: some View {
        VStack(spacing: 22) {
            Circle()
                .fill(Color.blue.opacity(0.18))
                .frame(width: 112, height: 112)
                .overlay {
                    Image(systemName: "person.crop.circle")
                        .font(.system(size: 54))
                        .foregroundStyle(.blue)
                }

            Text("Avatar upload")
                .font(.title2.bold())

            ProgressView()
                .controlSize(.large)

            Text("Stuck at 94% for 2 minutes")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.red)

            Spacer()
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemGroupedBackground))
    }
}

private struct CheckoutRow: View {
    var title: String
    var value: String
    var valueColor: Color = .primary
    var isEmphasized = false

    var body: some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .fontWeight(isEmphasized ? .bold : .medium)
                .foregroundStyle(valueColor)
        }
        .font(isEmphasized ? .title3 : .body)
    }
}

enum DemoScreenshotFactory {
    static func attachments() -> [HollerKitAttachment] {
        MainActor.assumeIsolated {
            [
                snapshot(name: "checkout-screen.png", view: CheckoutMockScreen()),
                snapshot(name: "profile-upload.png", view: ProfileUploadMockScreen())
            ]
        }
    }

    @MainActor
    private static func snapshot<Content: View>(name: String, view: Content) -> HollerKitAttachment {
        let size = CGSize(width: 390, height: 844)
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height))
        renderer.scale = UIScreen.main.scale
        let image = renderer.uiImage ?? UIImage()

        return HollerKitAttachment(
            filename: name,
            mimeType: "image/png",
            data: image.pngData() ?? Data()
        )
    }
}
