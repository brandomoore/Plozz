#if os(iOS)
import CoreModels
import CoreUI
import SwiftUI

/// The request-only season manager shared by Home and detail heroes.
struct PlozziOSSeasonRequestSheet: View {
    @Environment(\.dismiss) private var dismiss
    let series: MediaItem
    let availability: MediaRequestAvailability?
    let isRequesting: Bool
    let isRefreshing: Bool
    let refreshFailed: Bool
    let actingName: String?
    let onRefresh: () -> Void
    let onRequest: ([Int]) -> Void

    var body: some View {
        let seasons = SeriesDownloadSeasons(
            librarySeasons: [], looseEpisodes: [], requestAvailability: availability
        )
        NavigationStack {
            List {
                SeriesDownloadActions(
                    hasDownloads: false, canRequestSeasons: true,
                    availability: seasons.requestAvailability,
                    isSubmitting: isRequesting, isRefreshing: isRefreshing,
                    refreshFailed: refreshFailed, actingName: actingName,
                    onRefresh: onRefresh, onRequest: onRequest
                ) {
                    EmptyView()
                }
                if !seasons.rows.isEmpty {
                    Section {
                        ForEach(seasons.rows) { row in
                            PlozziOSSeasonRequestRow(
                                row: row, isRequesting: isRequesting, onRequest: onRequest
                            )
                        }
                    } header: {
                        Text(verbatim: series.title).textCase(nil)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .contentMargins(.top, 12, for: .scrollContent)
            .listSectionSpacing(16)
            .navigationTitle("Seasons")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    SeasonRequestRefreshButton(
                        isRefreshing: isRefreshing, isSubmitting: isRequesting, onRefresh: onRefresh
                    )
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}

struct PlozziOSSeasonRequestRow: View {
    let row: SeriesDownloadSeason
    let isRequesting: Bool
    let onRequest: ([Int]) -> Void

    var body: some View {
        if row.canRequest, let number = row.number {
            Button { onRequest([number]) } label: { label }
                .buttonStyle(.plain)
                .disabled(isRequesting)
                .accessibilityLabel(Text("Request \(Text(row.title))"))
        } else {
            label
        }
    }

    private var label: some View {
        SeasonDownloadRowContent(
            title: Text(row.title), status: row.statusTitle,
            statusSystemImage: row.statusSystemImage,
            showsRequestAction: row.canRequest, completedDownloadCount: 0
        ) {
            SeasonDownloadRowArtwork(showsMediaEdge: false) {
                MediaArtworkPlaceholder(glyphSize: 16, symbol: .media)
            }
        } accessory: {
            EmptyView()
        }
    }
}
#endif
