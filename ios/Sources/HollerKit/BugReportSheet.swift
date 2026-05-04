import SwiftUI

public struct BugReportSheet: View {
    private let configuration: HollerKitConfiguration?
    private let breadcrumbs: BreadcrumbStore
    @State private var comment = ""

    init(configuration: HollerKitConfiguration?, breadcrumbs: BreadcrumbStore) {
        self.configuration = configuration
        self.breadcrumbs = breadcrumbs
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $comment)
                        .frame(minHeight: 140)
                }

                if configuration?.audio.isEnabled == true {
                    Section {
                        Button("Record Audio") {}
                    }
                }
            }
            .navigationTitle("Report a Bug")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Submit") {}
                        .disabled(comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .accessibilityIdentifier("HollerKitBugReportSheet")
    }
}
