import SwiftUI

public struct QuestBoardView: View {
    @ObservedObject private var questState: HollerKitQuestState
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTab: BoardTab = .pending

    private enum BoardTab: String, CaseIterable, Identifiable {
        case pending = "Pending"
        case completed = "Completed"

        var id: Self { self }
    }

    public init(questState: HollerKitQuestState = HollerKit.quests) {
        self.questState = questState
    }

    public var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Filter", selection: $selectedTab) {
                        Text("Pending (\(questState.pendingQuests.count))")
                            .tag(BoardTab.pending)
                        Text("Completed (\(questState.completedQuests.count))")
                            .tag(BoardTab.completed)
                    }
                    .pickerStyle(.segmented)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    .listRowBackground(Color.clear)
                }

                if !questState.isBackendReachable {
                    Section {
                        Label(
                            "Offline mode — showing cached quest statuses. Runs will queue in the outbox.",
                            systemImage: "wifi.slash"
                        )
                        .font(.footnote)
                        .foregroundStyle(.orange)
                    }
                }

                let displayedQuests = selectedTab == .pending
                    ? questState.pendingQuests
                    : questState.completedQuests

                if displayedQuests.isEmpty {
                    Section {
                        VStack(spacing: 10) {
                            if questState.quests.isEmpty, let error = questState.lastSyncError {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 32))
                                    .foregroundStyle(.orange)
                                Text(error)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                            } else if questState.quests.isEmpty {
                                Image(systemName: "checklist")
                                    .font(.system(size: 32))
                                    .foregroundStyle(.secondary)
                                Text("No quests configured for this build.")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            } else {
                                Image(systemName: selectedTab == .pending ? "checkmark.seal.fill" : "checklist")
                                    .font(.system(size: 32))
                                    .foregroundStyle(.secondary)
                                Text(selectedTab == .pending ? "All quests completed for this build!" : "No completed quests yet.")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                    }
                } else if selectedTab == .pending {
                    if !questState.untriedQuests.isEmpty {
                        Section("Untried (\(questState.untriedQuests.count))") {
                            ForEach(questState.untriedQuests) { item in
                                questCardRow(for: item)
                            }
                        }
                    }

                    if !questState.needsAttentionQuests.isEmpty {
                        Section("Needs Attention (\(questState.needsAttentionQuests.count))") {
                            ForEach(questState.needsAttentionQuests) { item in
                                questCardRow(for: item)
                            }
                        }
                    }
                } else {
                    Section("Completed Quests") {
                        ForEach(questState.completedQuests) { item in
                            questCardRow(for: item)
                        }
                    }
                }
            }
            .navigationTitle("QA Quests")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task {
                            await questState.refresh()
                        }
                    } label: {
                        if questState.isSyncing {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .disabled(questState.isSyncing)
                    .accessibilityLabel("Refresh Quests")
                }
            }
            .task {
                await questState.refresh()
            }
        }
        .accessibilityIdentifier("HollerKitQuestBoardView")
    }

    @ViewBuilder
    private func questCardRow(for item: QuestBoardItem) -> some View {
        let isCurrentActive = questState.activeQuest?.quest.id == item.id
        let isAnyActive = questState.activeQuest != nil
        QuestCardView(
            item: item,
            isActive: isCurrentActive,
            isDisabled: isAnyActive && !isCurrentActive,
            onStart: {
                questState.startQuest(item)
            }
        )
    }
}
