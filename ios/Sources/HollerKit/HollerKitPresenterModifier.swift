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
                    onInvoke: {
                        HollerKit.present()
                    }
                )
            }
            .sheet(isPresented: $presenter.isPresented) {
                HollerKit.presentationView()
            }
    }
}

private struct InvocationObserver: View {
    var invocation: HollerKitInvocation
    var onInvoke: () -> Void

    var body: some View {
        #if canImport(UIKit)
        ZStack {
            if invocation.contains(.shake) {
                ShakeDetector(onShake: onInvoke)
                    .frame(width: 0, height: 0)
            }

            if invocation.contains(.screenshot) {
                ScreenshotDetector(onScreenshot: onInvoke)
                    .frame(width: 0, height: 0)
            }
        }
        #else
        EmptyView()
        #endif
    }
}
