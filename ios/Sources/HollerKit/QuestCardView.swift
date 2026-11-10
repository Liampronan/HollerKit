import SwiftUI

public struct QuestCardView: View {
    public var item: QuestBoardItem
    public var isActive: Bool
    public var isDisabled: Bool
    public var onStart: () -> Void

    public init(
        item: QuestBoardItem,
        isActive: Bool = false,
        isDisabled: Bool = false,
        onStart: @escaping () -> Void
    ) {
        self.item = item
        self.isActive = isActive
        self.isDisabled = isDisabled
        self.onStart = onStart
    }

    public var buttonTitle: String {
        if isActive {
            return "Running..."
        }
        return item.status == .passed ? "Re-run Quest" : "Start Quest"
    }

    public var buttonSystemImage: String {
        isActive ? "play.circle.fill" : "play.fill"
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 8) {
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

            Text(item.definition.title)
                .font(.headline)
                .foregroundStyle(.primary)

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
                VStack(alignment: .leading, spacing: 4) {
                    Text("Setup")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(Array(item.definition.setup.enumerated()), id: \.offset) { _, line in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "gearshape")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .padding(.top, 2)
                            Text(line)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Steps")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(Array(item.definition.steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .top, spacing: 6) {
                        Text("\(index + 1).")
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(step)
                            .font(.caption)
                            .foregroundStyle(.primary)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Expect")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(Array(item.definition.expect.enumerated()), id: \.offset) { _, expectation in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "checkmark.diamond")
                            .font(.caption2)
                            .foregroundStyle(.teal)
                            .padding(.top, 2)
                        Text(expectation)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
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
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("HollerKitQuestCard_\(item.id)")
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
            return "Pending"
        case .passed:
            return "Passed"
        case .failed:
            return "Failed"
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
        }
    }
}
