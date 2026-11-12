import SwiftUI

public extension View {
    func hollerKitPresenter() -> some View {
        modifier(HollerKitPresenterModifier())
    }
}

private struct HollerKitPresenterModifier: ViewModifier {
    @Bindable private var presenter = HollerKit.presenterState
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        let enabled = HollerKit.isEnabled
        content
            .background {
                if enabled {
                    InvocationObserver(
                        invocation: presenter.currentInvocation,
                        onTrigger: { trigger, action, attachments in
                            if presenter.isPresented || presenter.isQuestsPresented {
                                switch trigger.kind {
                                case .shake, .screenshot:
                                    break
                                default:
                                    return
                                }
                            }
                            switch action {
                            case .bugReport:
                                HollerKit.presentBugReport(attachments: attachments, trigger: trigger)
                            case .quests:
                                HollerKit.presentQuests(trigger: trigger)
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
    var onTrigger: (HollerKitTrigger, HollerKitInvocationAction, [HollerKitAttachment]) -> Void

    var body: some View {
        #if canImport(UIKit)
        ZStack {
            if invocation.contains(.shake) {
                ShakeDetector(onShake: {
                    let trigger = HollerKitTrigger.shake
                    let action = invocation.action(for: trigger) ?? .bugReport
                    onTrigger(trigger, action, [])
                })
                .frame(width: 0, height: 0)
            }

            if invocation.contains(.screenshot) {
                ScreenshotDetector(onScreenshot: { attachment in
                    let trigger = HollerKitTrigger.screenshot
                    let action = invocation.action(for: trigger) ?? .bugReport
                    let attachments = attachment.map { [$0] } ?? []
                    onTrigger(trigger, action, attachments)
                })
                .frame(width: 0, height: 0)
            }

            WindowInvocationDetector(
                invocation: invocation,
                onTrigger: { trigger, action in
                    onTrigger(trigger, action, [])
                }
            )
            .frame(width: 0, height: 0)
        }
        #else
        EmptyView()
        #endif
    }
}
