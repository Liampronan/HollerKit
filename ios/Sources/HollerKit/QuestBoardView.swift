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
                            Image(systemName: selectedTab == .pending ? "checkmark.seal.fill" : "checklist")
                                .font(.system(size: 32))
                                .foregroundStyle(.secondary)
                            Text(selectedTab == .pending ? "All quests completed for this build!" : "No completed quests yet.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                    }
                } else {
                    Section(selectedTab == .pending ? "Pending Quests" : "Completed Quests") {
                        ForEach(displayedQuests) { item in
                            QuestCardView(
                                item: item,
                                isActive: questState.activeQuest?.quest.id == item.id,
                                onStart: {
                                    questState.startQuest(item)
                                }
                            )
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
}
