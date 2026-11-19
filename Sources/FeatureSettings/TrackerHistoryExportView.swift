#if canImport(SwiftUI)
import AniListService
import CoreModels
import CoreUI
import MALService
import SimklService
import SwiftUI
import TraktService
import WetrakrService

public struct TraktHistoryExportView: View {
    private let service: TraktService

    public init(service: TraktService) { self.service = service }

    public var body: some View {
        TrackerHistoryExportView(
            summary: "Only movies and episodes with watch dates. No repeat plays.",
            libraryKinds: [.movie, .series]
        ) {
            guard let create = service.makeHistoryExport else { throw TrackerHistoryExportError.unsupported }
            return try create()
        }
    }
}

public struct SimklHistoryExportView: View {
    private let service: SimklService

    public init(service: SimklService) { self.service = service }

    public var body: some View {
        TrackerHistoryExportView(
            summary: "Movies only. Copies watched status and dates, without repeat plays.",
            libraryKinds: [.movie]
        ) {
            guard let create = service.makeHistoryExport else { throw TrackerHistoryExportError.unsupported }
            return try create()
        }
    }
}

public struct WetrakrHistoryExportView: View {
    private let service: WetrakrService

    public init(service: WetrakrService) { self.service = service }

    public var body: some View {
        TrackerHistoryExportView(
            summary: "Copies watched movies and episodes, without adding repeat plays.",
            libraryKinds: [.movie, .series]
        ) {
            guard let create = service.makeHistoryExport else { throw TrackerHistoryExportError.unsupported }
            return try create()
        }
    }
}

public struct AniListHistoryExportView: View {
    private let service: AniListService

    public init(service: AniListService) { self.service = service }

    public var body: some View {
        TrackerHistoryExportView(
            summary: "Movies only. Copies completion status, not dates or play counts.",
            libraryKinds: [.movie]
        ) {
            guard let create = service.makeHistoryExport else { throw TrackerHistoryExportError.unsupported }
            return try create()
        }
    }
}

public struct MALHistoryExportView: View {
    private let service: MALService

    public init(service: MALService) { self.service = service }

    public var body: some View {
        TrackerHistoryExportView(
            summary: "Movies only. Copies completion status, not dates or play counts.",
            libraryKinds: [.movie]
        ) {
            guard let create = service.makeHistoryExport else { throw TrackerHistoryExportError.unsupported }
            return try create()
        }
    }
}

public struct TrackerHistoryExportView<Target: Codable & Hashable & Sendable>: View {
    private let summary: LocalizedStringResource
    private let libraryKinds: Set<MediaItemKind>
    private let makeSession: @MainActor () throws -> TrackerHistoryExportSession<Target>
    @State private var session: TrackerHistoryExportSession<Target>?
    @State private var error: (any Error)?
    @Environment(\.themePalette) private var palette

    public init(
        summary: LocalizedStringResource, libraryKinds: Set<MediaItemKind>,
        makeSession: @escaping @MainActor () throws -> TrackerHistoryExportSession<Target>
    ) {
        self.summary = summary
        self.libraryKinds = libraryKinds
        self.makeSession = makeSession
    }

    public var body: some View {
        GroupedSettingsPage(title: "Export server history", backIdentifier: "tracker-export.back") {
            if let session {
                TrackerHistoryExportContent(session: session, libraryKinds: libraryKinds, summary: summary)
            } else if let error {
                TrackerHistoryExportFailure(error: error)
            } else {
                ProgressView()
            }
        }
        .tint(palette.primaryText)
        .task {
            guard session == nil else { return }
            do { session = try makeSession() }
            catch { self.error = error }
        }
        .onDisappear {
            session?.cancel()
            session = nil
        }
    }
}

private struct TrackerHistoryExportContent<Target: Codable & Hashable & Sendable>: View {
    let session: TrackerHistoryExportSession<Target>
    let libraryKinds: Set<MediaItemKind>
    let summary: LocalizedStringResource
    @State private var accountID = ""
    @State private var libraryID = ""
    @State private var libraries: [MediaLibrary] = []
    @State private var selected: Set<UUID> = []
    @State private var confirming = false
    @State private var loadingLibraries = false
    @State private var error: (any Error)?
    @State private var operation: Task<Void, Never>?

    var body: some View {
        TrackerHistorySettingsStack {
            SettingsSectionGroup("Export to \(session.trackerName)") {
                TrackerHistoryExportSourceRows(
                    accounts: session.source.accounts, libraries: libraries, loadingLibraries: loadingLibraries,
                    libraryLoadFailed: error != nil, accountID: $accountID, libraryID: $libraryID, identifier: "tracker-export"
                )
                if let library = libraries.first(where: { $0.id == libraryID }), !loadingLibraries {
                    Button("Preview export") {
                        let account = accountID
                        selected = []
                        error = nil
                        operation = Task { await session.compare(accountID: account, library: library) }
                    }
                    .settingsActionRow()
                    .accessibilityIdentifier("tracker-export.preview")
                }
            } footer: {
                Text(summary)
            }
            .disabled(session.isBusy)
            if let error = error ?? session.error { TrackerHistoryExportFailure(error: error) }
            if session.isBusy { ProgressView("Reading and verifying history…") }
            if session.hasCompared {
                if session.rows.isEmpty {
                    SettingsSectionGroup { Text("No matching server history to export.") }
                } else {
                    TrackerHistoryReviewResults(
                        rows: session.rows, selected: selected, identifier: "tracker-export",
                        hint: session.outcomes.isEmpty && session.rows.contains(where: { $0.status == .ready })
                            ? "Select up to 50 titles. Nothing is exported until you confirm." : nil,
                        category: { row in
                            switch row.status {
                            case .ready: .ready
                            case .alreadyMatches: .matches
                            case .conflict: .conflicts
                            case .unsupported, .ambiguous, .playing, .previousAttempt: .unavailable
                            }
                        }, title: { $0.title }
                    ) {
                        if !selected.isEmpty && session.outcomes.isEmpty {
                            Button("Review \(selected.count) selected") { confirming = true }
                                .settingsActionRow()
                                .disabled(session.isBusy)
                                .accessibilityIdentifier("tracker-export.apply")
                        }
                    } content: { row in
                        TrackerHistoryExportRow(
                            row: row, outcome: session.outcomes[row.id], trackerName: session.trackerName,
                            showsDate: session.preservesWatchDates,
                            isDisabled: session.isBusy || !session.outcomes.isEmpty || (selected.count >= 50 && !selected.contains(row.id)),
                            isSelected: Binding(
                                get: { selected.contains(row.id) },
                                set: { if $0 { selected.insert(row.id) } else { selected.remove(row.id) } }
                            )
                        )
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
                if accountID == expected { libraries = result.filter { libraryKinds.contains($0.kind) } }
            } catch {
                if accountID == expected, !Task.isCancelled { self.error = error }
            }
        }
        .onChange(of: libraryID) { _, _ in reset() }
        .confirmationDialog("Export to \(session.trackerName)?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Export selected titles", role: .destructive) {
                let selection = selected
                operation = Task { await session.apply(rowIDs: selection, confirmed: true) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            let library = libraries.first { $0.id == libraryID }?.title ?? ""
            publicMetaDBConfirmationMessage(
                Text("Copy \(selected.count) selected titles from \(library) to \(session.trackerName)?"),
                Text(summary),
                Text("Other apps using this tracker account see the changes. Recent tracker edits may conflict. Servers and sync settings stay unchanged.")
            )
        }
        .onDisappear { operation?.cancel() }
    }

    private func reset() {
        operation?.cancel()
        selected = []
        confirming = false
        session.resetPreview()
    }
}

private struct TrackerHistoryExportRow<Target: Codable & Hashable & Sendable>: View {
    let row: TrackerHistoryExportSession<Target>.Row
    let outcome: TrackerHistoryExportSession<Target>.Outcome?
    let trackerName: String
    let showsDate: Bool
    let isDisabled: Bool
    @Binding var isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsFormMetrics.relatedControlSpacing) {
            Text(verbatim: row.title)
            if showsDate { PublicMetaDBWatchDateLabel(date: row.watchDate) }
            if let outcome {
                switch outcome {
                case .confirmed: Text("Confirmed on \(trackerName)")
                case .alreadyPresent: Text("Already present; no additional play needed.")
                case .unconfirmed: Text("Not confirmed. Preview again before taking further action.")
                }
            } else {
                switch row.status {
                case .ready:
                    Toggle("Export this title", isOn: $isSelected)
                        .disabled(isDisabled)
                        .accessibilityIdentifier("tracker-export.select.\(row.baseline.itemID)")
                case .alreadyMatches: Text("Already present")
                case .conflict: Text("Conflicting tracker state")
                case .unsupported: Text("No supported exact match")
                case .ambiguous: Text("Multiple matches")
                case .playing: Text("Currently playing")
                case .previousAttempt: Text("Previously attempted; not sent again")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .trackerHistoryRowFocus(readOnly: isDisabled || outcome != nil || row.status != .ready)
    }
}

private struct TrackerHistoryExportFailure: View {
    let error: any Error
    var body: some View {
        if let failure = error as? TrackerHistoryExportError {
            switch failure {
            case .unsupported: Text("No supported exact match.")
            case .previousAttempt: Text("Previously attempted. It will not be sent again.")
            case .uncertainWrite: Text("Delivery is unconfirmed. It will not be sent again.")
            case .notWritten(let reason): Text(reason.userMessage)
            }
        } else if (error as? TrackerHistoryError) == .invalidSelection {
            Text("Select up to 50 supported titles, then confirm.")
        } else {
            TrackerHistoryImportFailure(error: error)
        }
    }
}
#endif
