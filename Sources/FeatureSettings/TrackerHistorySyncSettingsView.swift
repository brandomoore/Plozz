#if canImport(SwiftUI)
import CoreModels
import CoreUI
import SwiftUI

/// Creates the account-scoped session once, without fetching tracker history
/// while the user is browsing the account page.
public struct TrackerHistorySyncLink: View {
    @MainActor private final class Entry {
        let makeSession: @MainActor () -> TrackerHistoryImportSession
        lazy var session = makeSession()
        init(_ makeSession: @escaping @MainActor () -> TrackerHistoryImportSession) {
            self.makeSession = makeSession
        }
    }

    @State private var entry: Entry

    public init(makeSession: @escaping @MainActor () -> TrackerHistoryImportSession) {
        _entry = State(initialValue: Entry(makeSession))
    }

    public var body: some View {
        if let sync = entry.session.ongoingSync, sync.hasSettingsDestination {
            TrackerHistorySyncNavigationRow(session: entry.session, sync: sync)
        }
    }
}

extension TrackerHistorySyncController {
    var hasSettingsDestination: Bool {
        (!eligibleAccountIDs.isEmpty && !supportedCategories.isEmpty) || grant?.enabled == true
    }
}

struct TrackerHistorySyncNavigationRow: View {
    let session: TrackerHistoryImportSession
    let sync: TrackerHistorySyncController

    var body: some View {
        NavigationLink {
            TrackerHistorySyncSettingsView(session: session, sync: sync)
        } label: {
            SettingsDisclosureLabel { Text("Ongoing sync (Beta)") }
        }
        .settingsActionRow()
        .accessibilityIdentifier("tracker-history.ongoing-sync")
    }
}

struct TrackerHistorySyncSettingsView: View {
    let session: TrackerHistoryImportSession
    let sync: TrackerHistorySyncController
    @State private var reviewedPlan: TrackerHistoryImportPlan?
    @State private var operation: Task<Void, Never>?
    @State private var confirmingBeta = false
    @Environment(\.themePalette) private var palette

    init(session: TrackerHistoryImportSession, sync: TrackerHistorySyncController) {
        self.session = session
        self.sync = sync
        _reviewedPlan = State(initialValue: session.plan)
    }

    var body: some View {
        GroupedSettingsPage(title: "Ongoing sync (Beta)", backIdentifier: "tracker-history.sync-back") {
            if sync.isEnabled || (sync.grant?.enabled != true && !sync.eligibleAccountIDs.isEmpty && !sync.supportedCategories.isEmpty) {
                SettingsSectionGroup {
                    Toggle("Sync watch history", isOn: Binding(get: { sync.isEnabled }, set: setEnabled))
                        .accessibilityIdentifier("tracker-history.sync-enabled")
                        .disabled(!sync.isEnabled && sync.isBusy)
                        .confirmationDialog("Enable beta sync?", isPresented: $confirmingBeta, titleVisibility: .visible) {
                            Button("Enable beta sync") { enroll() }
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text("New tracker activity can change watch history on all current media shares in this profile, not your servers. Turning it off won’t undo those changes.")
                        }
                } footer: {
                    if sync.isEnabled {
                        Text("Only new tracker activity updates the selected shares. Turning sync off keeps their history.")
                    } else if sync.supportedCategories == [.watched] {
                        Text("New watched titles update all media shares in this profile, not your servers.")
                    } else if sync.supportedCategories == [.resume] {
                        Text("New playback positions update all media shares in this profile, not your servers.")
                    } else {
                        Text("New watched titles and playback positions update all media shares in this profile, not your servers.")
                    }
                }
            }
            if sync.isBusy { ProgressView("Syncing…") }
            if let error = sync.error { TrackerHistoryImportFailure(error: error) }
            if sync.isEnabled, let grant = sync.grant {
                let selected = Set(grant.scope.accounts.map(\.accountID))
                let shares = session.destinations.filter { sync.eligibleAccountIDs.contains($0.id) }
                SettingsSectionGroup("Media shares") {
                    ForEach(shares) { share in
                        Toggle(isOn: choice(share.id, in: selected) { update($0, grant.categories) }) {
                            if shares.contains(where: { $0.id != share.id && $0.serverName == share.serverName }) {
                                Text(verbatim: share.historyDisplayName)
                            } else {
                                Text(verbatim: share.serverName)
                            }
                        }
                        .accessibilityIdentifier("tracker-history.sync-server.\(share.id)")
                    }
                }
                .disabled(sync.isBusy)
                SettingsSectionGroup("What to sync") {
                    if sync.supportedCategories.contains(.watched) {
                        Toggle("Watched status", isOn: choice(.watched, in: grant.categories) { update(selected, $0) })
                            .accessibilityIdentifier("tracker-history.sync-watched")
                    }
                    if sync.supportedCategories.contains(.resume) {
                        Toggle("Where you left off", isOn: choice(.resume, in: grant.categories) { update(selected, $0) })
                            .accessibilityIdentifier("tracker-history.sync-resume")
                    }
                }
                .disabled(sync.isBusy)
                SettingsSectionGroup {
                    if grant.reviewCount > 0 { Text("Some changes need review. Compare histories before retrying.") }
                    if sync.hasMoreChanges { Text("More changes are waiting. Sync again to continue.") }
                    Button("Sync now") { operation = Task { await sync.synchronize() } }
                        .settingsActionRow()
                        .disabled(sync.isBusy)
                        .accessibilityIdentifier("tracker-history.sync-now")
                } footer: {
                    if !sync.identity.allowsForegroundChecks { Text("Use Sync now to import new history.") }
                }
            } else if sync.grant?.enabled == true {
                SettingsSectionGroup {
                    Text("Your previous permission no longer applies.")
                    Button("Remove previous permission", role: .destructive) { sync.disable() }
                        .settingsActionRow()
                }
            } else if sync.eligibleAccountIDs.isEmpty {
                Text("No media shares in this profile.")
            }
        }
        .tint(palette.primaryText)
        .onAppear { sync.reload() }
        .onDisappear { operation?.cancel() }
    }

    private func setEnabled(_ enabled: Bool) {
        if enabled {
            confirmingBeta = true
        } else {
            operation?.cancel()
            sync.disable()
        }
    }

    private func enroll() {
        operation = Task {
            if let reviewedPlan {
                await sync.enable(afterReview: reviewedPlan, accountIDs: sync.eligibleAccountIDs, categories: sync.supportedCategories)
            } else {
                await sync.enable(from: session, accountIDs: sync.eligibleAccountIDs, categories: sync.supportedCategories)
            }
        }
    }

    private func choice<T: Hashable>(_ item: T, in selection: Set<T>, set: @escaping (Set<T>) -> Void) -> Binding<Bool> {
        Binding(get: { selection.contains(item) }, set: { on in
            set(on ? selection.union([item]) : selection.subtracting([item]))
        })
    }

    private func update(_ accounts: Set<String>, _ categories: Set<TrackerHistorySyncCategory>) {
        guard !accounts.isEmpty, !categories.isEmpty else { setEnabled(false); return }
        operation = Task { await sync.updateSelection(accountIDs: accounts, categories: categories) }
    }
}
#endif
