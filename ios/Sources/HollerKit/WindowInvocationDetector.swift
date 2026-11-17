import SwiftUI

#if canImport(UIKit)
import UIKit
import UIKit.UIGestureRecognizerSubclass

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

/// Window-level multi-finger long-press gesture recognizer that coexists non-exclusively with
/// competing subview gesture recognizers (such as Mapbox pinch/rotate/pitch/two-finger-tap and `UIScrollView` pan/pinch).
@MainActor
final class HollerKitMultiFingerLongPressGestureRecognizer: UILongPressGestureRecognizer {
    static let defaultPressDuration: TimeInterval = 0.5
    static let defaultAllowableMovement: CGFloat = 28.0

    let trigger: HollerKitTrigger
    var onRecognized: (() -> Void)?
    var onFailure: ((String, CGFloat) -> Void)?

    private(set) var maxObservedTouchCount: Int = 0
    private(set) var didReachRequiredTouches = false
    private(set) var exceededRequiredTouches = false
    private(set) var didRecognizeCurrentCycle = false
    private(set) var hasFailedCurrentCycle = false
    private(set) var maxTouchMovement: CGFloat = 0

    private var activeTouches: Set<UITouch> = []
    private var anchorLocations: [ObjectIdentifier: CGPoint] = [:]
    private weak var trackedEvent: UIEvent?
    private var holdTask: Task<Void, Never>?
    private var cycleGeneration: UInt64 = 0

    init(
        trigger: HollerKitTrigger,
        numberOfTouchesRequired: Int,
        target: Any?,
        action: Selector?
    ) {
        self.trigger = trigger
        super.init(target: target, action: action)
        self.numberOfTouchesRequired = numberOfTouchesRequired
        self.minimumPressDuration = Self.defaultPressDuration
        self.allowableMovement = Self.defaultAllowableMovement
        self.cancelsTouchesInView = false
        self.delaysTouchesBegan = false
        self.delaysTouchesEnded = false
        self.requiresExclusiveTouchType = false
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool {
        false
    }

    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool {
        false
    }

    override func shouldRequireFailure(of otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        false
    }

    override func shouldBeRequiredToFail(by otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if !activeTouches.isEmpty && !hasAnyLiveTouch(in: activeTouches) {
            clearTrackingState()
        }
        trackedEvent = event
        for touch in touches {
            activeTouches.insert(touch)
        }

        let totalActiveCount = resolvedActiveTouchCount(with: event)
        if totalActiveCount > maxObservedTouchCount {
            maxObservedTouchCount = totalActiveCount
        }

        super.touchesBegan(touches, with: event)

        if totalActiveCount > numberOfTouchesRequired {
            exceededRequiredTouches = true
            cancelHoldTask()
            hasFailedCurrentCycle = true
            if state == .possible {
                state = .failed
            }
            return
        }

        if totalActiveCount == numberOfTouchesRequired,
           !didReachRequiredTouches,
           !exceededRequiredTouches,
           !hasFailedCurrentCycle,
           !didRecognizeCurrentCycle {
            didReachRequiredTouches = true
            snapshotAnchorLocations()
            startHoldTimer()
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        trackedEvent = event
        super.touchesMoved(touches, with: event)
        guard didReachRequiredTouches,
              !exceededRequiredTouches,
              !didRecognizeCurrentCycle,
              !hasFailedCurrentCycle else {
            return
        }
        evaluateTouchMovementAndCount(with: event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        trackedEvent = event
        for touch in touches {
            activeTouches.remove(touch)
        }
        super.touchesEnded(touches, with: event)

        if didReachRequiredTouches && !exceededRequiredTouches && !didRecognizeCurrentCycle && !hasFailedCurrentCycle {
            failCurrentCycle(reason: "released_early")
        }
        if activeTouches.isEmpty || !hasAnyLiveTouch(in: activeTouches) {
            clearTrackingState()
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        trackedEvent = event
        for touch in touches {
            activeTouches.remove(touch)
        }
        super.touchesCancelled(touches, with: event)

        if didReachRequiredTouches && !exceededRequiredTouches && !didRecognizeCurrentCycle && !hasFailedCurrentCycle {
            failCurrentCycle(reason: "touches_cancelled")
        }
        if activeTouches.isEmpty || !hasAnyLiveTouch(in: activeTouches) {
            clearTrackingState()
        }
    }

    override func reset() {
        super.reset()
        // If UIKit called reset() prematurely because a competing gesture recognizer in a child view
        // demanded failure precedence while all required touches are still stationary on screen,
        // keep the hold task alive to finish evaluating the live touches.
        if didReachRequiredTouches,
           !exceededRequiredTouches,
           !didRecognizeCurrentCycle,
           !hasFailedCurrentCycle,
           holdTask != nil,
           hasRequiredStationaryTouchesWithinAllowableMovement() {
            return
        }
        clearTrackingState()
    }

    /// Fires recognition at most once for the current multi-finger press cycle.
    func recognizeCurrentCycleIfNeeded() {
        guard !didRecognizeCurrentCycle, !hasFailedCurrentCycle, !exceededRequiredTouches else { return }
        didRecognizeCurrentCycle = true
        cancelHoldTask()
        onRecognized?()
    }

    /// Simulates a recognized multi-finger long press for deterministic unit testing.
    func recognizeForTesting() {
        didReachRequiredTouches = false
        exceededRequiredTouches = false
        hasFailedCurrentCycle = false
        didRecognizeCurrentCycle = false
        recognizeCurrentCycleIfNeeded()
        clearTrackingState()
    }

    private func resolvedActiveTouchCount(with event: UIEvent?) -> Int {
        let liveTracked = activeTouches.filter(Self.isTouchPhaseActive)
        if let view,
           let eventTouches = (event ?? trackedEvent)?.touches(for: view)?.filter(Self.isTouchPhaseActive),
           !eventTouches.isEmpty {
            return max(liveTracked.count, eventTouches.count)
        }
        return liveTracked.count
    }

    private static func isTouchPhaseActive(_ touch: UITouch) -> Bool {
        switch touch.phase {
        case .began, .moved, .stationary:
            return true
        case .ended, .cancelled, .regionEntered, .regionMoved, .regionExited:
            return false
        @unknown default:
            return false
        }
    }

    private func hasAnyLiveTouch(in touches: Set<UITouch>) -> Bool {
        touches.contains(where: Self.isTouchPhaseActive)
    }

    private func snapshotAnchorLocations() {
        anchorLocations.removeAll(keepingCapacity: true)
        guard let referenceView = view else { return }
        for touch in activeTouches where Self.isTouchPhaseActive(touch) {
            anchorLocations[ObjectIdentifier(touch)] = touch.location(in: referenceView)
        }
    }

    private func hasRequiredStationaryTouchesWithinAllowableMovement() -> Bool {
        guard let referenceView = view else { return false }
        let liveTouches = activeTouches.filter(Self.isTouchPhaseActive)
        guard liveTouches.count == numberOfTouchesRequired else { return false }
        if let eventTouches = trackedEvent?.touches(for: referenceView)?.filter(Self.isTouchPhaseActive),
           !eventTouches.isEmpty,
           eventTouches.count != numberOfTouchesRequired {
            return false
        }
        for touch in liveTouches {
            let key = ObjectIdentifier(touch)
            let currentLocation = touch.location(in: referenceView)
            if let anchor = anchorLocations[key] {
                let distance = hypot(currentLocation.x - anchor.x, currentLocation.y - anchor.y)
                if distance > allowableMovement {
                    return false
                }
            }
        }
        return true
    }

    private func evaluateTouchMovementAndCount(with event: UIEvent?) {
        let totalActiveCount = resolvedActiveTouchCount(with: event)
        if totalActiveCount > numberOfTouchesRequired {
            exceededRequiredTouches = true
            hasFailedCurrentCycle = true
            cancelHoldTask()
            if state == .possible {
                state = .failed
            }
            return
        }
        if totalActiveCount < numberOfTouchesRequired {
            failCurrentCycle(reason: "released_early")
            return
        }
        guard let referenceView = view else { return }
        for touch in activeTouches where Self.isTouchPhaseActive(touch) {
            let key = ObjectIdentifier(touch)
            let currentLocation = touch.location(in: referenceView)
            guard let anchor = anchorLocations[key] else {
                anchorLocations[key] = currentLocation
                continue
            }
            let distance = hypot(currentLocation.x - anchor.x, currentLocation.y - anchor.y)
            if distance > maxTouchMovement {
                maxTouchMovement = distance
            }
            if distance > allowableMovement {
                failCurrentCycle(reason: "movement_exceeded")
                return
            }
        }
    }

    private func startHoldTimer() {
        cancelHoldTask()
        cycleGeneration &+= 1
        let generation = cycleGeneration
        let durationSeconds = max(0.05, minimumPressDuration)
        let checkIntervalNanoseconds: UInt64 = 25_000_000
        let deadline = ContinuousClock.now + .nanoseconds(Int64(durationSeconds * 1_000_000_000))

        holdTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: checkIntervalNanoseconds)
                guard !Task.isCancelled,
                      let self,
                      self.cycleGeneration == generation,
                      self.didReachRequiredTouches,
                      !self.exceededRequiredTouches,
                      !self.didRecognizeCurrentCycle,
                      !self.hasFailedCurrentCycle else {
                    return
                }

                self.evaluateTouchMovementAndCount(with: self.trackedEvent)
                guard !self.hasFailedCurrentCycle, !self.exceededRequiredTouches else {
                    return
                }

                if ContinuousClock.now >= deadline {
                    if self.state == .possible {
                        self.state = .began
                    }
                    self.recognizeCurrentCycleIfNeeded()
                    return
                }
            }
        }
    }

    private func failCurrentCycle(reason: String) {
        guard !hasFailedCurrentCycle, !didRecognizeCurrentCycle else { return }
        hasFailedCurrentCycle = true
        cancelHoldTask()
        if state == .possible {
            state = .failed
        }
        if didReachRequiredTouches && !exceededRequiredTouches {
            onFailure?(reason, maxTouchMovement)
        }
    }

    private func cancelHoldTask() {
        holdTask?.cancel()
        holdTask = nil
    }

    func clearTrackingState() {
        cycleGeneration &+= 1
        cancelHoldTask()
        activeTouches.removeAll(keepingCapacity: true)
        anchorLocations.removeAll(keepingCapacity: true)
        trackedEvent = nil
        maxObservedTouchCount = 0
        didReachRequiredTouches = false
        exceededRequiredTouches = false
        didRecognizeCurrentCycle = false
        hasFailedCurrentCycle = false
        maxTouchMovement = 0
    }
}

final class WindowInvocationHostingView: UIView, UIGestureRecognizerDelegate {
    private struct WeakHostingViewBox {
        weak var view: WindowInvocationHostingView?
    }

    private static var activeViews: [WeakHostingViewBox] = []
    private static let failureBreadcrumbCooldownSeconds: TimeInterval = 2.0

    /// Synchronizes all mounted `WindowInvocationHostingView` instances immediately when runtime
    /// invocation triggers change via `HollerKit.setInvocation`, `setInvocationProvider`, or `configure`.
    @MainActor
    static func synchronizeActiveViews(with invocation: HollerKitInvocation) {
        activeViews.removeAll { $0.view == nil }
        for box in activeViews {
            box.view?.synchronizeRuntimeInvocation(invocation)
        }
    }

    @MainActor
    static var registeredHostingViewsForTesting: [WindowInvocationHostingView] {
        activeViews.compactMap(\.view)
    }

    private var invocation: HollerKitInvocation
    private var onTrigger: (HollerKitTrigger, HollerKitInvocationAction) -> Void

    private weak var currentWindow: UIWindow?
    private var strokeRecognizer: HollerKitStrokeGestureRecognizer?
    private var drawingView: StrokeDrawingView?
    private var twoFingerLongPressRecognizer: HollerKitMultiFingerLongPressGestureRecognizer?
    private var threeFingerLongPressRecognizer: HollerKitMultiFingerLongPressGestureRecognizer?
    private var threeFingerDoubleTapRecognizer: UITapGestureRecognizer?
    private var floatingButtonView: HollerKitFloatingButtonView?
    private var lastFailureBreadcrumbDates: [HollerKitTrigger: Date] = [:]

    var currentAttachedWindow: UIWindow? { currentWindow }
    var currentTwoFingerLongPressRecognizer: HollerKitMultiFingerLongPressGestureRecognizer? { twoFingerLongPressRecognizer }
    var currentThreeFingerLongPressRecognizer: HollerKitMultiFingerLongPressGestureRecognizer? { threeFingerLongPressRecognizer }
    var currentThreeFingerDoubleTapRecognizer: UITapGestureRecognizer? { threeFingerDoubleTapRecognizer }
    var currentStrokeRecognizer: HollerKitStrokeGestureRecognizer? { strokeRecognizer }
    var currentFloatingButtonView: HollerKitFloatingButtonView? { floatingButtonView }

    init(
        invocation: HollerKitInvocation,
        onTrigger: @escaping (HollerKitTrigger, HollerKitInvocationAction) -> Void
    ) {
        self.invocation = invocation
        self.onTrigger = onTrigger
        super.init(frame: .zero)
        backgroundColor = .clear
        isUserInteractionEnabled = false
        Self.registerActiveView(self)
        setupLifecycleObservers()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                detachFromWindow()
            }
        }
    }

    private static func registerActiveView(_ view: WindowInvocationHostingView) {
        activeViews.removeAll { $0.view == nil || $0.view === view }
        activeViews.append(WeakHostingViewBox(view: view))
    }

    private func setupLifecycleObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWindowOrAppDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWindowOrAppDidBecomeActive),
            name: UIWindow.didBecomeKeyNotification,
            object: nil
        )
    }

    @objc private func handleWindowOrAppDidBecomeActive() {
        reconcileWithResolvedWindow()
    }

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        if superview != nil {
            reconcileWithResolvedWindow()
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if let window {
            attachToWindow(window)
        } else {
            detachFromWindow()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if currentWindow == nil || (window != nil && window !== currentWindow) {
            reconcileWithResolvedWindow()
        }
    }

    func update(
        invocation: HollerKitInvocation,
        onTrigger: @escaping (HollerKitTrigger, HollerKitInvocationAction) -> Void
    ) {
        self.invocation = invocation
        self.onTrigger = onTrigger
        reconcileWithResolvedWindow()
    }

    func synchronizeRuntimeInvocation(_ newInvocation: HollerKitInvocation) {
        self.invocation = newInvocation
        reconcileWithResolvedWindow()
    }

    func resolveTargetWindow() -> UIWindow? {
        if let window = self.window, !(window is PassthroughOverlayWindow) {
            return window
        }
        if let currentWindow,
           !(currentWindow is PassthroughOverlayWindow),
           !currentWindow.isHidden {
            return currentWindow
        }
        return HollerKitScreenCapture.selectCaptureWindow(
            preferredScene: self.window?.windowScene ?? currentWindow?.windowScene
        )
    }

    func reconcileWithResolvedWindow() {
        guard HollerKitEnvironment.isDebugOrTestFlight else {
            detachFromWindow()
            return
        }
        guard let targetWindow = resolveTargetWindow() else {
            return
        }
        if currentWindow !== targetWindow {
            detachFromWindow()
            currentWindow = targetWindow
        }
        reconcileWindowAttachments(targetWindow)
    }

    private func attachToWindow(_ window: UIWindow) {
        if currentWindow !== window {
            detachFromWindow()
        }
        guard HollerKitEnvironment.isDebugOrTestFlight else { return }
        if window is PassthroughOverlayWindow {
            reconcileWithResolvedWindow()
            return
        }
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
        twoFingerLongPressRecognizer?.clearTrackingState()
        twoFingerLongPressRecognizer = nil

        if let threeFingerLongPressRecognizer, let window = threeFingerLongPressRecognizer.view {
            window.removeGestureRecognizer(threeFingerLongPressRecognizer)
        }
        threeFingerLongPressRecognizer?.clearTrackingState()
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
        let effectiveInvocation = invocation.actions.isEmpty ? HollerKit.currentInvocation : invocation

        // 1. Stroke gestures
        var strokeDirections: Set<StrokeDirection> = []
        if effectiveInvocation.actions.keys.contains(.stroke(.leftToCenter)) {
            strokeDirections.insert(.leftToCenter)
        }
        if effectiveInvocation.actions.keys.contains(.stroke(.rightToCenter)) {
            strokeDirections.insert(.rightToCenter)
        }

        if !strokeDirections.isEmpty {
            if drawingView == nil {
                let drawView = StrokeDrawingView(frame: window.bounds)
                drawView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                window.addSubview(drawView)
                drawingView = drawView
            } else if let drawingView, drawingView.superview !== window {
                drawingView.frame = window.bounds
                window.addSubview(drawingView)
            }

            if strokeRecognizer == nil {
                let recognizer = HollerKitStrokeGestureRecognizer()
                recognizer.drawingView = drawingView
                recognizer.onRecognized = { [weak self] direction in
                    self?.fireTrigger(.stroke(direction), includeMediumImpact: false)
                }
                window.addGestureRecognizer(recognizer)
                strokeRecognizer = recognizer
            } else if let strokeRecognizer, strokeRecognizer.view !== window {
                window.addGestureRecognizer(strokeRecognizer)
            }
            strokeRecognizer?.isEnabled = true
            strokeRecognizer?.allowedDirections = strokeDirections
            strokeRecognizer?.drawingView = drawingView
        } else {
            if let strokeRecognizer {
                strokeRecognizer.view?.removeGestureRecognizer(strokeRecognizer)
                window.removeGestureRecognizer(strokeRecognizer)
                self.strokeRecognizer = nil
            }
            drawingView?.removeFromSuperview()
            drawingView = nil
        }

        // 2. Two-finger long press
        if effectiveInvocation.actions.keys.contains(.twoFingerLongPress) {
            if twoFingerLongPressRecognizer == nil {
                let recognizer = HollerKitMultiFingerLongPressGestureRecognizer(
                    trigger: .twoFingerLongPress,
                    numberOfTouchesRequired: 2,
                    target: self,
                    action: #selector(handleTwoFingerLongPress(_:))
                )
                recognizer.delegate = self
                recognizer.onRecognized = { [weak self] in
                    self?.fireTrigger(.twoFingerLongPress, includeMediumImpact: true)
                }
                recognizer.onFailure = { [weak self] reason, movement in
                    self?.recordLongPressFailureBreadcrumb(
                        trigger: .twoFingerLongPress,
                        touches: 2,
                        reason: reason,
                        movement: movement
                    )
                }
                window.addGestureRecognizer(recognizer)
                twoFingerLongPressRecognizer = recognizer
            } else if let recognizer = twoFingerLongPressRecognizer {
                recognizer.delegate = self
                recognizer.isEnabled = true
                if recognizer.view !== window {
                    window.addGestureRecognizer(recognizer)
                }
            }
        } else {
            if let twoFingerLongPressRecognizer {
                twoFingerLongPressRecognizer.clearTrackingState()
                twoFingerLongPressRecognizer.view?.removeGestureRecognizer(twoFingerLongPressRecognizer)
                window.removeGestureRecognizer(twoFingerLongPressRecognizer)
                self.twoFingerLongPressRecognizer = nil
            }
        }

        // 3. Three-finger long press
        if effectiveInvocation.actions.keys.contains(.threeFingerLongPress) {
            if threeFingerLongPressRecognizer == nil {
                let recognizer = HollerKitMultiFingerLongPressGestureRecognizer(
                    trigger: .threeFingerLongPress,
                    numberOfTouchesRequired: 3,
                    target: self,
                    action: #selector(handleThreeFingerLongPress(_:))
                )
                recognizer.delegate = self
                recognizer.onRecognized = { [weak self] in
                    self?.fireTrigger(.threeFingerLongPress, includeMediumImpact: true)
                }
                recognizer.onFailure = { [weak self] reason, movement in
                    self?.recordLongPressFailureBreadcrumb(
                        trigger: .threeFingerLongPress,
                        touches: 3,
                        reason: reason,
                        movement: movement
                    )
                }
                window.addGestureRecognizer(recognizer)
                threeFingerLongPressRecognizer = recognizer
            } else if let recognizer = threeFingerLongPressRecognizer {
                recognizer.delegate = self
                recognizer.isEnabled = true
                if recognizer.view !== window {
                    window.addGestureRecognizer(recognizer)
                }
            }
        } else {
            if let threeFingerLongPressRecognizer {
                threeFingerLongPressRecognizer.clearTrackingState()
                threeFingerLongPressRecognizer.view?.removeGestureRecognizer(threeFingerLongPressRecognizer)
                window.removeGestureRecognizer(threeFingerLongPressRecognizer)
                self.threeFingerLongPressRecognizer = nil
            }
        }

        // 4. Three-finger double tap
        if effectiveInvocation.actions.keys.contains(.threeFingerDoubleTap) {
            if threeFingerDoubleTapRecognizer == nil {
                let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleThreeFingerDoubleTap(_:)))
                recognizer.numberOfTouchesRequired = 3
                recognizer.numberOfTapsRequired = 2
                recognizer.cancelsTouchesInView = false
                recognizer.delaysTouchesBegan = false
                recognizer.delaysTouchesEnded = false
                recognizer.delegate = self
                window.addGestureRecognizer(recognizer)
                threeFingerDoubleTapRecognizer = recognizer
            } else if let recognizer = threeFingerDoubleTapRecognizer {
                recognizer.delegate = self
                recognizer.isEnabled = true
                if recognizer.view !== window {
                    window.addGestureRecognizer(recognizer)
                }
            }
        } else {
            if let threeFingerDoubleTapRecognizer {
                threeFingerDoubleTapRecognizer.view?.removeGestureRecognizer(threeFingerDoubleTapRecognizer)
                window.removeGestureRecognizer(threeFingerDoubleTapRecognizer)
                self.threeFingerDoubleTapRecognizer = nil
            }
        }

        // 5. Floating button
        if effectiveInvocation.actions.keys.contains(.floatingButton) {
            if floatingButtonView == nil {
                let button = HollerKitFloatingButtonView()
                button.onTap = { [weak self] in
                    self?.fireTrigger(.floatingButton, includeMediumImpact: false)
                }
                window.addSubview(button)
                floatingButtonView = button
            } else if let floatingButtonView, floatingButtonView.superview !== window {
                window.addSubview(floatingButtonView)
            }
        } else {
            floatingButtonView?.removeFromSuperview()
            floatingButtonView = nil
        }
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRequireFailureOf otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        false
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        false
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldReceive touch: UITouch
    ) -> Bool {
        true
    }

    private func fireTrigger(_ trigger: HollerKitTrigger, includeMediumImpact: Bool) {
        guard let action = invocation.action(for: trigger) ?? HollerKit.currentInvocation.action(for: trigger) else {
            return
        }
        if includeMediumImpact {
            let generator = UIImpactFeedbackGenerator(style: .medium)
            generator.prepare()
            generator.impactOccurred()
        }
        onTrigger(trigger, action)
    }

    private func recordLongPressFailureBreadcrumb(
        trigger: HollerKitTrigger,
        touches: Int,
        reason: String,
        movement: CGFloat,
        now: Date = Date()
    ) {
        if let lastDate = lastFailureBreadcrumbDates[trigger],
           now.timeIntervalSince(lastDate) < Self.failureBreadcrumbCooldownSeconds {
            return
        }
        lastFailureBreadcrumbDates[trigger] = now
        HollerKit.breadcrumb(
            "Gesture \(trigger.description) failed (\(reason))",
            category: "invocation",
            fields: [
                "trigger": .string(trigger.description),
                "reason": .string(reason),
                "touches": .int(touches),
                "maxMovementPt": .double(Double(movement.rounded()))
            ],
            date: now
        )
    }

    @objc private func handleTwoFingerLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        if let customGesture = gesture as? HollerKitMultiFingerLongPressGestureRecognizer {
            customGesture.recognizeCurrentCycleIfNeeded()
        } else {
            fireTrigger(.twoFingerLongPress, includeMediumImpact: true)
        }
    }

    @objc private func handleThreeFingerLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        if let customGesture = gesture as? HollerKitMultiFingerLongPressGestureRecognizer {
            customGesture.recognizeCurrentCycleIfNeeded()
        } else {
            fireTrigger(.threeFingerLongPress, includeMediumImpact: true)
        }
    }

    @objc private func handleThreeFingerDoubleTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended else { return }
        fireTrigger(.threeFingerDoubleTap, includeMediumImpact: true)
    }
}
#endif
