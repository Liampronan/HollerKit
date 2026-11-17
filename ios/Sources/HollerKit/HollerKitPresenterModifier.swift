import SwiftUI

public extension View {
    func hollerKitPresenter() -> some View {
        modifier(HollerKitPresenterModifier())
    }
}

struct HollerKitPresenterModifier: ViewModifier {
    @Bindable private var presenter = HollerKit.presenterState
    @Environment(\.scenePhase) private var scenePhase

    @MainActor
    static func handleTrigger(
        _ trigger: HollerKitTrigger,
        action: HollerKitInvocationAction,
        attachments: [HollerKitAttachment] = [],
        presenter: HollerKitPresenterState = HollerKit.presenterState
    ) {
        if presenter.shouldIgnoreTriggerWhilePresented(trigger) {
            HollerKit.breadcrumb(
                "Ignored \(trigger.description) trigger while sheet already presented",
                category: "invocation"
            )
            return
        }
        switch action {
        case .bugReport:
            HollerKit.presentBugReport(attachments: attachments, trigger: trigger)
        case .quests:
            HollerKit.presentQuests(trigger: trigger)
        }
    }

    func body(content: Content) -> some View {
        let enabled = HollerKit.isEnabled
        let runtimeEnabled = presenter.isRuntimeEnabled
        let currentInvocation = presenter.currentInvocation
        content
            .background {
                if enabled && runtimeEnabled {
                    InvocationObserver(
                        invocation: currentInvocation,
                        onTrigger: { trigger, action, attachments in
                            Self.handleTrigger(
                                trigger,
                                action: action,
                                attachments: attachments,
                                presenter: presenter
                            )
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
                ),
                onDismiss: {
                    presenter.isQuestsSheetVisible = false
                }
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
    private let presenter = HollerKit.presenterState
    var invocation: HollerKitInvocation
    var onTrigger: (HollerKitTrigger, HollerKitInvocationAction, [HollerKitAttachment]) -> Void

    var body: some View {
        let activeInvocation = presenter.currentInvocation.actions.isEmpty ? invocation : presenter.currentInvocation
        #if canImport(UIKit)
        ZStack {
            if activeInvocation.contains(.shake) {
                ShakeDetector(onShake: {
                    let trigger = HollerKitTrigger.shake
                    let action = activeInvocation.action(for: trigger) ?? .bugReport
                    onTrigger(trigger, action, [])
                })
                .frame(width: 0, height: 0)
            }

            if activeInvocation.contains(.screenshot) {
                ScreenshotDetector(onScreenshot: { attachment in
                    let trigger = HollerKitTrigger.screenshot
                    let action = activeInvocation.action(for: trigger) ?? .bugReport
                    let attachments = attachment.map { [$0] } ?? []
                    onTrigger(trigger, action, attachments)
                })
                .frame(width: 0, height: 0)
            }

            WindowInvocationDetector(
                invocation: activeInvocation,
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
