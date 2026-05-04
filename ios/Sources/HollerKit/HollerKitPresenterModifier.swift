import SwiftUI

public extension View {
    func hollerKitPresenter() -> some View {
        modifier(HollerKitPresenterModifier())
    }
}

private struct HollerKitPresenterModifier: ViewModifier {
    @ObservedObject private var presenter = HollerKit.presenterState

    func body(content: Content) -> some View {
        content
            .background {
                InvocationObserver(
                    invocation: HollerKit.currentInvocation,
                    onShake: {
                        HollerKit.present()
                    },
                    onScreenshot: { attachment in
                        if let attachment {
                            HollerKit.present(attachments: [attachment])
                        } else {
                            HollerKit.present()
                        }
                    }
                )
            }
            .sheet(isPresented: $presenter.isPresented, onDismiss: {
                HollerKit.clearPresentationAttachments()
            }) {
                HollerKit.presentationView()
            }
    }
}

private struct InvocationObserver: View {
    var invocation: HollerKitInvocation
    var onShake: () -> Void
    var onScreenshot: (HollerKitAttachment?) -> Void

    var body: some View {
        #if canImport(UIKit)
        ZStack {
            if invocation.contains(.shake) {
                ShakeDetector(onShake: onShake)
                    .frame(width: 0, height: 0)
            }

            if invocation.contains(.screenshot) {
                ScreenshotDetector(onScreenshot: onScreenshot)
                    .frame(width: 0, height: 0)
            }
        }
        #else
        EmptyView()
        #endif
    }
}
