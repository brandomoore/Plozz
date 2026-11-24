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
    @Environment(\.themePalette) private var palette

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
        GroupedSettingsPage(title: "Listening history", backIdentifier: "lastfm.history.back") {
            if loading { ProgressView("Loading listening history…") }
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
                    SettingsSectionGroup("Now playing") { track(current) }
                }
                SettingsSectionGroup("Last.fm scrobbles") {
                    if result.plays.isEmpty { Text("No scrobbles in this history.") }
                    ForEach(Array(result.plays.enumerated()), id: \.offset) { _, play in track(play) }
                }
                if result.totalPages > 1 {
                    SettingsSectionGroup("Page \(result.page, format: .number) of \(result.totalPages, format: .number)") {
                        if result.page > 1 {
                            Button("Previous page") { page -= 1 }
                                .settingsActionRow()
                                .accessibilityIdentifier("lastfm.history.previous")
                                .disabled(loading)
                        }
                        if result.page < result.totalPages {
                            Button("Next page") { page += 1 }
                                .settingsActionRow()
                                .accessibilityIdentifier("lastfm.history.next")
                                .disabled(loading)
                        }
                    }
                }
            }
            SettingsSectionGroup {
                Button("Refresh") {
                    page = 1
                    before = Int(Date().timeIntervalSince1970)
                    expectedTotal = nil
                    refreshID = UUID()
                }
                .settingsActionRow()
                .accessibilityIdentifier("lastfm.history.refresh")
                .disabled(loading || service.historyConnectionID != connection)
            }
        }
        .tint(palette.primaryText)
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
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: value.title).font(.headline)
            if let album = value.album, !album.isEmpty {
                Text(verbatim: "\(value.artist) · \(album)").settingsRowSecondary()
            } else {
                Text(verbatim: value.artist).settingsRowSecondary()
            }
            if let date = value.playedAt {
                Text(date, format: .dateTime.year().month().day().hour().minute())
                    .font(SettingsRowMetrics.descriptionFont).settingsRowSecondary()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        #if os(tvOS)
        .focusable()
        #endif
    }
}
#endif
