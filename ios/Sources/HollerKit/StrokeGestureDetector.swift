import SwiftUI

#if canImport(UIKit)
import UIKit

/// Pure, stateless classifier for drawn stroke gestures across screen geometry.
public struct StrokeGestureClassifier {
    /// Classifies an array of touch points into a matching `StrokeDirection` or `nil`.
    public static func classify(
        points: [CGPoint],
        bounds: CGRect,
        allowedDirections: Set<StrokeDirection> = Set(StrokeDirection.allCases),
        minEdgeInset: CGFloat = 24.0,
        edgeZoneFraction: CGFloat = 0.40,
        verticalMargin: CGFloat = 60.0,
        minDistance: CGFloat = 70.0,
        maxAngleDegrees: CGFloat = 35.0,
        maxPathWanderRatio: CGFloat = 1.35
    ) -> StrokeDirection? {
        guard points.count >= 2, bounds.width > 0, bounds.height > 0 else {
            return nil
        }
        let start = points[0]
        let end = points[points.count - 1]

        let dx = end.x - start.x
        let dy = end.y - start.y
        let displacement = hypot(dx, dy)

        // 1. Minimum stroke length check
        guard displacement >= minDistance else {
            return nil
        }

        // 2. Vertical margin check to avoid top notification center / dynamic island and bottom home bar swipes
        guard start.y >= verticalMargin, start.y <= (bounds.height - verticalMargin) else {
            return nil
        }

        // 3. Path straightness check (prevents curved scribbles and wandering map pans)
        var totalPathLength: CGFloat = 0
        for i in 0..<(points.count - 1) {
            totalPathLength += hypot(points[i + 1].x - points[i].x, points[i + 1].y - points[i].y)
        }
        guard (totalPathLength / displacement) <= maxPathWanderRatio else {
            return nil
        }

        let maxAngleSlope = tan(maxAngleDegrees * .pi / 180.0)
        let centerX = bounds.midX

        // 4. Directional checks: left-to-center
        if dx > 0, allowedDirections.contains(.leftToCenter) {
            // Must not start directly on the left edge (protects UINavigationController interactive pop)
            guard start.x >= minEdgeInset else { return nil }
            // Must begin in the outer left portion of the screen
            guard start.x <= bounds.width * edgeZoneFraction else { return nil }
            // Must progress toward screen center
            guard abs(end.x - centerX) < abs(start.x - centerX) else { return nil }
            // Must satisfy horizontal angle tolerance (not a vertical scroll or diagonal pan)
            guard abs(dy) <= (dx * maxAngleSlope) else { return nil }
            return .leftToCenter
        }

        // 5. Directional checks: right-to-center
        if dx < 0, allowedDirections.contains(.rightToCenter) {
            // Must not start directly on the right edge
            guard start.x <= (bounds.width - minEdgeInset) else { return nil }
            // Must begin in the outer right portion of the screen
            guard start.x >= bounds.width * (1.0 - edgeZoneFraction) else { return nil }
            // Must progress toward screen center
            guard abs(end.x - centerX) < abs(start.x - centerX) else { return nil }
            // Must satisfy horizontal angle tolerance
            guard abs(dy) <= (-dx * maxAngleSlope) else { return nil }
            return .rightToCenter
        }

        return nil
    }
}

/// A non-interactive transparent overlay view that renders fading stroke feedback as the finger moves.
final class StrokeDrawingView: UIView {
    private let strokeLayer = CAShapeLayer()
    private var activePath = UIBezierPath()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear

        strokeLayer.fillColor = UIColor.clear.cgColor
        strokeLayer.strokeColor = UIColor.systemBlue.withAlphaComponent(0.65).cgColor
        strokeLayer.lineWidth = 4.5
        strokeLayer.lineCap = .round
        strokeLayer.lineJoin = .round
        layer.addSublayer(strokeLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        strokeLayer.frame = bounds
    }

    func beginStroke(at point: CGPoint) {
        strokeLayer.removeAllAnimations()
        strokeLayer.opacity = 1.0
        strokeLayer.strokeColor = UIColor.systemBlue.withAlphaComponent(0.65).cgColor
        activePath = UIBezierPath()
        activePath.move(to: point)
        strokeLayer.path = activePath.cgPath
    }

    func addPoint(_ point: CGPoint) {
        activePath.addLine(to: point)
        strokeLayer.path = activePath.cgPath
    }

    func finishStroke(recognized: Bool) {
        if recognized {
            strokeLayer.strokeColor = UIColor.systemGreen.withAlphaComponent(0.85).cgColor
        }
        UIView.animate(
            withDuration: 0.28,
            delay: 0.05,
            options: [.curveEaseOut],
            animations: {
                self.strokeLayer.opacity = 0.0
            },
            completion: { _ in
                self.activePath = UIBezierPath()
                self.strokeLayer.path = nil
                self.strokeLayer.opacity = 1.0
            }
        )
    }

    func cancelStroke() {
        UIView.animate(
            withDuration: 0.15,
            delay: 0,
            options: [.curveEaseOut],
            animations: {
                self.strokeLayer.opacity = 0.0
            },
            completion: { _ in
                self.activePath = UIBezierPath()
                self.strokeLayer.path = nil
                self.strokeLayer.opacity = 1.0
            }
        )
    }
}

/// Custom UIGestureRecognizer that watches stroke gestures across the screen without intercepting touches.
final class HollerKitStrokeGestureRecognizer: UIGestureRecognizer, UIGestureRecognizerDelegate {
    var allowedDirections: Set<StrokeDirection> = Set(StrokeDirection.allCases)
    var onRecognized: ((StrokeDirection) -> Void)?
    weak var drawingView: StrokeDrawingView?

    private var trackedPoints: [CGPoint] = []

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        delegate = self
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }

    private weak var activeTouch: UITouch?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        if activeTouch != nil {
            resetRecognizer()
            return
        }
        guard touches.count == 1, let touch = touches.first, let view else {
            resetRecognizer()
            return
        }
        activeTouch = touch
        let location = touch.location(in: view)
        trackedPoints = [location]
        drawingView?.beginStroke(at: location)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesMoved(touches, with: event)
        guard let activeTouch, touches.contains(activeTouch), let view else { return }
        let location = activeTouch.location(in: view)
        trackedPoints.append(location)
        drawingView?.addPoint(location)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        guard let activeTouch, touches.contains(activeTouch), let view else {
            resetRecognizer()
            return
        }
        let location = activeTouch.location(in: view)
        trackedPoints.append(location)

        let classified = StrokeGestureClassifier.classify(
            points: trackedPoints,
            bounds: view.bounds,
            allowedDirections: allowedDirections
        )

        if let direction = classified {
            state = .ended
            drawingView?.finishStroke(recognized: true)
            triggerHapticFeedback()
            onRecognized?(direction)
        } else {
            state = .failed
            drawingView?.finishStroke(recognized: false)
        }
        trackedPoints = []
        self.activeTouch = nil
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        state = .cancelled
        drawingView?.cancelStroke()
        trackedPoints = []
        activeTouch = nil
    }

    override func reset() {
        super.reset()
        trackedPoints = []
        activeTouch = nil
    }

    private func resetRecognizer() {
        state = .failed
        drawingView?.cancelStroke()
        trackedPoints = []
        activeTouch = nil
    }

    private func triggerHapticFeedback() {
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.prepare()
        generator.impactOccurred()
    }
}
#endif
