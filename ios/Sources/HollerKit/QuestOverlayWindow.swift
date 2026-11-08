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
    #endif

    private init() {}

    public var isOverlayVisible: Bool {
        #if canImport(UIKit)
        return overlayWindow?.isHidden == false
        #else
        return false
        #endif
    }

    #if canImport(UIKit)
    public func show(questState: HollerKitQuestState, in windowScene: UIWindowScene? = nil) {
        guard let targetScene = windowScene ?? activeWindowScene() else { return }
        boundWindowScene = targetScene

        let window: PassthroughOverlayWindow
        if let existing = overlayWindow, existing.windowScene === targetScene {
            window = existing
        } else {
            overlayWindow?.isHidden = true
            window = PassthroughOverlayWindow(windowScene: targetScene)
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
        window.isHidden = false
    }
    #else
    public func show(questState: HollerKitQuestState) {}
    #endif

    public func hide() {
        #if canImport(UIKit)
        overlayWindow?.isHidden = true
        overlayWindow?.rootViewController = nil
        overlayWindow = nil
        boundWindowScene = nil
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

public struct QuestOverlayView: View {
    @ObservedObject private var questState: HollerKitQuestState
    @State private var dragOffset: CGSize = .zero
    @State private var accumulatedOffset: CGSize = .zero
    @State private var cardSize: CGSize = .zero
    private var viewportSize: CGSize
    private var onFrameChange: (CGRect) -> Void

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
        if let session = questState.activeQuest {
            VStack(spacing: 0) {
                if session.isOverlayExpanded {
                    expandedCard(session: session)
                } else {
                    collapsedPill(session: session)
                        .gesture(dragGesture)
                }
            }
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
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("HollerKitQuestOverlayView")
        }
    }

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

    private func collapsedPill(session: ActiveQuestSession) -> some View {
        HStack(spacing: 10) {
            Button {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                    questState.setOverlayExpanded(true)
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "flag.checkered")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.teal)

                    Text(session.quest.definition.title)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    ElapsedTimerText(startedAt: session.startedAt)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("HollerKitQuestExpandButton")

            Divider()
                .frame(height: 18)

            Button {
                questState.captureMark()
            } label: {
                Label(
                    session.marks.isEmpty ? "Mark" : "Mark (\(session.marks.count))",
                    systemImage: "camera.viewfinder"
                )
                .font(.caption.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .accessibilityIdentifier("HollerKitQuestMarkButton")
            .accessibilityValue("\(session.marks.count)")

            Button {
                questState.presentResultSheet()
            } label: {
                Text("Done")
                    .font(.caption.weight(.bold))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.mini)
            .accessibilityIdentifier("HollerKitQuestDoneButton")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay {
            Capsule()
                .stroke(Color.primary.opacity(0.14), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.16), radius: 10, y: 4)
    }

    private func expandedCard(session: ActiveQuestSession) -> some View {
        let maxInstructionsHeight: CGFloat = viewportSize.height > 0
            ? min(240, max(110, viewportSize.height * 0.36))
            : 200

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.quest.definition.area.uppercased())
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.teal)
                    Text(session.quest.definition.title)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.primary)
                }

                Spacer()

                ElapsedTimerText(startedAt: session.startedAt)

                Button {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                        questState.setOverlayExpanded(false)
                    }
                } label: {
                    Image(systemName: "chevron.down.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
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
                    VStack(alignment: .leading, spacing: 6) {
                        let checkedCount = session.stepsChecked.filter { $0 }.count
                        let totalSteps = session.quest.definition.steps.count
                        HStack {
                            Text("Steps (\(checkedCount)/\(totalSteps))")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Spacer()
                            if totalSteps > 0 {
                                Text("Tap to check off")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }

                        ForEach(Array(session.quest.definition.steps.enumerated()), id: \.offset) { index, step in
                            let isChecked = session.stepsChecked.indices.contains(index) && session.stepsChecked[index]
                            Button {
                                questState.toggleStep(at: index)
                            } label: {
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: isChecked ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(isChecked ? .green : .secondary)
                                        .font(.subheadline)
                                    Text(step)
                                        .font(.caption)
                                        .foregroundStyle(isChecked ? .secondary : .primary)
                                        .strikethrough(isChecked)
                                        .multilineTextAlignment(.leading)
                                    Spacer(minLength: 0)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("HollerKitQuestStep_\(index)")
                        }
                    }

                    if !session.quest.definition.expect.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Expect")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            ForEach(Array(session.quest.definition.expect.enumerated()), id: \.offset) { _, exp in
                                HStack(alignment: .top, spacing: 6) {
                                    Image(systemName: "sparkles")
                                        .font(.caption2)
                                        .foregroundStyle(.teal)
                                        .padding(.top, 2)
                                    Text(exp)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
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
                    questState.captureMark()
                } label: {
                    Label(
                        session.marks.isEmpty ? "Mark" : "Mark (\(session.marks.count))",
                        systemImage: "camera.viewfinder"
                    )
                    .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier("HollerKitQuestMarkButton")
                .accessibilityValue("\(session.marks.count)")

                Button(role: .destructive) {
                    Task {
                        await questState.abandonActiveQuest()
                    }
                } label: {
                    Text("Abandon")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier("HollerKitQuestAbandonButton")

                Spacer()

                Button {
                    questState.presentResultSheet()
                } label: {
                    Label("Done", systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.bold))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .accessibilityIdentifier("HollerKitQuestDoneButton")
            }
            .contentShape(Rectangle())
            .gesture(dragGesture)
        }
        .padding(14)
        .frame(maxWidth: 340)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.primary.opacity(0.14), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.2), radius: 14, y: 6)
    }
}

private struct QuestOverlayRootView: View {
    @ObservedObject var questState: HollerKitQuestState
    var onFrameChange: (CGRect) -> Void

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
        }
        .sheet(
            isPresented: Binding(
                get: { questState.activeQuest?.isPresentingResultSheet == true },
                set: { newValue in
                    if !newValue {
                        questState.dismissResultSheet()
                    }
                }
            )
        ) {
            QuestResultSheet(questState: questState)
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
            Text(String(format: "%d:%02d", minutes, remainder))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}
