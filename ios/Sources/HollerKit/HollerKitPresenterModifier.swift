import SwiftUI

public extension View {
    func hollerKitPresenter() -> some View {
        modifier(HollerKitPresenterModifier())
    }
}

private struct HollerKitPresenterModifier: ViewModifier {
    @ObservedObject private var presenter = HollerKit.presenterState
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        Group {
            if HollerKit.isEnabled {
                content
                    .background {
                        InvocationObserver(
                            invocation: HollerKit.currentInvocation,
                            onShake: {
                                HollerKit.presentBugReport()
                            },
                            onScreenshot: { attachment in
                                if let attachment {
                                    HollerKit.presentBugReport(attachments: [attachment])
                                } else {
                                    HollerKit.presentBugReport()
                                }
                            }
                        )
                    }
                    .sheet(isPresented: $presenter.isPresented, onDismiss: {
                        HollerKit.clearPresentationAttachments()
                    }) {
                        HollerKit.presentationView()
                    }
                    .sheet(isPresented: $presenter.isQuestsPresented) {
                        HollerKit.questBoardView()
                    }
            } else {
                content
            }
        }
        .onAppear {
            HollerKit.reconcileEnablement()
        }
        .onChange(of: scenePhase) { _, _ in
            HollerKit.reconcileEnablement()
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
