#if canImport(SwiftUI)
import CoreModels
import CoreUI
import SwiftUI

public struct TrackerHistoryImportView: View {
    private let makeSession: @MainActor () -> TrackerHistoryImportSession
    @State private var session: TrackerHistoryImportSession?

    public init(makeSession: @escaping @MainActor () -> TrackerHistoryImportSession) {
        self.makeSession = makeSession
    }

    public var body: some View {
        PublicMetaDBPage {
            SettingsPageHeader("Compare with server history")
            Text("Your server already tracks playback. Nothing changes until you select differences and confirm.")
                .foregroundStyle(.secondary)
            if let session {
                TrackerHistoryComparisonContent(session: session)
            } else {
                ProgressView()
            }
        }
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
    @State private var page = 0
    @State private var confirming = false
    @State private var operation: Task<Void, Never>?

    var body: some View {
        comparisonContent
        .confirmationDialog("Change server history?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Apply selected changes", role: .destructive) {
                guard let plan = session.plan else { return }
                let conflicts = Set(plan.rows.filter {
                    selected.contains($0.id) && ($0.comparison == .serverConflict || $0.comparison == .trackerConflict)
                }.map(\.id))
                operation = Task {
                    await session.apply(rowIDs: selected, overridingConflicts: conflicts, confirmsDestructiveChanges: true)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Only the selected titles and server users shown above will change. Other apps and profiles using those server users will see the changes. Server plugins may forward them to trackers. Original play counts and dates are not imported. This does not enable ongoing sync.")
        }
        .onChange(of: session.plan?.id) { _, _ in selected = []; page = 0; confirming = false }
        .onDisappear { operation?.cancel() }
    }

    @ViewBuilder private var comparisonContent: some View {
        #if os(tvOS)
        VStack(alignment: .leading, spacing: 20) { rows }
        #else
        Section { rows }
        #endif
    }

    @ViewBuilder private var rows: some View {
        if session.isBusy { ProgressView("Comparing or verifying history…") }
        if let error = session.error { TrackerHistoryImportFailure(error: error) }
        if let plan = session.plan {
            if plan.rows.isEmpty { Text("No tracker records to compare.") }
            ForEach(Array(plan.rows.dropFirst(page * 50).prefix(50))) { row in
                TrackerHistoryComparisonRow(
                    row: row, destination: session.destinations.first { $0.id == row.target?.accountID },
                    outcome: session.outcomes[row.id],
                    selected: Binding(
                        get: { selected.contains(row.id) },
                        set: { if $0 { selected.insert(row.id) } else { selected.remove(row.id) } }
                    )
                )
            }
            .disabled(session.isBusy || !session.outcomes.isEmpty)
            if plan.rows.count > 50 {
                Text("Page \(page + 1) of \((plan.rows.count + 49) / 50)")
                    .foregroundStyle(.secondary)
                if page > 0 {
                    Button("Previous page") { page -= 1 }
                        .accessibilityIdentifier("tracker-history.previous-page")
                }
                if (page + 1) * 50 < plan.rows.count {
                    Button("Next page") { page += 1 }
                        .accessibilityIdentifier("tracker-history.next-page")
                }
            }
            Button("Apply \(selected.count) selected changes") { confirming = true }
                .disabled(selected.isEmpty || session.isBusy || !session.outcomes.isEmpty)
                .accessibilityIdentifier("tracker-history.apply")
        }
        Button("Compare again") {
            selected = []
            operation?.cancel()
            operation = Task { await session.compare() }
        }
        .disabled(session.isBusy)
        if let sync = session.ongoingSync {
            NavigationLink("Ongoing sync") {
                TrackerHistorySyncSettingsView(session: session, sync: sync)
            }
            .disabled(session.isBusy)
            .accessibilityIdentifier("tracker-history.ongoing-sync")
        }
    }
}

private struct TrackerHistoryComparisonRow: View {
    let row: TrackerHistoryImportPlan.Row
    let destination: TrackerHistoryImportSession.Destination?
    let outcome: TrackerHistoryImportSession.Outcome?
    @Binding var selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: row.title ?? row.observation.sourceTitle ?? row.observation.identities.map { identity in
                if case .external(let source, let value) = identity { return "\(source): \(value)" }
                return ""
            }.joined(separator: ", "))
            if let destination {
                Text("\(destination.serverName) · \(destination.userName)").foregroundStyle(.secondary)
            }
            if let outcome {
                switch outcome {
                case .queued: Text("Queued for verification")
                case .confirmed: Text("Confirmed on server")
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
                    Text("The tracker provides a percentage, not a verified file runtime. Server progress will not change.")
                        .foregroundStyle(.secondary)
                }
                if let baseline = row.baseline {
                    Text(baseline.played ? "Server: watched" : "Server: not watched").foregroundStyle(.secondary)
                    if let position = baseline.resumePosition, position > 0 {
                        Text("Server resume: \(position.formatted(.number.precision(.fractionLength(0)))) seconds")
                            .foregroundStyle(.secondary)
                    }
                }
                TrackerHistoryComparisonStatus(comparison: row.comparison)
                if let change = row.change,
                   row.comparison == .ready || row.comparison == .serverConflict || row.comparison == .trackerConflict {
                    Toggle(isOn: $selected) {
                        switch change {
                        case .watched(true): Text("Mark watched")
                        case .watched(false): Text("Mark unwatched")
                        case .resume(let seconds):
                            if seconds == 0 { Text("Clear resume point") }
                            else { Text("Set resume to \(seconds.formatted(.number.precision(.fractionLength(0)))) seconds") }
                        }
                    }
                    .accessibilityIdentifier("tracker-history.select.\(row.target?.id ?? row.id.uuidString)")
                }
            }
        }
        .accessibilityElement(children: .contain)
    }
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
    var body: some View {
        Group {
            switch comparison {
            case .ready: Text("Available to import")
            case .alreadyMatches: Text("Already matches — no change")
            case .serverConflict: Text("Different from server — selecting replaces its current state")
            case .trackerConflict: Text("Tracker records disagree — select only one change for this title")
            case .unmatched: Text("No confirmed library match")
            case .ambiguous: Text("Multiple library matches — not imported")
            case .unsupported: Text("The server cannot import this kind of record")
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
