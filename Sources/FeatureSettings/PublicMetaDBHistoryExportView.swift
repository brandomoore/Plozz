#if canImport(SwiftUI)
import CoreModels
import CoreUI
import PublicMetaDBService
import SwiftUI

struct PublicMetaDBHistoryExportView: View {
    let service: PublicMetaDBService
    @State private var session: PublicMetaDBHistoryExportSession?
    @State private var error: (any Error)?

    var body: some View {
        PublicMetaDBPage {
            SettingsPageHeader("Export server history")
            Text("Preview one server user's library, select titles, then confirm. This writes only to PublicMetaDB and does not enable ongoing sync or change your server.")
                .foregroundStyle(.secondary)
            if let session {
                PublicMetaDBHistoryExportContent(session: session)
            } else if let error {
                PublicMetaDBFailureMessage(error: error)
            } else {
                ProgressView()
            }
        }
        .task {
            guard session == nil else { return }
            do { session = try service.makeHistoryExportSession() }
            catch { self.error = error }
        }
        .onDisappear { session?.cancel() }
    }
}

private struct PublicMetaDBHistoryExportContent: View {
    let session: PublicMetaDBHistoryExportSession
    @State private var accountID = ""
    @State private var libraries: [MediaLibrary] = []
    @State private var libraryID = ""
    @State private var mode: PublicMetaDBHistoryExportSession.Mode = .watched
    @State private var selected: Set<UUID> = []
    @State private var page = 0
    @State private var confirming = false
    @State private var loadingLibraries = false
    @State private var error: (any Error)?
    @State private var operation: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Group {
                Picker("Server user", selection: $accountID) {
                    Text("Choose a server user").tag("")
                    ForEach(session.source.accounts) { account in
                        Text("\(account.serverName) · \(account.userName)").tag(account.id)
                    }
                }
                .accessibilityIdentifier("publicmetadb.export.account")
                Picker("Library", selection: $libraryID) {
                    Text("Choose a library").tag("")
                    ForEach(libraries) { library in Text(verbatim: library.title).tag(library.id) }
                }
                .disabled(loadingLibraries || accountID.isEmpty)
                .accessibilityIdentifier("publicmetadb.export.library")
                Picker("History to export", selection: $mode) {
                    Text("Watched titles").tag(PublicMetaDBHistoryExportSession.Mode.watched)
                    Text("Resume points").tag(PublicMetaDBHistoryExportSession.Mode.resume)
                }
                .accessibilityIdentifier("publicmetadb.export.mode")
            }
            .disabled(session.isBusy)
            if mode == .watched {
                Text("Adds one play only when PublicMetaDB has none. Uses the server's last played date when no resume point exists; otherwise the date is unknown. Original play counts and earlier play dates cannot be reconstructed.")
                    .foregroundStyle(.secondary)
            } else {
                Text("Copies the current position and runtime. PublicMetaDB dates the update now; it cannot retain the original progress timestamp. Positions below 2% or at least 80% are not exported.")
                    .foregroundStyle(.secondary)
            }
            if let error = error ?? session.error { TrackerHistoryImportFailure(error: error) }
            if loadingLibraries { ProgressView("Loading libraries…") }
            if session.isBusy {
                ProgressView("Reading and verifying history…")
                Text("Loaded \(session.loadedCount) library items").foregroundStyle(.secondary)
            }
            Button("Preview export") {
                guard let library = libraries.first(where: { $0.id == libraryID }) else { return }
                selected = []
                page = 0
                operation = Task { await session.compare(accountID: accountID, library: library, mode: mode) }
            }
            .disabled(session.isBusy || loadingLibraries || libraryID.isEmpty)
            .accessibilityIdentifier("publicmetadb.export.preview")
            if session.hasCompared {
                if session.rows.isEmpty { Text("No matching server history to export.") }
                ForEach(Array(session.rows.dropFirst(page * 50).prefix(50))) { row in
                    VStack(alignment: .leading, spacing: 8) {
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
                }
                if page > 0 { Button("Previous page") { page -= 1 } }
                if (page + 1) * 50 < session.rows.count { Button("Next page") { page += 1 } }
                Button("Export \(selected.count) selected titles") { confirming = true }
                    .disabled(session.isBusy || selected.isEmpty || !session.outcomes.isEmpty)
                    .accessibilityIdentifier("publicmetadb.export.apply")
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
                let conflicts = Set(session.rows.filter { selected.contains($0.id) && $0.status == .conflict }.map(\.id))
                operation = Task { await session.apply(rowIDs: selected, overridingConflicts: conflicts, confirmed: true) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Only the selected titles for the server user and library shown above will be exported. Selected resume points replace any conflicting tracker progress and may restore progress on a completed title. Adding watched episodes undrops their shows. Other apps using this PublicMetaDB account will see these changes. Remote activity can still race the comparison.")
        }
        .onDisappear { operation?.cancel() }
    }

    private func reset() {
        selected = []
        page = 0
        confirming = false
        session.resetPreview()
    }

    private func status(_ status: PublicMetaDBHistoryExportSession.Status) -> some View {
        Group {
            switch status {
            case .ready: Text("Available to export")
            case .alreadyMatches: Text("Already present — no change")
            case .conflict: Text("Tracker history, progress, or dropped status conflicts — selection explicitly authorizes this change")
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
