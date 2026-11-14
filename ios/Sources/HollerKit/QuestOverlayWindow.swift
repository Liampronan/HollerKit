import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

@MainActor
public final class QuestOverlayWindowManager {
    public static let shared = QuestOverlayWindowManager()

    #if canImport(UIKit)
    private var overlayWindow: PassthroughOverlayWindow?
    private weak var boundWindowScene: UIWindowScene?
    private var isPendingSheetDismissalTeardown = false
    private var teardownGeneration: UInt64 = 0
    private var pendingTeardownTask: Task<Void, Never>?
    var simulatedModalSheetPresentedForTesting: Bool?

    private var hasPresentedModalSheet: Bool {
        if let simulatedModalSheetPresentedForTesting {
            return simulatedModalSheetPresentedForTesting
        }
        guard let window = overlayWindow,
              window.windowScene != nil,
              let rootVC = window.rootViewController else {
            return false
        }
        return rootVC.presentedViewController != nil
    }
    #endif

    private init() {}

    public var isOverlayVisible: Bool {
        #if canImport(UIKit)
        return overlayWindow?.isHidden == false && !isPendingSheetDismissalTeardown
        #else
        return false
        #endif
    }

    /// Returns `true` while the overlay window is kept alive solely so the presented quest result sheet can complete its slide-down dismissal animation.
    public var isAwaitingSheetDismissalTeardown: Bool {
        #if canImport(UIKit)
        return overlayWindow != nil && isPendingSheetDismissalTeardown
        #else
        return false
        #endif
    }

    /// Returns `true` when an underlying overlay `UIWindow` instance is currently mounted in memory.
    public var hasMountedOverlayWindow: Bool {
        #if canImport(UIKit)
        return overlayWindow != nil
        #else
        return false
        #endif
    }

    #if canImport(UIKit)
    var currentOverlayWindow: UIWindow? {
        overlayWindow
    }

    public func show(questState: HollerKitQuestState, in windowScene: UIWindowScene? = nil) {
        let targetScene = windowScene ?? activeWindowScene()
        teardownGeneration &+= 1
        pendingTeardownTask?.cancel()
        pendingTeardownTask = nil
        isPendingSheetDismissalTeardown = false
        boundWindowScene = targetScene

        let window: PassthroughOverlayWindow
        if let targetScene {
            if let existing = overlayWindow, existing.windowScene === targetScene {
                window = existing
            } else {
                overlayWindow?.isHidden = true
                window = PassthroughOverlayWindow(windowScene: targetScene)
                overlayWindow = window
            }
        } else if let existing = overlayWindow, existing.windowScene == nil {
            window = existing
        } else {
            overlayWindow?.isHidden = true
            window = PassthroughOverlayWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
            overlayWindow = window
        }

        let rootView = QuestOverlayRootView(
            questState: questState,
            onFrameChange: { [weak window] frame in
                window?.interactiveFrame = frame
            }
        )
        let hostingController = UIHostingController(rootView: rootView)
        hostingController.view.backgroundColor = .clear
        window.rootViewController = hostingController
        window.isUserInteractionEnabled = true
        window.isHidden = false
    }
    #else
    public func show(questState: HollerKitQuestState) {}
    #endif

    /// Hides and tears down the floating quest overlay window.
    ///
    /// When `waitForPresentedSheet` is `true` and the overlay window is currently presenting a modal sheet,
    /// the window remains mounted until the sheet's dismissal transition finishes so the sheet slides down smoothly
    /// instead of vanishing abruptly.
    public func hide(waitForPresentedSheet: Bool = false) {
        #if canImport(UIKit)
        teardownGeneration &+= 1
        let generation = teardownGeneration
        pendingTeardownTask?.cancel()
        pendingTeardownTask = nil

        if waitForPresentedSheet,
           let window = overlayWindow,
           hasPresentedModalSheet {
            isPendingSheetDismissalTeardown = true
            window.interactiveFrame = .zero
            window.isUserInteractionEnabled = false

            if let coordinator = window.rootViewController?.presentedViewController?.transitionCoordinator {
                coordinator.animate(alongsideTransition: nil) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard let self, self.teardownGeneration == generation else { return }
                        self.completePendingHideIfNeeded()
                    }
                }
            }

            pendingTeardownTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 40_000_000)
                    guard !Task.isCancelled,
                          let self,
                          self.teardownGeneration == generation,
                          self.isPendingSheetDismissalTeardown else {
                        return
                    }
                    if !self.hasPresentedModalSheet {
                        self.completePendingHideIfNeeded()
                        return
                    }
                }
            }
            return
        }

        simulatedModalSheetPresentedForTesting = nil
        isPendingSheetDismissalTeardown = false
        overlayWindow?.isHidden = true
        overlayWindow?.rootViewController = nil
        overlayWindow = nil
        boundWindowScene = nil
        #endif
    }

    /// Completes deferred overlay window teardown once any presented modal sheet has finished dismissing.
    public func completePendingHideIfNeeded() {
        #if canImport(UIKit)
        guard isPendingSheetDismissalTeardown else { return }
        if !hasPresentedModalSheet {
            hide(waitForPresentedSheet: false)
        }
        #endif
    }

    /// Captures a PNG screenshot of the host app's main window in the initiating scene while excluding the HollerKit overlay window.
    public func captureHostScreenExcludingOverlay() -> Data? {
        #if canImport(UIKit)
        let wasHidden = overlayWindow?.isHidden ?? true
        overlayWindow?.isHidden = true
        defer {
            if overlayWindow != nil {
                overlayWindow?.isHidden = wasHidden
            }
        }

        guard let hostWindow = findHostAppWindow() else {
            return nil
        }

        let format = UIGraphicsImageRendererFormat()
        format.scale = hostWindow.screen.scale
        let renderer = UIGraphicsImageRenderer(bounds: hostWindow.bounds, format: format)
        let image = renderer.image { _ in
            hostWindow.drawHierarchy(in: hostWindow.bounds, afterScreenUpdates: false)
        }
        return image.pngData()
        #else
        return nil
        #endif
    }

    #if canImport(UIKit)
    private func activeWindowScene() -> UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if let activeKeyScene = scenes.first(where: { scene in
            scene.activationState == .foregroundActive && scene.windows.contains(where: \.isKeyWindow)
        }) {
            return activeKeyScene
        }
        if let active = scenes.first(where: { $0.activationState == .foregroundActive }) {
            return active
        }
        return scenes.first
    }

    private func findHostAppWindow() -> UIWindow? {
        guard let windowScene = overlayWindow?.windowScene ?? boundWindowScene ?? activeWindowScene() else {
            return nil
        }
        let candidates = windowScene.windows.filter { window in
            window !== overlayWindow && !window.isHidden && window.alpha > 0.01
        }
        if let key = candidates.first(where: { $0.isKeyWindow }) {
            return key
        }
        return candidates.first(where: { $0.windowLevel == .normal }) ?? candidates.first
    }
    #endif
}

/// Pure hit-testing policy for the floating quest overlay window.
enum OverlayHitPolicy {
    static let slop: CGFloat = 12

    /// Returns whether a touch at `point` falls within the measured `interactiveFrame` expanded by `slop`.
    static func capturesTouch(at point: CGPoint, interactiveFrame: CGRect) -> Bool {
        // Before the bar has been measured, pass everything through rather than block the whole screen.
        guard interactiveFrame != .zero, !interactiveFrame.isEmpty, !interactiveFrame.isNull else {
            return false
        }
        return interactiveFrame.insetBy(dx: -slop, dy: -slop).contains(point)
    }
}

#if canImport(UIKit)
final class PassthroughOverlayWindow: UIWindow {
    var interactiveFrame: CGRect = .zero

    override init(windowScene: UIWindowScene) {
        super.init(windowScene: windowScene)
        windowLevel = .statusBar + 1
        backgroundColor = .clear
        isOpaque = false
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        windowLevel = .statusBar + 1
        backgroundColor = .clear
        isOpaque = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if rootViewController?.presentedViewController != nil {
            return super.hitTest(point, with: event)
        }
        if let rootView = rootViewController?.view {
            assert(
                rootView.frame == bounds,
                "PassthroughOverlayWindow root view (\(rootView.frame)) must match window bounds (\(bounds)) so SwiftUI .global coordinates align with window hitTest points."
            )
        }
        guard OverlayHitPolicy.capturesTouch(at: point, interactiveFrame: interactiveFrame) else {
            return nil
        }
        return super.hitTest(point, with: event)
    }
}
#endif

/// Explicit UIKit-backed semantic colors for `QuestOverlayView` so material vibrancy inside
/// `PassthroughOverlayWindow` never washes out secondary labels or checklist icons.
private enum OverlayPalette {
    #if canImport(UIKit)
    static let primaryText = Color(uiColor: .label)
    static let secondaryText = Color(uiColor: .secondaryLabel)
    static let tertiaryText = Color(uiColor: .tertiaryLabel)
    static let uncheckedIcon = Color(uiColor: .secondaryLabel)
    static let checkedIcon = Color(red: 0.08, green: 0.50, blue: 0.24)
    static let accentTeal = Color(uiColor: .systemTeal)
    static let surfaceFill = Color(uiColor: .secondarySystemBackground)
    static let strokeBorder = Color(uiColor: .separator)
    #else
    static let primaryText = Color.primary
    static let secondaryText = Color.secondary
    static let tertiaryText = Color.secondary.opacity(0.75)
    static let uncheckedIcon = Color.secondary
    static let checkedIcon = Color(red: 0.08, green: 0.50, blue: 0.24)
    static let accentTeal = Color.teal
    static let surfaceFill = Color.gray.opacity(0.18)
    static let strokeBorder = Color.primary.opacity(0.14)
    #endif
}

/// Floating quest overlay card and collapsed pill displayed while a quest is active.
public struct QuestOverlayView: View {
    private let questState: HollerKitQuestState
    @State private var dragOffset: CGSize = .zero
    @State private var accumulatedOffset: CGSize = .zero
    @State private var cardSize: CGSize = .zero
    private var viewportSize: CGSize
    private var onFrameChange: (CGRect) -> Void

    /// Maximum width of the floating quest overlay card and collapsed pill.
    public static let maxOverlayWidth: CGFloat = 340

    /// Animation curve used when morphing between the collapsed pill and expanded card or updating step/mark state.
    public static let overlayAnimation: Animation = .snappy(duration: 0.24, extraBounce: 0)

    /// Formats the Mark button title for a given number of captured marks.
    public static func markButtonTitle(for markCount: Int) -> String {
        markCount <= 0 ? "Mark" : "Mark (\(markCount))"
    }

    /// Formats the compact step progress summary for the collapsed pill, or `nil` when the quest has no steps.
    public static func stepProgressSummary(checkedCount: Int, totalSteps: Int) -> String? {
        guard totalSteps > 0 else { return nil }
        return "\(min(max(0, checkedCount), totalSteps))/\(totalSteps)"
    }

    public init(
        questState: HollerKitQuestState = HollerKit.quests,
        viewportSize: CGSize = .zero,
        onFrameChange: @escaping (CGRect) -> Void = { _ in }
    ) {
        self.questState = questState
        self.viewportSize = viewportSize
        self.onFrameChange = onFrameChange
    }

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                let raw = CGSize(
                    width: accumulatedOffset.width + value.translation.width,
                    height: accumulatedOffset.height + value.translation.height
                )
                let clamped = clampOffset(raw, viewportSize: viewportSize, cardSize: cardSize)
                dragOffset = CGSize(
                    width: clamped.width - accumulatedOffset.width,
                    height: clamped.height - accumulatedOffset.height
                )
            }
            .onEnded { value in
                let raw = CGSize(
                    width: accumulatedOffset.width + value.translation.width,
                    height: accumulatedOffset.height + value.translation.height
                )
                accumulatedOffset = clampOffset(raw, viewportSize: viewportSize, cardSize: cardSize)
                dragOffset = .zero
            }
    }

    public var body: some View {
        if let session = questState.activeQuest,
           !session.isPresentingResultSheet,
           !session.isSubmitted {
            VStack(spacing: 0) {
                if session.isOverlayExpanded {
                    expandedCard(session: session)
                        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottom)))
                } else {
                    collapsedPill(session: session)
                        .gesture(dragGesture)
                        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottom)))
                }
            }
            .animation(Self.overlayAnimation, value: session.isOverlayExpanded)
            .animation(Self.overlayAnimation, value: session.stepsChecked)
            .animation(Self.overlayAnimation, value: session.marks.count)
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .onAppear {
                            cardSize = proxy.size
                            accumulatedOffset = clampOffset(accumulatedOffset, viewportSize: viewportSize, cardSize: proxy.size)
                            onFrameChange(proxy.frame(in: .global))
                        }
                        .onChange(of: proxy.size) { _, newSize in
                            cardSize = newSize
                            accumulatedOffset = clampOffset(accumulatedOffset, viewportSize: viewportSize, cardSize: newSize)
                            onFrameChange(proxy.frame(in: .global))
                        }
                        .onChange(of: proxy.frame(in: .global)) { _, newFrame in
                            onFrameChange(newFrame)
                        }
                        .onChange(of: session.id) { _, _ in
                            cardSize = proxy.size
                            accumulatedOffset = clampOffset(accumulatedOffset, viewportSize: viewportSize, cardSize: proxy.size)
                            onFrameChange(proxy.frame(in: .global))
                        }
                        .onChange(of: session.isOverlayExpanded) { _, _ in
                            cardSize = proxy.size
                            accumulatedOffset = clampOffset(accumulatedOffset, viewportSize: viewportSize, cardSize: proxy.size)
                            onFrameChange(proxy.frame(in: .global))
                        }
                        .onChange(of: session.stepsChecked) { _, _ in
                            cardSize = proxy.size
                            onFrameChange(proxy.frame(in: .global))
                        }
                        .onChange(of: session.marks.count) { _, _ in
                            cardSize = proxy.size
                            onFrameChange(proxy.frame(in: .global))
                        }
                        .onDisappear {
                            onFrameChange(.zero)
                        }
                }
            )
            .onChange(of: viewportSize) { _, newViewport in
                accumulatedOffset = clampOffset(accumulatedOffset, viewportSize: newViewport, cardSize: cardSize)
            }
            .offset(
                x: accumulatedOffset.width + dragOffset.width,
                y: accumulatedOffset.height + dragOffset.height
            )
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("HollerKitQuestOverlayView")
        }
    }

    /// Clamps the proposed drag offset so the floating overlay stays within safe viewport margins.
    private func clampOffset(_ proposed: CGSize, viewportSize: CGSize, cardSize: CGSize) -> CGSize {
        guard viewportSize.width > 0, viewportSize.height > 0, cardSize.width > 0, cardSize.height > 0 else {
            return proposed
        }
        let horizontalPadding: CGFloat = 16
        let bottomPadding: CGFloat = 28
        let topPadding: CGFloat = 16
        let maxX = max(0, (viewportSize.width - cardSize.width) / 2 - horizontalPadding)
        let minY = -max(0, viewportSize.height - cardSize.height - bottomPadding - topPadding)
        let maxY: CGFloat = 0

        return CGSize(
            width: min(max(proposed.width, -maxX), maxX),
            height: min(max(proposed.height, minY), maxY)
        )
    }

    /// Renders a stable-width Mark button label so incrementing the mark count never resizes the button or shifts neighbor controls.
    private func markButtonLabel(markCount: Int, iconSpacing: CGFloat) -> some View {
        let visibleTitle = Self.markButtonTitle(for: markCount)
        let reservationCount = max(99, markCount)
        let reservationTitle = Self.markButtonTitle(for: reservationCount)

        return HStack(spacing: iconSpacing) {
            Image(systemName: "camera.viewfinder")
                .symbolRenderingMode(.monochrome)

            ZStack(alignment: .center) {
                Text(reservationTitle)
                    .monospacedDigit()
                    .lineLimit(1)
                    .hidden()
                    .accessibilityHidden(true)

                Text(visibleTitle)
                    .monospacedDigit()
                    .lineLimit(1)
                    .contentTransition(.numericText(value: Double(markCount)))
            }
        }
        .font(.caption.weight(.semibold))
        .fixedSize(horizontal: true, vertical: true)
    }

    /// Renders the compact floating pill for the active quest session.
    private func collapsedPill(session: ActiveQuestSession) -> some View {
        let checkedCount = session.stepsChecked.filter { $0 }.count
        let totalSteps = session.quest.definition.steps.count

        return HStack(spacing: 10) {
            Button {
                withAnimation(Self.overlayAnimation) {
                    questState.setOverlayExpanded(true)
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "flag.checkered")
                        .symbolRenderingMode(.monochrome)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(OverlayPalette.accentTeal)

                    Text(session.quest.definition.title)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(OverlayPalette.primaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Spacer(minLength: 0)

                    if let progressSummary = Self.stepProgressSummary(checkedCount: checkedCount, totalSteps: totalSteps) {
                        ZStack(alignment: .trailing) {
                            Text("\(totalSteps)/\(totalSteps)")
                                .font(.caption2.weight(.semibold).monospacedDigit())
                                .lineLimit(1)
                                .hidden()
                                .accessibilityHidden(true)

                            Text(progressSummary)
                                .font(.caption2.weight(.semibold).monospacedDigit())
                                .foregroundStyle(checkedCount == totalSteps ? OverlayPalette.checkedIcon : OverlayPalette.secondaryText)
                                .lineLimit(1)
                                .contentTransition(.numericText(value: Double(checkedCount)))
                        }
                        .fixedSize(horizontal: true, vertical: true)
                        .accessibilityIdentifier("HollerKitQuestStepProgressText")
                    }

                    ElapsedTimerText(startedAt: session.startedAt)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("HollerKitQuestExpandButton")

            Divider()
                .frame(height: 18)

            Button {
                withAnimation(Self.overlayAnimation) {
                    _ = questState.captureMark()
                }
            } label: {
                markButtonLabel(markCount: session.marks.count, iconSpacing: 4)
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .fixedSize(horizontal: true, vertical: true)
            .accessibilityIdentifier("HollerKitQuestMarkButton")
            .accessibilityValue("\(session.marks.count)")

            Button {
                withAnimation(Self.overlayAnimation) {
                    questState.presentResultSheet()
                }
            } label: {
                Text("Done")
                    .font(.caption.weight(.bold))
                    .lineLimit(1)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.mini)
            .fixedSize(horizontal: true, vertical: true)
            .accessibilityIdentifier("HollerKitQuestDoneButton")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: Self.maxOverlayWidth)
        .fixedSize(horizontal: false, vertical: true)
        .background {
            ZStack {
                Capsule()
                    .fill(.ultraThinMaterial)
                Capsule()
                    .fill(OverlayPalette.surfaceFill.opacity(0.94))
            }
        }
        .overlay {
            Capsule()
                .stroke(OverlayPalette.strokeBorder.opacity(0.45), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.16), radius: 10, y: 4)
    }

    /// Renders the expanded floating quest card with setup, interactive step checklist, and expectations.
    private func expandedCard(session: ActiveQuestSession) -> some View {
        let maxInstructionsHeight: CGFloat = viewportSize.height > 0
            ? min(240, max(110, viewportSize.height * 0.36))
            : 200

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.quest.definition.area.uppercased())
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(OverlayPalette.accentTeal)
                        .lineLimit(1)
                    Text(session.quest.definition.title)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(OverlayPalette.primaryText)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                ElapsedTimerText(startedAt: session.startedAt)
                    .fixedSize(horizontal: true, vertical: false)

                Button {
                    withAnimation(Self.overlayAnimation) {
                        questState.setOverlayExpanded(false)
                    }
                } label: {
                    Image(systemName: "chevron.down.circle.fill")
                        .symbolRenderingMode(.hierarchical)
                        .font(.title3)
                        .foregroundStyle(OverlayPalette.secondaryText)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Collapse Quest Overlay")
                .accessibilityIdentifier("HollerKitQuestCollapseButton")
            }
            .contentShape(Rectangle())
            .gesture(dragGesture)

            Divider()

            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 10) {
                    if !session.quest.definition.setup.isEmpty {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Setup")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(OverlayPalette.secondaryText)
                            ForEach(Array(session.quest.definition.setup.enumerated()), id: \.offset) { _, line in
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: "gearshape")
                                        .symbolRenderingMode(.monochrome)
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(OverlayPalette.secondaryText)
                                        .frame(width: 16, height: 14, alignment: .center)
                                    Text(line)
                                        .font(.caption)
                                        .foregroundStyle(OverlayPalette.secondaryText)
                                        .multilineTextAlignment(.leading)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Spacer(minLength: 0)
                                }
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        let checkedCount = session.stepsChecked.filter { $0 }.count
                        let totalSteps = session.quest.definition.steps.count
                        HStack {
                            ZStack(alignment: .leading) {
                                Text("Steps (\(totalSteps)/\(totalSteps))")
                                    .font(.caption.weight(.semibold).monospacedDigit())
                                    .lineLimit(1)
                                    .hidden()
                                    .accessibilityHidden(true)

                                Text("Steps (\(checkedCount)/\(totalSteps))")
                                    .font(.caption.weight(.semibold).monospacedDigit())
                                    .foregroundStyle(OverlayPalette.secondaryText)
                                    .lineLimit(1)
                                    .contentTransition(.numericText(value: Double(checkedCount)))
                            }
                            .fixedSize(horizontal: true, vertical: false)
                            .accessibilityIdentifier("HollerKitQuestStepsHeader")

                            Spacer()
                            if totalSteps > 0 {
                                Text("Tap to check off")
                                    .font(.caption2)
                                    .foregroundStyle(OverlayPalette.tertiaryText)
                            }
                        }

                        ForEach(Array(session.quest.definition.steps.enumerated()), id: \.offset) { index, step in
                            let isChecked = session.stepsChecked.indices.contains(index) && session.stepsChecked[index]
                            Button {
                                withAnimation(Self.overlayAnimation) {
                                    questState.toggleStep(at: index)
                                }
                            } label: {
                                HStack(alignment: .top, spacing: 8) {
                                    Group {
                                        if isChecked {
                                            Image(systemName: "checkmark.circle.fill")
                                                .symbolRenderingMode(.palette)
                                                .foregroundStyle(Color.white, OverlayPalette.checkedIcon)
                                        } else {
                                            Image(systemName: "circle")
                                                .symbolRenderingMode(.monochrome)
                                                .foregroundStyle(OverlayPalette.uncheckedIcon)
                                        }
                                    }
                                    .font(.system(size: 13, weight: .semibold))
                                    .frame(width: 16, height: 14, alignment: .center)

                                    Text(step)
                                        .font(.caption)
                                        .foregroundStyle(isChecked ? OverlayPalette.secondaryText : OverlayPalette.primaryText)
                                        .strikethrough(isChecked, color: OverlayPalette.secondaryText)
                                        .multilineTextAlignment(.leading)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Spacer(minLength: 0)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityValue(isChecked ? "checked" : "unchecked")
                            .accessibilityIdentifier("HollerKitQuestStep_\(index)")
                        }
                    }

                    if !session.quest.definition.expect.isEmpty {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Expect")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(OverlayPalette.secondaryText)
                            ForEach(Array(session.quest.definition.expect.enumerated()), id: \.offset) { _, exp in
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: "sparkles")
                                        .symbolRenderingMode(.monochrome)
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(OverlayPalette.accentTeal)
                                        .frame(width: 16, height: 14, alignment: .center)
                                    Text(exp)
                                        .font(.caption)
                                        .foregroundStyle(OverlayPalette.primaryText)
                                        .multilineTextAlignment(.leading)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Spacer(minLength: 0)
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: maxInstructionsHeight)

            HStack(spacing: 8) {
                Button {
                    withAnimation(Self.overlayAnimation) {
                        _ = questState.captureMark()
                    }
                } label: {
                    markButtonLabel(markCount: session.marks.count, iconSpacing: 5)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityIdentifier("HollerKitQuestMarkButton")
                .accessibilityValue("\(session.marks.count)")

                Button(role: .destructive) {
                    Task {
                        await questState.abandonActiveQuest()
                    }
                } label: {
                    Text("Abandon")
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityIdentifier("HollerKitQuestAbandonButton")

                Spacer()

                Button {
                    withAnimation(Self.overlayAnimation) {
                        questState.presentResultSheet()
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "checkmark.circle.fill")
                            .symbolRenderingMode(.monochrome)
                        Text("Done")
                            .lineLimit(1)
                    }
                    .font(.caption.weight(.bold))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityIdentifier("HollerKitQuestDoneButton")
            }
            .contentShape(Rectangle())
            .gesture(dragGesture)
        }
        .padding(14)
        .frame(maxWidth: Self.maxOverlayWidth)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.regularMaterial)
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(OverlayPalette.surfaceFill.opacity(0.94))
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(OverlayPalette.strokeBorder.opacity(0.45), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.2), radius: 14, y: 6)
    }
}

private struct QuestOverlayRootView: View {
    var questState: HollerKitQuestState
    var onFrameChange: (CGRect) -> Void
    @State private var presentedSessionId: UUID?

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottom) {
                Color.clear
                    .ignoresSafeArea()
                    .allowsHitTesting(false)

                QuestOverlayView(
                    questState: questState,
                    viewportSize: proxy.size,
                    onFrameChange: onFrameChange
                )
                .padding(.horizontal, 16)
                .padding(.bottom, 28)
            }
            .animation(.spring(response: 0.28, dampingFraction: 0.84), value: questState.activeQuest?.isPresentingResultSheet)
            .animation(.spring(response: 0.28, dampingFraction: 0.84), value: questState.activeQuest?.isSubmitted)
        }
        .onAppear {
            if let activeId = questState.activeQuest?.id {
                presentedSessionId = activeId
            }
        }
        .onChange(of: questState.activeQuest?.id) { _, newId in
            if let newId {
                presentedSessionId = newId
            }
        }
        .sheet(
            isPresented: Binding(
                get: { questState.activeQuest?.isPresentingResultSheet == true },
                set: { newValue in
                    if !newValue {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                            questState.dismissResultSheet()
                        }
                    }
                }
            ),
            onDismiss: {
                QuestOverlayWindowManager.shared.completePendingHideIfNeeded()
            }
        ) {
            QuestResultSheet(questState: questState)
                .id(presentedSessionId)
        }
    }
}

private struct ElapsedTimerText: View {
    var startedAt: Date

    var body: some View {
        TimelineView(.periodic(from: startedAt, by: 1.0)) { context in
            let seconds = max(0, Int(context.date.timeIntervalSince(startedAt)))
            let minutes = seconds / 60
            let remainder = seconds % 60
            let formatted = String(format: "%d:%02d", minutes, remainder)
            let reservation = minutes >= 100 ? String(format: "%d:00", minutes) : "99:59"

            ZStack(alignment: .trailing) {
                Text(reservation)
                    .font(.caption2.monospacedDigit())
                    .lineLimit(1)
                    .hidden()
                    .accessibilityHidden(true)

                Text(formatted)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(OverlayPalette.secondaryText)
                    .lineLimit(1)
                    .contentTransition(.numericText(value: Double(seconds)))
            }
            .fixedSize(horizontal: true, vertical: true)
        }
        .fixedSize(horizontal: true, vertical: true)
    }
}
