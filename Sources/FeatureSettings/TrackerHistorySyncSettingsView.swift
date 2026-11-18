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
        GroupedSettingsPage(title: "Ongoing sync", backIdentifier: "tracker-history.sync-back") {
            if sync.isBusy { ProgressView("Syncing…") }
            if let error = sync.error { TrackerHistoryImportFailure(error: error) }
            if sync.isEnabled, let grant = sync.grant {
                SettingsSectionGroup("Media shares") {
                    ForEach(session.destinations.filter { destination in
                        grant.scope.accounts.contains { $0.accountID == destination.id }
                    }) { destination in
                        Text("\(destination.serverName) · \(destination.userName)")
                    }
                }
                SettingsSectionGroup("What to sync") {
                    if grant.categories.contains(.watched) { Text("Watched") }
                    if grant.categories.contains(.resume) { Text("Resume points") }
                }
                SettingsSectionGroup {
                    if grant.reviewCount > 0 {
                        Text("Some changes need review. Compare histories before retrying.")
                    }
                    if sync.hasMoreChanges { Text("More changes are waiting. Sync again to continue.") }
                    Button("Sync now") { operation = Task { await sync.synchronize() } }
                        .settingsActionRow()
                        .disabled(sync.isBusy)
                        .accessibilityIdentifier("tracker-history.sync-now")
                    Button("Turn off sync", role: .destructive) { sync.disable() }
                        .settingsActionRow()
                        .accessibilityIdentifier("tracker-history.disable-sync")
                } footer: {
                    if !sync.identity.allowsForegroundChecks { Text("Use Sync now to import new history.") }
                }
            } else {
                if sync.grant?.enabled == true {
                    SettingsSectionGroup {
                        Text("Your previous permission no longer applies.")
                        Button("Remove previous permission", role: .destructive) { sync.disable() }
                            .settingsActionRow()
                    }
                }
                if !sync.eligibleAccountIDs.isEmpty {
                    SettingsSectionGroup("Media shares") {
                        ForEach(session.destinations.filter { sync.eligibleAccountIDs.contains($0.id) }) { destination in
                            Toggle(
                                "\(destination.serverName) · \(destination.userName)",
                                isOn: Binding(
                                    get: { accounts.contains(destination.id) },
                                    set: { if $0 { accounts.insert(destination.id) } else { accounts.remove(destination.id) } }
                                )
                            )
                            .accessibilityIdentifier("tracker-history.sync-server.\(destination.id)")
                        }
                    } footer: {
                        Text("Only this profile’s share history changes. Media servers keep their own history.")
                    }
                    SettingsSectionGroup("What to sync") {
                        if sync.supportedCategories.contains(.watched) {
                            Toggle("Watched", isOn: selection(.watched))
                                .accessibilityIdentifier("tracker-history.sync-watched")
                        }
                        if sync.supportedCategories.contains(.resume) {
                            Toggle("Resume points", isOn: selection(.resume))
                                .accessibilityIdentifier("tracker-history.sync-resume")
                        }
                    }
                    SettingsSectionGroup {
                        Button("Enable sync") { confirming = true }
                            .settingsActionRow()
                            .disabled(accounts.isEmpty || categories.isEmpty || reviewedPlan == nil || sync.isBusy)
                            .accessibilityIdentifier("tracker-history.enable-sync")
                    }
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
            Text("Only new tracker history will update this profile’s selected shares. Conflicts and removals require review. Media servers and other trackers are not updated.")
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
