#if canImport(SwiftUI)
import CoreModels
import CoreUI
import SwiftUI

public struct TrackerAccountSettingsRows: View {
    let tracker: any TrackerHistorySyncReading
    let makeSession: (@MainActor () -> TrackerHistoryImportSession)?

    public init(tracker: any TrackerHistorySyncReading, makeSession: (@MainActor () -> TrackerHistoryImportSession)?) {
        self.tracker = tracker
        self.makeSession = makeSession
    }

    public var body: some View {
        TrackerActivationRow(tracker: tracker, trackerID: tracker.historySyncTrackerID)
        if tracker.trackerEnabled, let connection = tracker.historyActivationID, let makeSession {
            TrackerHistorySyncLink(makeSession: makeSession).id(connection)
        }
    }
}

public struct TrackerHistorySyncLink: View {
    @MainActor private final class Entry {
        let makeSession: @MainActor () -> TrackerHistoryImportSession
        lazy var session = makeSession()
        init(_ makeSession: @escaping @MainActor () -> TrackerHistoryImportSession) { self.makeSession = makeSession }
    }
    @State private var entry: Entry
    public init(makeSession: @escaping @MainActor () -> TrackerHistoryImportSession) {
        _entry = State(initialValue: Entry(makeSession))
    }

    public var body: some View {
        if let sync = entry.session.ongoingSync, sync.hasSettingsDestination {
            TrackerTwoWaySyncRows(session: entry.session, sync: sync)
        }
    }
}

extension TrackerHistorySyncController {
    var hasSettingsDestination: Bool {
        (!eligibleAccountIDs.isEmpty && !supportedCategories.isEmpty) || grant?.enabled == true
    }
}

// The reviewed-history tool has its own navigation host; connected accounts render the rows inline.
struct TrackerHistorySyncNavigationRow: View {
    let session: TrackerHistoryImportSession
    let sync: TrackerHistorySyncController
    var body: some View {
        SettingsPageLink {
            TrackerHistorySyncSettingsView(session: session, sync: sync)
        } label: {
            SettingsDisclosureLabel { Text("2-way sync") }
        }
        .settingsActionRow()
        .accessibilityIdentifier("tracker-history.ongoing-sync")
    }
}

struct TrackerHistorySyncSettingsView: View {
    let session: TrackerHistoryImportSession
    let sync: TrackerHistorySyncController
    @State private var reviewedPlan: TrackerHistoryImportPlan?

    init(session: TrackerHistoryImportSession, sync: TrackerHistorySyncController) {
        self.session = session
        self.sync = sync
        // The comparison session closes on navigation. Keep its evidence, not its authority.
        _reviewedPlan = State(initialValue: session.plan)
    }

    var body: some View {
        GroupedSettingsPage(title: "2-way sync", backIdentifier: "tracker-history.sync-back") {
            TrackerTwoWaySyncRows(session: session, sync: sync, reviewedPlan: reviewedPlan)
        }
    }
}

private struct TrackerTwoWaySyncRows: View {
    let session: TrackerHistoryImportSession
    let sync: TrackerHistorySyncController
    var reviewedPlan: TrackerHistoryImportPlan? = nil
    @State private var choosingLibraries = false
    @State private var confirmedLibraries: Set<String>?
    @State private var editingLibraries = false
    @State private var offeredGrant: UUID?
    @State private var showHistoryChoice = false
    @State private var operation: Task<Void, Never>?

    private var trackerName: String {
        let id = sync.identity.trackerID
        return (id == "publicmetadb" ? SettingsSearchPage.publicMetaDB : SettingsSearchPage(rawValue: id))?.trackerAccount?.name ?? id
    }
    private var shares: [TrackerHistoryImportSession.Destination] {
        session.destinations.filter { sync.eligibleAccountIDs.contains($0.id) }
    }
    private var selected: Set<String> {
        Set(sync.grant?.scope.accounts.map(\.accountID) ?? [])
    }
    private func name(_ share: TrackerHistoryImportSession.Destination) -> String {
        shares.contains { $0.id != share.id && $0.serverName == share.serverName } ? share.historyDisplayName : share.serverName
    }
    private var selectedShares: [TrackerHistoryImportSession.Destination] {
        let ids = selected
        return shares.filter { ids.contains($0.id) }
    }
    private var destinations: String { selectedShares.map(name).formatted(.list(type: .and)) }
    private var librarySummary: some View {
        LabeledContent("Libraries") {
            HStack(spacing: 6) {
                Text("\(selectedShares.count) of \(shares.count) selected")
                Image(systemName: editingLibraries ? "chevron.up" : "chevron.down")
                    .font(.caption.weight(.semibold))
                    .accessibilityHidden(true)
            }
        }
    }
    var body: some View {
        if sync.grant?.enabled == true && !sync.isEnabled {
            SettingsSectionGroup("Watch history") {
                Text("Your previous sync permission no longer applies.")
                Button("Remove previous permission", role: .destructive) { sync.disable() }.settingsActionRow()
            }
        } else if !shares.isEmpty {
            SettingsSectionGroup("Watch history") {
                controls
            } footer: {
                Text("Beta: Changes from \(trackerName) update matching titles in Plozz, not on Plex, Jellyfin, or Emby.")
                if sync.isEnabled && !sync.isBusy && !sync.identity.allowsForegroundChecks {
                    Text("Use Sync now to check for later changes.").font(.footnote).plozzForeground(.secondary)
                }
            }
            #if os(iOS)
            .fixedSize(horizontal: false, vertical: true)
            #endif
        }
    }

    @ViewBuilder private var controls: some View {
        Toggle("2-way sync", isOn: Binding(get: { sync.isEnabled }, set: setEnabled))
            .accessibilityIdentifier("tracker-history.sync-enabled")
            .disabled(!sync.isEnabled && sync.isBusy)
            .sheet(isPresented: $choosingLibraries, onDismiss: finishLibraryChoice) {
                TrackerSyncLibraryChooser(shares: shares, name: name) { accounts in
                    confirmedLibraries = accounts
                    choosingLibraries = false
                }
            }
            .alert("Sync existing watch history from \(trackerName)?", isPresented: $showHistoryChoice) {
                Button("Sync history") {
                    guard let id = offeredGrant, sync.isEnabled, sync.grant?.id == id else { return }
                    offeredGrant = nil
                    operation = Task { await sync.syncExistingHistory(for: id) }
                }
                Button("Skip", role: .cancel) {
                    if let offeredGrant { sync.skipExistingHistory(for: offeredGrant) }
                    offeredGrant = nil
                }
            } message: {
                Text("Mark matching titles as watched in \(destinations). New activity syncs either way.")
            }
        if sync.isEnabled { activeLibraries }
        if sync.isBusy {
            progressRow
        } else if let error = sync.error {
            Group {
                if case .rateLimited = error as? AppError {
                    if let date = sync.retryDate {
                        Text("\(trackerName) paused the history check. Try again after \(date.formatted(date: .omitted, time: .standard)).")
                    } else { Text("\(trackerName) paused the history check. Try again later.") }
                } else if !sync.isEnabled, error as? TrackerHistoryError == .incompleteSnapshot {
                    Text("Sync is off. Plozz couldn’t verify your full \(trackerName) history. Try again later.")
                } else { TrackerHistoryImportFailure(error: error) }
            }
            #if os(iOS)
            .lineLimit(nil)
            .padding(.vertical, MobileSettingsMetrics.descriptionBottomInset - MobileSettingsMetrics.controlVerticalInset)
            .fixedSize(horizontal: false, vertical: true)
            #endif
        } else if sync.isEnabled {
            syncResult
        }
        if sync.isEnabled && !sync.isBusy {
            Button("Sync now") { operation = Task { await sync.synchronize() } }
                .settingsActionRow()
                .accessibilityIdentifier("tracker-history.sync-now")
        }
    }

    private var progressRow: some View {
        HStack(spacing: 12) {
            ProgressView().accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                switch sync.stage {
                case .reading: Text("Reading \(trackerName) watch history…")
                case .verifying: Text("Verifying \(trackerName) watch history…")
                case .saving: Text("Saving sync settings…")
                case .selecting: Text("Updating selected libraries…")
                case let .comparing(index, total): Text("Checking library \(index) of \(total)…")
                case let .applying(index, total): Text("Updating library \(index) of \(total)…")
                }
                if let detail = sync.readDetail {
                    Group {
                        switch detail {
                        case let .watches(page, total): Text("Read \(page) of \(total) history pages")
                        case let .verifyingRange(page, total): Text("Checking dates: \(page) of \(total) pages")
                        case .waiting(let date): Text("Waiting for \(trackerName) until \(date.formatted(date: .omitted, time: .standard))")
                        }
                    }.font(.footnote).plozzForeground(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .lineLimit(nil)
        .padding(.vertical, 12)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("tracker-history.progress")
    }

    @ViewBuilder private var activeLibraries: some View {
        if shares.count > 1 {
            Button { editingLibraries.toggle() } label: { librarySummary }
            .settingsActionRow()
            .accessibilityIdentifier("tracker-history.libraries")
            if editingLibraries {
                ForEach(shares) { share in
                    Toggle(isOn: Binding(get: { selected.contains(share.id) }, set: { select(share.id, $0) })) {
                        TrackerLibraryLabel(name: name(share), transport: share.transportKind)
                    }
                    .disabled(sync.isBusy)
                    .accessibilityIdentifier("tracker-history.sync-server.\(share.id)")
                }
            }
        } else if let share = shares.first {
            LabeledContent("Library") {
                TrackerLibraryLabel(name: name(share), transport: share.transportKind)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("tracker-history.library.\(share.id)")
        }
    }

    @ViewBuilder private var syncResult: some View {
        if sync.grant?.lastCheckStatus == .incomplete {
            Text("Last sync didn’t finish. Use Sync now to check again.")
        } else if sync.grant?.lastCheckStatus == .failed {
            Text("Last sync failed. Use Sync now to try again.")
        } else if let result = sync.grant?.lastCompletedResult {
            TrackerLastSyncRows(result: result) { id in
                shares.first(where: { $0.id == id }).map(name)
            }
        }
    }

    private func setEnabled(_ enabled: Bool) {
        offeredGrant = nil
        showHistoryChoice = false
        editingLibraries = false
        confirmedLibraries = nil
        if enabled {
            choosingLibraries = true
        } else {
            operation?.cancel()
            sync.disable()
        }
    }

    private func finishLibraryChoice() {
        guard let accounts = confirmedLibraries else { return }
        confirmedLibraries = nil
        guard !sync.isEnabled, !sync.isBusy else { return }
        operation = Task {
            if let plan = reviewedPlan {
                await sync.enable(afterReview: plan, accountIDs: accounts, categories: sync.supportedCategories)
            } else {
                await sync.enable(from: session, accountIDs: accounts, categories: sync.supportedCategories)
            }
            guard !Task.isCancelled, sync.isEnabled, sync.error == nil, let id = sync.grant?.id else { return }
            await sync.synchronize()
            guard !Task.isCancelled, sync.isEnabled, sync.pendingHistoryGrantID == id else { return }
            offeredGrant = id
            showHistoryChoice = true
        }
    }

    private func select(_ id: String, _ on: Bool) {
        guard sync.isEnabled, let grant = sync.grant else { return }
        let ids = on ? selected.union([id]) : selected.subtracting([id])
        if ids.isEmpty {
            setEnabled(false)
        } else {
            operation = Task { await sync.updateSelection(accountIDs: ids, categories: grant.categories) }
        }
    }
}

private struct TrackerLastSyncRows: View {
    let result: TrackerHistorySyncResult
    let libraryName: (String) -> String?
    @State private var expanded = false

    @ViewBuilder private var summary: some View {
        switch result.confirmedCount {
        case 0: Text("Last sync: no updates applied")
        case 1: Text("Last sync: 1 update applied")
        default: Text("Last sync: \(result.confirmedCount) updates applied")
        }
    }

    private var disclosure: some View {
        HStack {
            summary
            Spacer()
            Image(systemName: expanded ? "chevron.up" : "chevron.down")
                .font(.caption.weight(.semibold)).accessibilityHidden(true)
        }
    }

    var body: some View {
        if let libraries = result.libraries, libraries.contains(where: { !$0.counts.isEmpty }) {
            Button { expanded.toggle() } label: { disclosure }
            .settingsActionRow()
            .accessibilityValue(expanded ? Text("Expanded") : Text("Collapsed"))
            .accessibilityHint("Shows the results for each library.")
            .accessibilityIdentifier("tracker-history.last-sync")
            if expanded {
                ForEach(libraries, id: \.accountID) { library in
                    VStack(alignment: .leading, spacing: 4) {
                        if let name = libraryName(library.accountID) { Text(verbatim: name).font(.headline) }
                        if library.counts.isEmpty { Text("No new activity to check.") }
                        ForEach(TrackerHistorySyncResult.Outcome.allCases, id: \.self) { reason in
                            if let count = library.counts[reason] {
                                Text("\(Text(reason.label)): \(count)")
                                    .accessibilityIdentifier("tracker-history.result.\(reason.rawValue)")
                            }
                        }
                    }
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            let remaining = libraries.reduce(0) { $0 + ($1.counts[.leftToCheck] ?? 0) }
            if remaining > 0 {
                Text("Library entries left for the next sync: \(remaining). Use Sync now to continue.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            if libraries.contains(where: { $0.counts[.playing] != nil }) {
                Text("Plozz skips titles during playback. To update their history, sync after playback ends.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            if libraries.contains(where: { $0.counts[.unconfirmed] != nil || $0.counts[.previousUnconfirmed] != nil }) {
                let names = libraries.filter { $0.counts[.unconfirmed] != nil || $0.counts[.previousUnconfirmed] != nil }
                    .compactMap { libraryName($0.accountID) }
                Group {
                    if names.isEmpty { Text("Check watched status in Plozz. An update couldn’t be verified and won’t be repeated.") }
                    else { Text("Check watch history in \(names.formatted(.list(type: .and))). Plozz couldn’t verify an update and won’t repeat it.") }
                }.fixedSize(horizontal: false, vertical: true)
            }
        } else {
            summary
                .accessibilityIdentifier("tracker-history.last-sync")
            if result.hasMoreChanges {
                // Older versions saved only the continuation flag.
                Text("Use Sync now to check the rest of your history.")
            }
        }
    }
}

private extension TrackerHistorySyncResult.Outcome {
    var label: LocalizedStringResource {
        switch self {
        case .updated: "Updates applied"
        case .alreadyMatched: "Already matched"
        case .noMatch: "Skipped — no exact library match"
        case .multipleMatches: "Skipped — multiple library matches"
        case .libraryConflict: "Kept existing watch history"
        case .trackerConflict: "Skipped — tracker records disagree"
        case .unsupported: "Skipped — unsupported history"
        case .incompatibleRuntime: "Skipped resume — different or unknown duration"
        case .wouldClearHistory: "Kept existing watched status or progress"
        case .unconfirmed: "Update not verified"
        case .previousUnconfirmed: "Skipped — previous update not verified"
        case .playing: "Deferred during playback"
        case .leftToCheck: "Left for the next sync"
        }
    }
}

private struct TrackerSyncLibraryChooser: View {
    let shares: [TrackerHistoryImportSession.Destination]
    let name: (TrackerHistoryImportSession.Destination) -> String
    let confirm: (Set<String>) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.themePalette) private var palette
    @State private var selection: Set<String> = []

    private var eligible: Set<String> { Set(shares.map(\.id)) }
    private var selected: Set<String> { shares.count == 1 ? eligible : selection.intersection(eligible) }

    var body: some View {
        NavigationStack {
            GroupedSettingsPage(title: "Libraries to sync") {
                #if os(tvOS)
                SettingsSectionGroup {
                    startButton.settingsActionRow()
                    Button("Cancel", role: .cancel) { dismiss() }.settingsActionRow()
                }
                #endif
                SettingsSectionGroup {
                    if shares.count > 1 {
                        Button {
                            selection = selected == eligible ? [] : eligible
                        } label: {
                            if selected == eligible { Text("Deselect all") } else { Text("Select all") }
                        }
                        .settingsActionRow()
                        .accessibilityIdentifier("tracker-history.choose-all")
                    }
                    ForEach(shares) { share in
                        let label = TrackerLibraryLabel(name: name(share), transport: share.transportKind)
                        if shares.count == 1 {
                            label
                        } else {
                            let checked = selected.contains(share.id)
                            Button {
                                if checked { selection.remove(share.id) } else { selection.insert(share.id) }
                            } label: {
                                HStack {
                                    label
                                    Spacer()
                                    SettingsCheckmark(isChecked: checked)
                                }
                            }
                            .settingsActionRow()
                            .accessibilityAddTraits(checked ? .isSelected : [])
                            .accessibilityIdentifier("tracker-history.choose.\(share.id)")
                        }
                    }
                }
            }
            #if os(iOS)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", role: .cancel) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { startButton }
            }
            #elseif os(tvOS)
            .environment(\.settingsInWorkspace, false)
            .onExitCommand { dismiss() }
            #endif
        }
        .tint(palette.primaryText)
    }

    private var startButton: some View {
        Button("Start sync") { confirm(selected) }
            .disabled(selected.isEmpty)
            .accessibilityIdentifier("tracker-history.start-sync")
    }
}

private struct TrackerLibraryLabel: View {
    let name: String
    let transport: MediaShareTransportKind?
    #if os(tvOS)
    private let markSize: CGFloat = 40
    #else
    @ScaledMetric(relativeTo: .body) private var markSize: CGFloat = 28
    #endif

    var body: some View {
        HStack(spacing: 8) {
            ProviderBrandMark(provider: .mediaShare, size: markSize, mediaShareTransport: transport)
                .accessibilityHidden(true)
            Text(verbatim: name)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: [name, transport?.badgeLabel].compactMap { $0 }.joined(separator: ", ")))
    }
}
#endif
