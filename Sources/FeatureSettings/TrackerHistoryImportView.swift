#if canImport(SwiftUI)
import CoreModels
import CoreUI
import SwiftUI

public struct TrackerHistoryImportView: View {
    private let makeSession: @MainActor () -> TrackerHistoryImportSession
    @State private var session: TrackerHistoryImportSession?
    @Environment(\.themePalette) private var palette

    public init(makeSession: @escaping @MainActor () -> TrackerHistoryImportSession) {
        self.makeSession = makeSession
    }

    public var body: some View {
        GroupedSettingsPage(title: "Compare watch history", backIdentifier: "tracker-history.back") {
            if let session {
                TrackerHistoryComparisonContent(session: session)
            } else {
                ProgressView()
            }
        }
        .tint(palette.primaryText)
        .task {
            guard session == nil || session?.plan == nil else { return }
            let created = makeSession()
            session = created
            await created.compare()
        }
        .onDisappear { session?.cancel() }
    }
}

private struct TrackerHistoryComparisonContent: View {
    let session: TrackerHistoryImportSession
    @State private var selected: Set<UUID> = []
    @State private var confirming = false
    @State private var operation: Task<Void, Never>?

    private var selectedRows: [TrackerHistoryImportPlan.Row] {
        session.plan?.rows.filter { selected.contains($0.id) } ?? []
    }

    private var confirmationTitle: LocalizedStringKey {
        let rows = selectedRows
        let hasShares = rows.contains { $0.target?.providerKind == .mediaShare }
        let hasServers = rows.contains { $0.target?.providerKind != .mediaShare }
        if hasShares && hasServers { return "Change share and server history?" }
        if hasShares { return "Change share history in Plozz?" }
        return "Change server history?"
    }

    var body: some View {
        TrackerHistorySettingsStack {
            if session.isBusy { ProgressView("Comparing or verifying history…") }
            if let error = session.error { TrackerHistoryImportFailure(error: error) }
            if let plan = session.plan, !plan.rows.isEmpty {
                let selectedTargets = Set(plan.rows.lazy.filter { selected.contains($0.id) }.compactMap(\.target))
                TrackerHistoryReviewResults(
                    rows: plan.rows, selected: selected, identifier: "tracker-history",
                    hint: session.outcomes.isEmpty && plan.rows.contains(where: { $0.filter == .ready || $0.filter == .conflicts })
                        ? "Nothing changes until you confirm." : nil,
                    category: { $0.filter }, title: { $0.displayTitle }
                ) {
                    if !selected.isEmpty && session.outcomes.isEmpty {
                        Button("Review \(selected.count) selected") { confirming = true }
                            .settingsActionRow()
                            .disabled(session.isBusy)
                            .accessibilityIdentifier("tracker-history.apply")
                    }
                } content: { row in
                    TrackerHistoryComparisonRow(
                        row: row, destination: session.destinations.first { $0.id == row.target?.accountID },
                        outcome: session.outcomes[row.id],
                        competingSelection: row.target.map(selectedTargets.contains) == true && !selected.contains(row.id),
                        canSelect: !session.isBusy && session.outcomes.isEmpty,
                        selected: Binding(
                            get: { selected.contains(row.id) },
                            set: { if $0 { selected.insert(row.id) } else { selected.remove(row.id) } }
                        )
                    )
                }
                .id(plan.id)
            } else if session.plan != nil {
                SettingsSectionGroup { Text("No tracker records to compare.") }
            }
            SettingsSectionGroup {
                Button("Compare again") {
                    selected = []
                    operation?.cancel()
                    operation = Task { await session.compare() }
                }
                .settingsActionRow()
                .disabled(session.isBusy)
                if let sync = session.ongoingSync, sync.hasSettingsDestination {
                    TrackerHistorySyncNavigationRow(session: session, sync: sync)
                        .disabled(session.isBusy || (session.plan == nil && sync.grant?.enabled != true))
                }
            }
        }
        .confirmationDialog(confirmationTitle, isPresented: $confirming, titleVisibility: .visible) {
            Button("Apply selected changes", role: .destructive) {
                guard let plan = session.plan else { return }
                let selection = selected
                let conflicts = Set(plan.rows.filter {
                    selection.contains($0.id) && $0.filter == .conflicts
                }.map(\.id))
                operation = Task {
                    await session.apply(rowIDs: selection, overridingConflicts: conflicts, confirmsDestructiveChanges: true)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            let rows = selectedRows
            let accounts = Set(rows.compactMap(\.target?.accountID))
            let destinations = session.destinations.filter { accounts.contains($0.id) }
                .map(\.historyDisplayName).formatted(.list(type: .and))
            let conflicts = rows.filter { $0.filter == .conflicts }.count
            let changesServer = rows.contains { $0.target?.providerKind != .mediaShare }
            let single = rows.count == 1 ? rows.first : nil
            publicMetaDBConfirmationMessage(
                single.map { Text("\($0.displayTitle) · \(destinations)") }
                    ?? Text("Apply \(rows.count) selected changes to \(destinations)?"),
                single?.change?.actionLabel,
                conflicts > 0 ? Text("Conflicting history will be replaced.") : nil,
                changesServer ? Text("Other apps and profiles using these server users see the changes. Server plugins may forward them to trackers.") : nil,
                Text("Play counts and dates aren’t copied. Ongoing sync stays unchanged.")
            )
        }
        .onChange(of: session.plan?.id) { _, _ in selected = []; confirming = false }
        .onDisappear { operation?.cancel() }
    }
}

private extension TrackerHistoryImportPlan.Change {
    var actionLabel: Text {
        switch self {
        case .watched(true): Text("Mark watched")
        case .watched(false): Text("Mark unwatched")
        case .resume(let seconds):
            if seconds == 0 { Text("Clear resume point") }
            else { Text("Set resume to \(seconds.formatted(.number.precision(.fractionLength(0)))) seconds") }
        }
    }
}

private extension TrackerHistoryImportPlan.Row {
    var displayTitle: String {
        title ?? observation.sourceTitle ?? observation.identities.compactMap { identity in
            if case .external(let source, let value) = identity { return "\(source): \(value)" }
            return nil
        }.joined(separator: ", ")
    }
    var filter: TrackerHistoryResultFilter {
        switch comparison {
        case .ready: .ready
        case .serverConflict, .trackerConflict: .conflicts
        case .alreadyMatches: .matches
        case .unmatched, .ambiguous, .unsupported, .playing, .incompatibleRuntime: .unavailable
        }
    }
}

private struct TrackerHistoryComparisonRow: View {
    let row: TrackerHistoryImportPlan.Row
    let destination: TrackerHistoryImportSession.Destination?
    let outcome: TrackerHistoryImportSession.Outcome?
    let competingSelection: Bool
    let canSelect: Bool
    @Binding var selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsFormMetrics.relatedControlSpacing) {
            Text(verbatim: row.displayTitle)
            if let destination {
                Text(verbatim: destination.historyDisplayName).foregroundStyle(.secondary)
            }
            if let outcome {
                switch outcome {
                case .queued: Text("Queued for verification")
                case .confirmed: Text(isShare ? "Confirmed in Plozz" : "Confirmed on server")
                case .unconfirmed: Text("Not confirmed. Compare again before retrying.")
                }
            } else {
                if case .animeList(let progress) = row.observation.fact {
                    TrackerAnimeProgressSummary(progress: progress, kind: row.observation.kind)
                }
                if case .episodeCount(let watched, let repeats) = row.observation.fact {
                    Text("Watched episodes: \(watched)").foregroundStyle(.secondary)
                    if let repeats { Text("Rewatches: \(repeats)").foregroundStyle(.secondary) }
                    Text("Aggregate episode progress cannot identify individual watched episodes.")
                        .foregroundStyle(.secondary)
                }
                if case .resumePercentage(let percent, _) = row.observation.fact {
                    Text("Tracker resume: \((percent / 100).formatted(.percent.precision(.fractionLength(1))))")
                        .foregroundStyle(.secondary)
                    Text("The tracker provides a percentage, not a verified file runtime. Progress will not change.")
                        .foregroundStyle(.secondary)
                }
                if let baseline = row.baseline {
                    Group {
                        if isShare { Text(baseline.played ? "Plozz: watched" : "Plozz: not watched") }
                        else { Text(baseline.played ? "Server: watched" : "Server: not watched") }
                    }
                    .foregroundStyle(.secondary)
                    if let position = baseline.resumePosition, position > 0 {
                        let seconds = position.formatted(.number.precision(.fractionLength(0)))
                        Group {
                            if isShare { Text("Plozz resume: \(seconds) seconds") }
                            else { Text("Server resume: \(seconds) seconds") }
                        }
                        .foregroundStyle(.secondary)
                    }
                }
                TrackerHistoryComparisonStatus(comparison: row.comparison, isShare: isShare)
                if competingSelection && row.filter == .conflicts {
                    Text("Deselect the other change for this title first.")
                        .foregroundStyle(.secondary)
                } else if canSelect, let change = row.change, row.filter == .ready || row.filter == .conflicts {
                    Toggle(isOn: $selected) { change.actionLabel }
                    .accessibilityIdentifier("tracker-history.select.\(row.target?.id ?? row.id.uuidString)")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tracker-history.row.\(row.id.uuidString)")
        .trackerHistoryRowFocus(readOnly: !canSelect || competingSelection || row.filter == .matches || row.filter == .unavailable)
    }

    private var isShare: Bool { row.target?.providerKind == .mediaShare }
}

private struct TrackerAnimeProgressSummary: View {
    let progress: TrackerAnimeListProgress
    let kind: MediaItemKind
    var body: some View {
        Group {
            switch progress.status {
            case .planning: Text("Tracker status: planning")
            case .watching: Text("Tracker status: watching")
            case .completed: Text("Tracker status: completed")
            case .paused: Text("Tracker status: paused")
            case .dropped: Text("Tracker status: dropped")
            case .rewatching: Text("Tracker status: rewatching")
            case nil: Text("Tracker status: unavailable")
            }
            if let episodes = progress.episodesWatched { Text("Watched episodes: \(episodes)") }
            if let repeats = progress.repeats { Text("Rewatches: \(repeats)") }
            if let score = progress.score { Text("Your tracker rating: \(score.formatted()) out of 10") }
            if kind == .series {
                Text("Aggregate episode progress cannot identify individual watched episodes.")
            }
        }
        .foregroundStyle(.secondary)
    }
}

private struct TrackerHistoryComparisonStatus: View {
    let comparison: TrackerHistoryImportPlan.Comparison
    let isShare: Bool
    var body: some View {
        Group {
            switch comparison {
            case .ready: EmptyView()
            case .alreadyMatches: Text("Already matches — no change")
            case .serverConflict:
                Text(isShare ? "Different from Plozz — selecting replaces this title’s current state" : "Different from server — selecting replaces its current state")
            case .trackerConflict: Text("Tracker records disagree — select only one change for this title")
            case .unmatched: Text("No confirmed library match")
            case .ambiguous: Text("Multiple library matches — not imported")
            case .unsupported: Text("This kind of record cannot be imported")
            case .playing: Text("Currently playing — not imported")
            case .incompatibleRuntime: Text("Different or unknown runtime — resume not imported")
            }
        }
        .foregroundStyle(.secondary)
    }
}

struct TrackerHistoryImportFailure: View {
    let error: any Error
    var body: some View {
        if let failure = error as? TrackerHistorySyncError {
            switch failure {
            case .unavailable: Text("Ongoing sync is unavailable.")
            case .permissionChanged: Text("Sync permission changed. Review it again.")
            case .historyTooLarge: Text("History is too large for ongoing sync. Use a one-time import.")
            case .timedOut: Text("Sync timed out. Unconfirmed changes need review.")
            case .revocationFailed: Text("Sync is paused. Turn it off again before closing the app.")
            }
        } else if error is DurableLocalStateError {
            Text("Sync records could not be saved or read. Review sync before retrying.")
        } else if let failure = error as? TrackerHistoryError {
            switch failure {
            case .scopeChanged: Text("The profile, server user, or tracker connection changed. Close this page and compare again.")
            case .stalePreview: Text("Tracker or server history changed after the comparison. Compare again before applying changes.")
            case .incompleteSnapshot: Text("The tracker history or library index is incomplete. Wait for loading to finish and compare again.")
            case .invalidObservation: Text("A tracker record could not be interpreted safely. No comparison is available.")
            case .invalidSelection: Text("Select supported changes. Conflicting records for the same title cannot both be imported.")
            }
        } else {
            PublicMetaDBFailureMessage(error: error)
        }
    }
}
#endif
