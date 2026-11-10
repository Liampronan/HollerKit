import SwiftUI

#if canImport(UIKit)
import UIKit

struct WindowInvocationDetector: UIViewRepresentable {
    var invocation: HollerKitInvocation
    var onTrigger: (HollerKitTrigger, HollerKitInvocationAction) -> Void

    func makeUIView(context: Context) -> WindowInvocationHostingView {
        WindowInvocationHostingView(invocation: invocation, onTrigger: onTrigger)
    }

    func updateUIView(_ uiView: WindowInvocationHostingView, context: Context) {
        uiView.update(invocation: invocation, onTrigger: onTrigger)
    }
}

final class WindowInvocationHostingView: UIView, UIGestureRecognizerDelegate {
    private var invocation: HollerKitInvocation
    private var onTrigger: (HollerKitTrigger, HollerKitInvocationAction) -> Void

    private weak var currentWindow: UIWindow?
    private var strokeRecognizer: HollerKitStrokeGestureRecognizer?
    private var drawingView: StrokeDrawingView?
    private var twoFingerLongPressRecognizer: UILongPressGestureRecognizer?
    private var threeFingerLongPressRecognizer: UILongPressGestureRecognizer?
    private var threeFingerDoubleTapRecognizer: UITapGestureRecognizer?
    private var floatingButtonView: HollerKitFloatingButtonView?

    init(
        invocation: HollerKitInvocation,
        onTrigger: @escaping (HollerKitTrigger, HollerKitInvocationAction) -> Void
    ) {
        self.invocation = invocation
        self.onTrigger = onTrigger
        super.init(frame: .zero)
        backgroundColor = .clear
        isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if let window {
            attachToWindow(window)
        } else {
            detachFromWindow()
        }
    }

    func update(
        invocation: HollerKitInvocation,
        onTrigger: @escaping (HollerKitTrigger, HollerKitInvocationAction) -> Void
    ) {
        self.invocation = invocation
        self.onTrigger = onTrigger
        if let window = currentWindow {
            reconcileWindowAttachments(window)
        }
    }

    private func attachToWindow(_ window: UIWindow) {
        guard HollerKitEnvironment.isDebugOrTestFlight else { return }
        detachFromWindow()
        currentWindow = window
        reconcileWindowAttachments(window)
    }

    private func detachFromWindow() {
        if let strokeRecognizer, let window = strokeRecognizer.view {
            window.removeGestureRecognizer(strokeRecognizer)
        }
        strokeRecognizer = nil

        drawingView?.removeFromSuperview()
        drawingView = nil

        if let twoFingerLongPressRecognizer, let window = twoFingerLongPressRecognizer.view {
            window.removeGestureRecognizer(twoFingerLongPressRecognizer)
        }
        twoFingerLongPressRecognizer = nil

        if let threeFingerLongPressRecognizer, let window = threeFingerLongPressRecognizer.view {
            window.removeGestureRecognizer(threeFingerLongPressRecognizer)
        }
        threeFingerLongPressRecognizer = nil

        if let threeFingerDoubleTapRecognizer, let window = threeFingerDoubleTapRecognizer.view {
            window.removeGestureRecognizer(threeFingerDoubleTapRecognizer)
        }
        threeFingerDoubleTapRecognizer = nil

        floatingButtonView?.removeFromSuperview()
        floatingButtonView = nil

        currentWindow = nil
    }

    private func reconcileWindowAttachments(_ window: UIWindow) {
        guard HollerKitEnvironment.isDebugOrTestFlight else {
            detachFromWindow()
            return
        }

        // 1. Stroke gestures
        var strokeDirections: Set<StrokeDirection> = []
        if invocation.actions.keys.contains(.stroke(.leftToCenter)) {
            strokeDirections.insert(.leftToCenter)
        }
        if invocation.actions.keys.contains(.stroke(.rightToCenter)) {
            strokeDirections.insert(.rightToCenter)
        }

        if !strokeDirections.isEmpty {
            if drawingView == nil {
                let drawView = StrokeDrawingView(frame: window.bounds)
                drawView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                window.addSubview(drawView)
                drawingView = drawView
            }

            if strokeRecognizer == nil {
                let recognizer = HollerKitStrokeGestureRecognizer()
                recognizer.drawingView = drawingView
                recognizer.onRecognized = { [weak self] direction in
                    guard let self else { return }
                    let trigger = HollerKitTrigger.stroke(direction)
                    if let action = self.invocation.action(for: trigger) {
                        self.onTrigger(trigger, action)
                    }
                }
                window.addGestureRecognizer(recognizer)
                strokeRecognizer = recognizer
            }
            strokeRecognizer?.allowedDirections = strokeDirections
            strokeRecognizer?.drawingView = drawingView
        } else {
            if let strokeRecognizer {
                window.removeGestureRecognizer(strokeRecognizer)
                self.strokeRecognizer = nil
            }
            drawingView?.removeFromSuperview()
            drawingView = nil
        }

        // 2. Two-finger long press
        if invocation.actions.keys.contains(.twoFingerLongPress) {
            if twoFingerLongPressRecognizer == nil {
                let recognizer = UILongPressGestureRecognizer(target: self, action: #selector(handleTwoFingerLongPress(_:)))
                recognizer.numberOfTouchesRequired = 2
                recognizer.minimumPressDuration = 0.6
                recognizer.cancelsTouchesInView = false
                recognizer.delegate = self
                window.addGestureRecognizer(recognizer)
                twoFingerLongPressRecognizer = recognizer
            }
        } else {
            if let twoFingerLongPressRecognizer {
                window.removeGestureRecognizer(twoFingerLongPressRecognizer)
                self.twoFingerLongPressRecognizer = nil
            }
        }

        // 3. Three-finger long press
        if invocation.actions.keys.contains(.threeFingerLongPress) {
            if threeFingerLongPressRecognizer == nil {
                let recognizer = UILongPressGestureRecognizer(target: self, action: #selector(handleThreeFingerLongPress(_:)))
                recognizer.numberOfTouchesRequired = 3
                recognizer.minimumPressDuration = 0.6
                recognizer.cancelsTouchesInView = false
                recognizer.delegate = self
                window.addGestureRecognizer(recognizer)
                threeFingerLongPressRecognizer = recognizer
            }
        } else {
            if let threeFingerLongPressRecognizer {
                window.removeGestureRecognizer(threeFingerLongPressRecognizer)
                self.threeFingerLongPressRecognizer = nil
            }
        }

        // 4. Three-finger double tap
        if invocation.actions.keys.contains(.threeFingerDoubleTap) {
            if threeFingerDoubleTapRecognizer == nil {
                let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleThreeFingerDoubleTap(_:)))
                recognizer.numberOfTouchesRequired = 3
                recognizer.numberOfTapsRequired = 2
                recognizer.cancelsTouchesInView = false
                recognizer.delegate = self
                window.addGestureRecognizer(recognizer)
                threeFingerDoubleTapRecognizer = recognizer
            }
        } else {
            if let threeFingerDoubleTapRecognizer {
                window.removeGestureRecognizer(threeFingerDoubleTapRecognizer)
                self.threeFingerDoubleTapRecognizer = nil
            }
        }

        // 5. Floating button
        if invocation.actions.keys.contains(.floatingButton) {
            if floatingButtonView == nil {
                let button = HollerKitFloatingButtonView()
                button.onTap = { [weak self] in
                    guard let self else { return }
                    let trigger = HollerKitTrigger.floatingButton
                    if let action = self.invocation.action(for: trigger) {
                        self.onTrigger(trigger, action)
                    }
                }
                window.addSubview(button)
                floatingButtonView = button
            }
        } else {
            floatingButtonView?.removeFromSuperview()
            floatingButtonView = nil
        }
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }

    @objc private func handleTwoFingerLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.prepare()
        generator.impactOccurred()
        let trigger = HollerKitTrigger.twoFingerLongPress
        if let action = invocation.action(for: trigger) {
            onTrigger(trigger, action)
        }
    }

    @objc private func handleThreeFingerLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.prepare()
        generator.impactOccurred()
        let trigger = HollerKitTrigger.threeFingerLongPress
        if let action = invocation.action(for: trigger) {
            onTrigger(trigger, action)
        }
    }

    @objc private func handleThreeFingerDoubleTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended else { return }
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.prepare()
        generator.impactOccurred()
        let trigger = HollerKitTrigger.threeFingerDoubleTap
        if let action = invocation.action(for: trigger) {
            onTrigger(trigger, action)
        }
    }

    deinit {
        detachFromWindow()
    }
}
#endif
