import SwiftUI

#if canImport(UIKit)
import UIKit

/// Draggable floating button docked to the edge of the screen for debug invocation.
final class HollerKitFloatingButtonView: UIView {
    var onTap: (() -> Void)?

    private let button = UIButton(type: .system)
    private var panGesture: UIPanGestureRecognizer?
    private var boundsObservation: NSKeyValueObservation?
    private let buttonSize: CGFloat = 46.0

    override init(frame: CGRect) {
        super.init(frame: CGRect(x: 16, y: 140, width: buttonSize, height: buttonSize))
        setupView()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        boundsObservation?.invalidate()
        boundsObservation = nil
        guard let superview else { return }
        clampCenterToSafeArea(in: superview)
        boundsObservation = superview.observe(\.bounds, options: [.new]) { [weak self] container, _ in
            MainActor.assumeIsolated {
                self?.clampCenterToSafeArea(in: container)
            }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if let superview, panGesture?.state != .changed && panGesture?.state != .began {
            clampCenterToSafeArea(in: superview)
        }
    }

    private func setupView() {
        backgroundColor = UIColor.systemBlue.withAlphaComponent(0.92)
        layer.cornerRadius = buttonSize / 2.0
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.28
        layer.shadowOffset = CGSize(width: 0, height: 2)
        layer.shadowRadius = 4
        accessibilityIdentifier = "HollerKitFloatingButton"

        let image = UIImage(systemName: "ladybug.fill") ?? UIImage(systemName: "exclamationmark.bubble.fill")
        button.setImage(image, for: .normal)
        button.tintColor = .white
        button.frame = bounds
        button.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        button.addTarget(self, action: #selector(buttonTapped), for: .touchUpInside)
        addSubview(button)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        addGestureRecognizer(pan)
        self.panGesture = pan
    }

    @objc private func buttonTapped() {
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.prepare()
        generator.impactOccurred()
        onTap?()
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard let superview else { return }
        let translation = gesture.translation(in: superview)

        switch gesture.state {
        case .changed:
            center = CGPoint(
                x: center.x + translation.x,
                y: center.y + translation.y
            )
            gesture.setTranslation(.zero, in: superview)

        case .ended, .cancelled:
            snapToNearestEdge(in: superview)

        default:
            break
        }
    }

    func clampCenterToSafeArea(in container: UIView) {
        guard container.bounds.width > 0, container.bounds.height > 0 else { return }
        let safeArea = container.safeAreaInsets
        let minX = safeArea.left + (buttonSize / 2.0) + 8
        let maxX = max(minX, container.bounds.width - safeArea.right - (buttonSize / 2.0) - 8)
        let minY = safeArea.top + (buttonSize / 2.0) + 8
        let maxY = max(minY, container.bounds.height - safeArea.bottom - (buttonSize / 2.0) - 8)

        let clampedX = min(max(center.x, minX), maxX)
        let clampedY = min(max(center.y, minY), maxY)
        if center.x != clampedX || center.y != clampedY {
            center = CGPoint(x: clampedX, y: clampedY)
        }
    }

    private func snapToNearestEdge(in container: UIView) {
        let safeArea = container.safeAreaInsets
        let minX = safeArea.left + (buttonSize / 2.0) + 8
        let maxX = max(minX, container.bounds.width - safeArea.right - (buttonSize / 2.0) - 8)
        let minY = safeArea.top + (buttonSize / 2.0) + 8
        let maxY = max(minY, container.bounds.height - safeArea.bottom - (buttonSize / 2.0) - 8)

        let targetX = (center.x < container.bounds.midX) ? minX : maxX
        let clampedY = min(max(center.y, minY), maxY)

        UIView.animate(
            withDuration: 0.25,
            delay: 0,
            usingSpringWithDamping: 0.78,
            initialSpringVelocity: 0.5,
            options: [.curveEaseOut],
            animations: {
                self.center = CGPoint(x: targetX, y: clampedY)
            }
        )
    }
}
#endif
