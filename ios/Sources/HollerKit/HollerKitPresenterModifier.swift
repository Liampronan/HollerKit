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
        let enabled = HollerKit.isEnabled
        content
            .background {
                if enabled {
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
            }
            .sheet(
                isPresented: Binding(
                    get: { presenter.isRuntimeEnabled && presenter.isPresented },
                    set: { presenter.isPresented = $0 }
                ),
                onDismiss: {
                    HollerKit.clearPresentationAttachments()
                }
            ) {
                HollerKit.presentationView()
            }
            .sheet(
                isPresented: Binding(
                    get: { presenter.isRuntimeEnabled && presenter.isQuestsPresented },
                    set: { presenter.isQuestsPresented = $0 }
                )
            ) {
                HollerKit.questBoardView()
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
