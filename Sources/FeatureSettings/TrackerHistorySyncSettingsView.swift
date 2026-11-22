#if canImport(SwiftUI)
import CoreModels
import CoreUI
import SwiftUI

/// The account page may stay on screen across a reconnect or profile change.
/// Keep the sheet and its captured session scoped to this connection.
public struct TrackerAccountSettingsRows: View {
    private let tracker: any TrackerHistorySyncReading
    private let makeSession: (@MainActor () -> TrackerHistoryImportSession)?

    public init(tracker: any TrackerHistorySyncReading, makeSession: (@MainActor () -> TrackerHistoryImportSession)?) {
        self.tracker = tracker
        self.makeSession = makeSession
    }

    public var body: some View {
        TrackerActivationRow(tracker: tracker, trackerID: tracker.historySyncTrackerID)
        if tracker.trackerEnabled, let connectionID = tracker.historyConnectionID, let makeSession {
            TrackerHistorySyncLink(makeSession: makeSession, accountTrackerID: tracker.historySyncTrackerID)
                .id(connectionID)
        }
    }
}

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
    @State private var showingSync = false
    private let accountTrackerID: String?
    private let isCurrent: @MainActor () -> Bool

    public init(makeSession: @escaping @MainActor () -> TrackerHistoryImportSession) {
        self.init(makeSession: makeSession, isCurrent: { true })
    }

    init(makeSession: @escaping @MainActor () -> TrackerHistoryImportSession,
         accountTrackerID: String? = nil, isCurrent: @escaping @MainActor () -> Bool = { true }) {
        self.accountTrackerID = accountTrackerID
        self.isCurrent = isCurrent
        _entry = State(initialValue: Entry(makeSession))
    }

    public var body: some View {
        if let sync = entry.session.ongoingSync, sync.hasSettingsDestination {
            if let accountTrackerID {
                Button { showingSync = true } label: {
                    SettingsDisclosureLabel { Text("File share sync (Beta)") }
                }
                .settingsActionRow()
                .accessibilityIdentifier("\(accountTrackerID).ongoing-sync")
                .sheet(isPresented: $showingSync) {
                    NavigationStack {
                        TrackerHistorySyncSettingsView(session: entry.session, sync: sync)
                            #if os(iOS)
                            .toolbar {
                                ToolbarItem(placement: .confirmationAction) {
                                    Button("Done") { showingSync = false }
                                }
                            }
                            #endif
                    }
                    #if os(tvOS)
                    .environment(\.settingsPageContext, nil)
                    #endif
                }
            } else {
                TrackerHistorySyncNavigationRow(session: entry.session, sync: sync, isCurrent: isCurrent)
            }
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
    var isCurrent: @MainActor () -> Bool = { true }

    var body: some View {
        SettingsPageLink {
            TrackerConnectionPage(isCurrent: isCurrent) {
                TrackerHistorySyncSettingsView(session: session, sync: sync)
            }
        } label: {
            SettingsDisclosureLabel { Text("File share sync (Beta)") }
        }
        .settingsActionRow()
        .accessibilityIdentifier("tracker-history.ongoing-sync")
    }
}

/// The TV workspace retains a pushed page even if the originating account row disappears.
struct TrackerConnectionPage<Content: View>: View {
    let isCurrent: @MainActor () -> Bool
    @ViewBuilder let content: () -> Content
    @SettingsPageDismiss private var dismiss

    var body: some View {
        if isCurrent() {
            content()
        } else {
            Color.clear.onAppear { dismiss() }
        }
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
        GroupedSettingsPage(title: "File share sync (Beta)", backIdentifier: "tracker-history.sync-back") {
            if sync.isEnabled || (sync.grant?.enabled != true && !sync.eligibleAccountIDs.isEmpty && !sync.supportedCategories.isEmpty) {
                SettingsSectionGroup {
                    Toggle("Apply new activity from \(trackerName)", isOn: Binding(get: { sync.isEnabled }, set: setEnabled))
                        .accessibilityIdentifier("tracker-history.sync-enabled")
                        .disabled(!sync.isEnabled && sync.isBusy)
                        .confirmationDialog("Update file share history in Plozz?", isPresented: $confirmingBeta, titleVisibility: .visible) {
                            Button("Enable beta sync") { enroll() }
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text("Applies to \(shareNames). Turning sync off won’t undo changes.")
                        }
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        if sync.supportedCategories == [.watched] {
                            Text("When \(trackerName) records a new watch, Plozz marks matching titles as watched on your file shares.")
                        } else if sync.supportedCategories == [.resume] {
                            Text("New playback positions from \(trackerName) update where you left off in Plozz.")
                        } else {
                            Text("Plozz can apply new watches and playback positions from \(trackerName) to matching titles.")
                        }
                        Text("Past history isn’t imported. This never changes watch history on Plex or other media servers.")
                    }
                }
                if !sync.isEnabled {
                    SettingsSectionGroup("File shares in this profile") {
                        ForEach(shares) { share in
                            Text(verbatim: shareName(share))
                        }
                    }
                }
            }
            if sync.isBusy { ProgressView("Syncing…") }
            if reviewedPlan == nil, sync.grant?.enabled != true, sync.error as? TrackerHistoryError == .incompleteSnapshot {
                Text("Sync is off. Plozz couldn’t verify your full \(trackerName) history. Try again later.")
            } else if let error = sync.error { TrackerHistoryImportFailure(error: error) }
            if sync.isEnabled, let grant = sync.grant {
                let selected = Set(grant.scope.accounts.map(\.accountID))
                SettingsSectionGroup("File shares to update") {
                    ForEach(shares) { share in
                        Toggle(isOn: choice(share.id, in: selected) { update($0, grant.categories) }) {
                            Text(verbatim: shareName(share))
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
                        Toggle("Playback progress", isOn: choice(.resume, in: grant.categories) { update(selected, $0) })
                            .accessibilityIdentifier("tracker-history.sync-resume")
                    }
                }
                .disabled(sync.isBusy)
                SettingsSectionGroup {
                    if grant.reviewCount > 0 { Text("Some changes couldn’t be applied automatically.") }
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
                Text("No file shares in this profile.")
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

    private var trackerName: String {
        let id = sync.identity.trackerID
        let page = id == "publicmetadb" ? SettingsSearchPage.publicMetaDB : SettingsSearchPage(rawValue: id)
        return page?.trackerAccount?.name ?? id
    }

    private var shares: [TrackerHistoryImportSession.Destination] {
        session.destinations.filter { sync.eligibleAccountIDs.contains($0.id) }
    }

    private func shareName(_ share: TrackerHistoryImportSession.Destination) -> String {
        shares.contains { $0.id != share.id && $0.serverName == share.serverName }
            ? share.historyDisplayName : share.serverName
    }

    private var shareNames: String { shares.map(shareName).formatted(.list(type: .and)) }

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
