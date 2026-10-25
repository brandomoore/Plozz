#if canImport(SwiftUI)
import CoreModels
import CoreUI
import LastFmService
import SwiftUI

public struct LastFmListeningHistoryView: View {
    let service: LastFmService
    @State private var connection: String?
    @State private var page = 1
    @State private var before = Int(Date().timeIntervalSince1970)
    @State private var refreshID = UUID()
    @State private var expectedTotal: Int?
    @State private var result: LastFmListeningHistoryPage?
    @State private var failure: Error?
    @State private var loading = false
    @Environment(\.dismiss) private var dismiss

    public init(service: LastFmService) {
        self.service = service
        _connection = State(initialValue: service.historyConnectionID)
    }

    private struct Request: Hashable {
        let connection: String?
        let page: Int
        let refresh: UUID
    }
    private var request: Request { .init(connection: service.historyConnectionID, page: page, refresh: refreshID) }

    public var body: some View {
        PublicMetaDBPage {
            SettingsPageHeader("Listening history")
            Text("These are your Last.fm scrobbles. Browsing does not change server history or play counts.")
                .foregroundStyle(.secondary)
            if loading { ProgressView() }
            if let failure {
                if failure as? TrackerHistoryError == .stalePreview {
                    Text("Listening history changed. Refresh before continuing.")
                } else if failure as? TrackerHistoryError == .scopeChanged {
                    Text("The connected profile changed. Reopen listening history.")
                } else {
                    Text((failure as? AppError ?? .invalidResponse).userMessage)
                }
            }
            if let result {
                if page == 1, let current = result.nowPlaying {
                    Text("Now playing").font(.headline)
                    track(current)
                }
                if result.plays.isEmpty { Text("No scrobbles in this history.") }
                ForEach(Array(result.plays.enumerated()), id: \.offset) { _, play in track(play) }
                if result.totalPages > 0 {
                    Text("Page \(result.page) of \(result.totalPages)").foregroundStyle(.secondary)
                }
                if result.page > 1 {
                    Button("Previous page") { page -= 1 }
                        .accessibilityIdentifier("lastfm.history.previous")
                        .disabled(loading)
                }
                if result.page < result.totalPages {
                    Button("Next page") { page += 1 }
                        .accessibilityIdentifier("lastfm.history.next")
                        .disabled(loading)
                }
            }
            Button("Refresh") {
                page = 1
                before = Int(Date().timeIntervalSince1970)
                expectedTotal = nil
                refreshID = UUID()
            }
            .accessibilityIdentifier("lastfm.history.refresh")
            .disabled(loading || service.historyConnectionID != connection)
        }
        .task(id: request) {
            let captured = request
            result = nil
            failure = nil
            loading = true
            defer { if request == captured { loading = false } }
            do {
                guard let connection, captured.connection == connection else { throw TrackerHistoryError.scopeChanged }
                let value = try await service.listeningHistory(page: page, before: before, expectedConnectionID: connection)
                try Task.checkCancellation()
                guard request == captured else { return }
                guard expectedTotal == nil || expectedTotal == value.totalPlays else { throw TrackerHistoryError.stalePreview }
                expectedTotal = value.totalPlays
                result = value
            } catch is CancellationError {
                return
            } catch {
                guard request == captured, !Task.isCancelled else { return }
                failure = error
            }
        }
        .onChange(of: service.historyConnectionID) { _, _ in dismiss() }
    }

    private func track(_ value: LastFmListeningHistoryPage.Track) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: value.title).font(.headline)
            Text(verbatim: value.artist).foregroundStyle(.secondary)
            if let album = value.album, !album.isEmpty { Text(verbatim: album).foregroundStyle(.secondary) }
            if let date = value.playedAt {
                Text(date, format: .dateTime.year().month().day().hour().minute()).foregroundStyle(.secondary)
            }
        }
        #if os(tvOS)
        .focusable()
        #endif
    }
}
#endif
