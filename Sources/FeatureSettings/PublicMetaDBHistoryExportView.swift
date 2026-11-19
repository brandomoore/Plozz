#if canImport(SwiftUI)
import CoreModels
import CoreUI
import PublicMetaDBService
import SwiftUI

struct PublicMetaDBHistoryExportView: View {
    let service: PublicMetaDBService
    @State private var session: PublicMetaDBHistoryExportSession?
    @State private var error: (any Error)?
    @Environment(\.themePalette) private var palette

    var body: some View {
        GroupedSettingsPage(title: "Export server history", backIdentifier: "publicmetadb.export.back") {
            if let session {
                PublicMetaDBHistoryExportContent(session: session)
            } else if let error {
                PublicMetaDBFailureMessage(error: error)
            } else {
                ProgressView()
            }
        }
        .tint(palette.primaryText)
        .task {
            guard session == nil else { return }
            do { session = try service.makeHistoryExportSession() }
            catch { self.error = error }
        }
        .onDisappear { session?.cancel(); session = nil }
    }
}

private struct PublicMetaDBHistoryExportContent: View {
    let session: PublicMetaDBHistoryExportSession
    @State private var accountID = ""
    @State private var libraries: [MediaLibrary] = []
    @State private var libraryID = ""
    @State private var mode: PublicMetaDBHistoryExportSession.Mode = .watched
    @State private var selected: Set<UUID> = []
    @State private var confirming = false
    @State private var loadingLibraries = false
    @State private var error: (any Error)?
    @State private var operation: Task<Void, Never>?

    var body: some View {
        TrackerHistorySettingsStack {
            SettingsSectionGroup("Export to PublicMetaDB") {
                TrackerHistoryExportSourceRows(
                    accounts: session.source.accounts, libraries: libraries, loadingLibraries: loadingLibraries,
                    libraryLoadFailed: error != nil, accountID: $accountID, libraryID: $libraryID, identifier: "publicmetadb.export"
                )
                if let library = libraries.first(where: { $0.id == libraryID }), !loadingLibraries {
                    SettingsMenuRow(title: "History to export", value: mode == .watched ? Text("Watched titles") : Text("Where you left off")) {
                        Picker("History to export", selection: $mode) {
                            Text("Watched titles").tag(PublicMetaDBHistoryExportSession.Mode.watched)
                            Text("Where you left off").tag(PublicMetaDBHistoryExportSession.Mode.resume)
                        }
                    }
                    .accessibilityIdentifier("publicmetadb.export.mode")
                    Button("Preview export") {
                        let account = accountID, category = mode
                        selected = []
                        operation = Task { await session.compare(accountID: account, library: library, mode: category) }
                    }
                    .settingsActionRow()
                    .accessibilityIdentifier("publicmetadb.export.preview")
                }
            } footer: {
                if !libraryID.isEmpty {
                    if mode == .watched {
                        Text("Adds one missing play per title. Uses the last played date if there’s no saved position; otherwise the date is unknown.")
                    } else {
                        Text("Copies positions from 2% to below 80% of runtime. PublicMetaDB dates them today.")
                    }
                }
            }
            .disabled(session.isBusy)
            if let error = error ?? session.error { TrackerHistoryImportFailure(error: error) }
            if session.isBusy {
                ProgressView("Reading and verifying history…")
                Text("Loaded \(session.loadedCount) library items").foregroundStyle(.secondary)
            }
            if session.hasCompared {
                if session.rows.isEmpty {
                    SettingsSectionGroup { Text("No matching server history to export.") }
                } else {
                    TrackerHistoryReviewResults(
                        rows: session.rows, selected: selected, identifier: "publicmetadb.export",
                        hint: session.outcomes.isEmpty && session.rows.contains(where: { $0.status == .ready || $0.status == .conflict })
                            ? "Select up to 50 titles. Nothing is exported until you confirm." : nil,
                        category: { row in
                            switch row.status {
                            case .ready: .ready
                            case .conflict: .conflicts
                            case .alreadyMatches: .matches
                            case .unsupported, .ambiguous, .playing, .previousAttempt: .unavailable
                            }
                        }, title: { $0.title }
                    ) {
                        if !selected.isEmpty && session.outcomes.isEmpty {
                            Button("Review \(selected.count) selected") { confirming = true }
                                .settingsActionRow()
                                .disabled(session.isBusy)
                                .accessibilityIdentifier("publicmetadb.export.apply")
                        }
                    } content: { row in
                    VStack(alignment: .leading, spacing: SettingsFormMetrics.relatedControlSpacing) {
                        Text(verbatim: row.title)
                        if let content = row.content, let season = content.season, let episode = content.episode {
                            Text("Season \(season), episode \(episode)").foregroundStyle(.secondary)
                        }
                        if mode == .watched {
                            PublicMetaDBWatchDateLabel(date: row.exportedWatchDate)
                        } else if let position = row.baseline.resumePosition, let runtime = row.baseline.runtime {
                            Text("\(position.formatted(.number.precision(.fractionLength(0)))) of \(runtime.formatted(.number.precision(.fractionLength(0)))) seconds")
                                .foregroundStyle(.secondary)
                        }
                        if let outcome = session.outcomes[row.id] {
                            switch outcome {
                            case .confirmed: Text("Confirmed on PublicMetaDB")
                            case .alreadyPresent: Text("History is present on PublicMetaDB; no additional play is needed")
                            case .unconfirmed: Text("Not confirmed. Preview again before taking further action.")
                            }
                        } else {
                            status(row.status)
                            if row.status == .ready || row.status == .conflict {
                                Toggle("Export this title", isOn: Binding(
                                    get: { selected.contains(row.id) },
                                    set: { if $0 { selected.insert(row.id) } else { selected.remove(row.id) } }
                                ))
                                .disabled(session.isBusy || !session.outcomes.isEmpty || (selected.count >= 50 && !selected.contains(row.id)))
                                .accessibilityIdentifier("publicmetadb.export.select.\(row.baseline.itemID)")
                            }
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("publicmetadb.export.row.\(row.baseline.itemID)")
                    .trackerHistoryRowFocus(readOnly: session.isBusy || !session.outcomes.isEmpty ||
                        (row.status != .ready && row.status != .conflict) || (selected.count >= 50 && !selected.contains(row.id)))
                    }
                }
            }
        }
        .task(id: accountID) {
            reset()
            libraryID = ""
            libraries = []
            error = nil
            loadingLibraries = false
            guard !accountID.isEmpty else { return }
            let expected = accountID
            loadingLibraries = true
            defer { if accountID == expected { loadingLibraries = false } }
            do {
                let result = try await session.source.libraries(accountID: expected)
                try Task.checkCancellation()
                if accountID == expected { libraries = result }
            } catch {
                if accountID == expected, !Task.isCancelled { self.error = error }
            }
        }
        .onChange(of: libraryID) { _, _ in reset() }
        .onChange(of: mode) { _, _ in reset() }
        .confirmationDialog("Write selected history to PublicMetaDB?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Export selected titles", role: .destructive) {
                let selection = selected
                let conflicts = Set(session.rows.filter { selection.contains($0.id) && $0.status == .conflict }.map(\.id))
                operation = Task { await session.apply(rowIDs: selection, overridingConflicts: conflicts, confirmed: true) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            let rows = session.rows.filter { selected.contains($0.id) }
            publicMetaDBConfirmationMessage(
                Text("Export \(rows.count) selected titles to PublicMetaDB? Other apps using this tracker account see the changes. Servers and sync settings stay unchanged."),
                mode == .resume ? Text("Positions replace conflicting progress and can restore progress on completed titles.") : nil,
                mode == .watched && rows.contains(where: { $0.content?.episode != nil })
                    ? Text("Adding watched episodes restores dropped shows.") : nil,
                rows.contains(where: { $0.status == .conflict }) ? Text("Selected conflicts will be overwritten.") : nil,
                Text("Recent tracker edits may conflict.")
            )
        }
        .onDisappear { operation?.cancel() }
    }

    private func reset() {
        selected = []
        operation?.cancel()
        confirming = false
        session.resetPreview()
    }

    private func status(_ status: PublicMetaDBHistoryExportSession.Status) -> some View {
        Group {
            switch status {
            case .ready: EmptyView()
            case .alreadyMatches: Text("Already present — no change")
            case .conflict: Text("Conflicts with tracker history. Selecting this replaces the tracker’s state.")
            case .unsupported: Text("No supported exact identity, date, runtime, or resume position — not exported")
            case .ambiguous: Text("Multiple server items match this tracker title — not exported")
            case .playing: Text("Currently playing — not exported")
            case .previousAttempt: Text("Previously exported or awaiting verification — not replayed")
            }
        }
        .foregroundStyle(.secondary)
    }
}
#endif
