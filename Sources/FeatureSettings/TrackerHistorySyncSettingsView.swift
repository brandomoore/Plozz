#if canImport(SwiftUI)
import CoreModels
import CoreUI
import SwiftUI

struct TrackerHistorySyncSettingsView: View {
    let session: TrackerHistoryImportSession
    let sync: TrackerHistorySyncController
    @State private var accounts: Set<String> = []
    @State private var categories: Set<TrackerHistorySyncCategory> = []
    @State private var confirming = false
    @State private var operation: Task<Void, Never>?
    @State private var reviewedPlan: TrackerHistoryImportPlan?

    init(session: TrackerHistoryImportSession, sync: TrackerHistorySyncController) {
        self.session = session
        self.sync = sync
        _reviewedPlan = State(initialValue: session.plan)
    }

    var body: some View {
        PublicMetaDBPage {
            SettingsPageHeader("Ongoing sync")
            if sync.isBusy { ProgressView("Syncing…") }
            if let error = sync.error { TrackerHistoryImportFailure(error: error) }
            if sync.isEnabled, let grant = sync.grant {
                Text("New history syncs to your selected server users. Conflicts stay unchanged.")
                    .foregroundStyle(.secondary)
                if grant.categories == [.watched, .resume] {
                    Text("Watched and resume points")
                } else if grant.categories.contains(.watched) {
                    Text("Watched")
                } else {
                    Text("Resume points")
                }
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(session.destinations.filter { destination in
                        grant.scope.accounts.contains { $0.accountID == destination.id }
                    }) { destination in
                        Text("\(destination.serverName) · \(destination.userName)")
                    }
                }
                .accessibilityElement(children: .contain)
                if grant.reviewCount > 0 {
                    Text("Some changes need review. Compare with server history before retrying.")
                }
                if sync.hasMoreChanges { Text("More changes are waiting. Sync again to continue.") }
                Button("Sync now") { operation = Task { await sync.synchronize() } }
                    .disabled(sync.isBusy)
                    .accessibilityIdentifier("tracker-history.sync-now")
                Button("Turn off sync", role: .destructive) { sync.disable() }
                    .accessibilityIdentifier("tracker-history.disable-sync")
            } else {
                Text("Import new watched states or resume points on this device. Existing history stays unchanged.")
                    .foregroundStyle(.secondary)
                ForEach(session.destinations) { destination in
                    Toggle(
                        "\(destination.serverName) · \(destination.userName)",
                        isOn: Binding(
                            get: { accounts.contains(destination.id) },
                            set: { if $0 { accounts.insert(destination.id) } else { accounts.remove(destination.id) } }
                        )
                    )
                    .accessibilityIdentifier("tracker-history.sync-server.\(destination.id)")
                }
                Toggle("Watched", isOn: selection(.watched))
                    .accessibilityIdentifier("tracker-history.sync-watched")
                Toggle("Resume points", isOn: selection(.resume))
                    .accessibilityIdentifier("tracker-history.sync-resume")
                Button("Enable sync") { confirming = true }
                    .disabled(accounts.isEmpty || categories.isEmpty || reviewedPlan == nil || sync.isBusy)
                    .accessibilityIdentifier("tracker-history.enable-sync")
                if sync.grant?.enabled == true {
                    Text("The connection or server user changed. Review your selection to enable sync again.")
                    Button("Remove previous permission", role: .destructive) { sync.disable() }
                }
            }
        }
        .confirmationDialog("Enable ongoing sync?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Enable sync") {
                guard let reviewedPlan else { return }
                operation = Task {
                    await sync.enable(afterReview: reviewedPlan, accountIDs: accounts, categories: categories)
                }
            }
            .accessibilityIdentifier("tracker-history.confirm-sync")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Only new history will sync to the selected server users. Conflicts and removals require review. Profiles sharing those users will see the changes; server plugins may forward them. Other Plozz trackers are not updated.")
        }
        .onAppear { sync.reload() }
        .onDisappear { operation?.cancel() }
    }

    private func selection(_ category: TrackerHistorySyncCategory) -> Binding<Bool> {
        Binding(
            get: { categories.contains(category) },
            set: { if $0 { categories.insert(category) } else { categories.remove(category) } }
        )
    }
}
#endif
