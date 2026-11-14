import SwiftUI

public struct QuestCardView: View {
    public var item: QuestBoardItem
    public var isActive: Bool
    public var isDisabled: Bool
    public var onToggleExpand: (() -> Void)?
    public var onStart: () -> Void

    @State private var internalIsExpanded: Bool
    private let initialIsExpanded: Bool
    private var externalIsExpanded: Binding<Bool>?

    public init(
        item: QuestBoardItem,
        isActive: Bool = false,
        isDisabled: Bool = false,
        isExpanded: Bool = false,
        onToggleExpand: (() -> Void)? = nil,
        onStart: @escaping () -> Void
    ) {
        self.item = item
        self.isActive = isActive
        self.isDisabled = isDisabled
        self.onToggleExpand = onToggleExpand
        self.onStart = onStart
        self._internalIsExpanded = State(initialValue: isExpanded)
        self.initialIsExpanded = isExpanded
        self.externalIsExpanded = nil
    }

    public init(
        item: QuestBoardItem,
        isActive: Bool = false,
        isDisabled: Bool = false,
        isExpanded: Binding<Bool>,
        onToggleExpand: (() -> Void)? = nil,
        onStart: @escaping () -> Void
    ) {
        self.item = item
        self.isActive = isActive
        self.isDisabled = isDisabled
        self.onToggleExpand = onToggleExpand
        self.onStart = onStart
        self._internalIsExpanded = State(initialValue: isExpanded.wrappedValue)
        self.initialIsExpanded = isExpanded.wrappedValue
        self.externalIsExpanded = isExpanded
    }

    /// Whether the card's detail body (area, setup, steps, expectations, needs, latest run, and Start button) is disclosed.
    public var isExpanded: Bool {
        externalIsExpanded?.wrappedValue ?? internalIsExpanded
    }

    /// The SF Symbol name displayed for the card's disclosure indicator.
    public var disclosureChevronSystemImage: String {
        isExpanded ? "chevron.down" : "chevron.right"
    }

    /// Whether the collapsed header row displays a compact status or active-session badge alongside the title.
    public var showsCollapsedStatusBadge: Bool {
        isActive || item.status != .pending
    }

    /// The localized title displayed inside the card's primary action button.
    public var buttonTitle: String {
        if isActive {
            return "Running..."
        }
        return item.status == .passed ? "Re-run Quest" : "Start Quest"
    }

    /// The SF Symbol name displayed alongside `buttonTitle` in the card's primary action button.
    public var buttonSystemImage: String {
        isActive ? "play.circle.fill" : "play.fill"
    }

    private func toggleExpansion() {
        withAnimation(.snappy(duration: 0.22)) {
            if let externalIsExpanded {
                externalIsExpanded.wrappedValue.toggle()
            } else {
                internalIsExpanded.toggle()
            }
        }
        onToggleExpand?()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: toggleExpansion) {
                HStack(alignment: .center, spacing: 10) {
                    Text(item.definition.title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 8)

                    if isActive {
                        ActiveSessionBadge()
                    } else if !isExpanded && item.status != .pending {
                        StatusBadge(status: item.status)
                    }

                    Image(systemName: disclosureChevronSystemImage)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16, alignment: .center)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("HollerKitQuestDisclosure_\(item.id)")
            .accessibilityValue(isExpanded ? "expanded" : "collapsed")
            .accessibilityHint(
                isExpanded
                    ? "Double tap to hide quest details"
                    : "Double tap to show quest details and start button"
            )

            if isExpanded {
                VStack(alignment: .leading, spacing: 12) {
                    Divider()

                    HStack(alignment: .center, spacing: 8) {
                        Text(item.definition.area.uppercased())
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.accentColor.opacity(0.14))
                            .foregroundStyle(Color.accentColor)
                            .clipShape(Capsule())

                        StatusBadge(status: item.status)

                        Spacer()

                        Text("v\(item.version)")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }

                    if !item.needWarnings.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(item.needWarnings, id: \.self) { warning in
                                    HStack(spacing: 4) {
                                        Image(systemName: "exclamationmark.triangle.fill")
                                        Text(warning)
                                    }
                                    .font(.caption2.weight(.medium))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color.orange.opacity(0.15))
                                    .foregroundStyle(.orange)
                                    .clipShape(Capsule())
                                }
                            }
                        }
                    }

                    if !item.definition.setup.isEmpty {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Setup")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            ForEach(Array(item.definition.setup.enumerated()), id: \.offset) { _, line in
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: "gearshape")
                                        .symbolRenderingMode(.monochrome)
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 16, height: 14, alignment: .center)
                                    Text(line)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .multilineTextAlignment(.leading)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 5) {
                        Text("Steps")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ForEach(Array(item.definition.steps.enumerated()), id: \.offset) { index, step in
                            HStack(alignment: .top, spacing: 8) {
                                Text("\(index + 1).")
                                    .font(.caption.monospacedDigit().weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 16, height: 14, alignment: .center)
                                Text(step)
                                    .font(.caption)
                                    .foregroundStyle(.primary)
                                    .multilineTextAlignment(.leading)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }

                    if !item.definition.expect.isEmpty {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Expect")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            ForEach(Array(item.definition.expect.enumerated()), id: \.offset) { _, expectation in
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: "sparkles")
                                        .symbolRenderingMode(.monochrome)
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(.teal)
                                        .frame(width: 16, height: 14, alignment: .center)
                                    Text(expectation)
                                        .font(.caption)
                                        .foregroundStyle(.primary)
                                        .multilineTextAlignment(.leading)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }

                    if let latestRun = item.latestRun {
                        LatestRunSummaryView(latestRun: latestRun)
                            .accessibilityIdentifier("HollerKitQuestLatestRun_\(item.id)")
                    }

                    HStack(spacing: 8) {
                        if let route = item.definition.start, !route.isEmpty {
                            HStack(spacing: 4) {
                                Image(systemName: "link")
                                Text(route)
                                    .lineLimit(1)
                            }
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier("HollerKitQuestStartRoute_\(item.id)")
                        }

                        Spacer(minLength: 8)

                        Button(action: onStart) {
                            HStack(spacing: 6) {
                                Image(systemName: buttonSystemImage)
                                Text(buttonTitle)
                            }
                            .font(.subheadline.weight(.semibold))
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(isActive || isDisabled)
                        .accessibilityIdentifier("HollerKitStartQuestButton_\(item.id)")
                    }
                    .padding(.top, 4)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("HollerKitQuestDetails_\(item.id)")
            }
        }
        .padding(.vertical, 4)
        .onChange(of: initialIsExpanded) { _, newValue in
            if externalIsExpanded == nil {
                internalIsExpanded = newValue
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("HollerKitQuestCard_\(item.id)")
    }
}

private struct ActiveSessionBadge: View {
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "play.circle.fill")
            Text("Running")
        }
        .font(.caption2.weight(.semibold))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.accentColor.opacity(0.14))
        .foregroundStyle(Color.accentColor)
        .clipShape(Capsule())
    }
}

private struct LatestRunSummaryView: View {
    var latestRun: QuestLatestRun

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Image(systemName: iconName)
                    .foregroundStyle(tintColor)
                Text("Last run: \(latestRun.formattedSummary())")
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
            }
            .font(.caption2)

            if let commentLine = latestRun.firstCommentLine {
                Text("\u{201C}\(commentLine)\u{201D}")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(tintColor.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var iconName: String {
        switch latestRun.result {
        case .pass:
            return "checkmark.circle.fill"
        case .fail:
            return "exclamationmark.circle.fill"
        case .unsure:
            return "questionmark.circle.fill"
        case .abandoned:
            return "xmark.circle"
        }
    }

    private var tintColor: Color {
        switch latestRun.result {
        case .pass:
            return .green
        case .fail:
            return .red
        case .unsure:
            return .orange
        case .abandoned:
            return .secondary
        }
    }
}

private struct StatusBadge: View {
    var status: QuestStatus

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: iconName)
            Text(label)
        }
        .font(.caption2.weight(.semibold))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(tintColor.opacity(0.14))
        .foregroundStyle(tintColor)
        .clipShape(Capsule())
    }

    private var label: String {
        switch status {
        case .pending:
            return "Untried"
        case .passed:
            return "Passed"
        case .failed:
            return "Failed"
        case .unsure:
            return "Unsure"
        }
    }

    private var iconName: String {
        switch status {
        case .pending:
            return "clock"
        case .passed:
            return "checkmark.circle.fill"
        case .failed:
            return "exclamationmark.circle.fill"
        case .unsure:
            return "questionmark.circle.fill"
        }
    }

    private var tintColor: Color {
        switch status {
        case .pending:
            return .blue
        case .passed:
            return .green
        case .failed:
            return .red
        case .unsure:
            return .orange
        }
    }
}
