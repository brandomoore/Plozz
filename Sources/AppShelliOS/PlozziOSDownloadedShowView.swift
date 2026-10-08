#if os(iOS)
import CoreModels
import MediaDownloads
import SwiftUI
import CoreUI

/// The drill-in page for a single downloaded show: seasons as sections, each
/// with its own episode count, size, and a "Remove Season" action, plus a
/// toolbar action to remove the entire show. Reads the show live from the
/// model's grouped library so it updates as episodes are deleted, and pops
/// itself once the last episode is gone.
struct PlozziOSDownloadedShowView: View {
    let showID: String
    @Bindable var model: PlozziOSDownloadsModel
    let appModel: PlozziOSAppModel
    var initialSeasonID: String? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(\.themePalette) private var palette
    @State private var pendingBulkDeletion: PlozziOSDownloadsBulkDeletion?
    @State private var detailNav: PlozziOSDownloadDetailNav?

    var body: some View {
        let show = currentShow
        Group {
            if let show {
                ScrollViewReader { proxy in
                    GeometryReader { geometry in
                        List {
                            ForEach(show.seasons) { season in
                                PlozziOSDownloadedSeasonSection(
                                    season: season, model: model,
                                    horizontalInset: max(20, (geometry.size.width - 900) / 2),
                                    openEpisode: { item in
                                        detailNav = PlozziOSDownloadDetailNav(item: item)
                                    },
                                    removeSeason: {
                                        pendingBulkDeletion = .season(season, showTitle: show.title)
                                    }
                                )
                                .id(season.id)
                            }
                        }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                        .task(id: initialSeasonID) {
                            guard let initialSeasonID else { return }
                            await Task.yield()
                            proxy.scrollTo(initialSeasonID, anchor: .top)
                        }
                    }
                }
                .background { AppBackground(palette: palette) }
                .navigationTitle(show.title)
                .navigationBarTitleDisplayMode(.inline)
                .navigationDestination(item: $detailNav) { nav in
                    if let provider = appModel.provider(for: nav.item) {
                        PlozziOSItemDetailView(
                            appModel: appModel,
                            provider: provider,
                            item: nav.item,
                            seerService: appModel.seerService,
                            originSourceAccountID: nav.item.sourceAccountID,
                            presentsEpisodeAsSubject: nav.item.kind == .episode
                        )
                    } else {
                        ContentUnavailableView(
                            "Details Unavailable",
                            systemImage: "wifi.slash",
                            description: Text("Reconnect to view full details.")
                        )
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            if show.records.contains(where: \.isActiveDownload) {
                                Button {
                                    Task { await model.pause(show.records) }
                                } label: {
                                    Label("Pause Show", systemImage: "pause.fill")
                                }
                            } else if show.records.contains(where: \.isResumableDownload) {
                                Button {
                                    Task { await model.resume(show.records) }
                                } label: {
                                    Label("Resume Show", systemImage: "play.fill")
                                }
                            }
                            Button(role: .destructive) {
                                pendingBulkDeletion = .show(show)
                            } label: {
                                Label("Remove Show", systemImage: "trash")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }
            } else {
                ContentUnavailableView(
                    "No Downloads",
                    systemImage: "arrow.down.circle"
                )
            }
        }
        .confirmationDialog(
            pendingBulkDeletion.map { Text($0.title) } ?? Text(verbatim: ""),
            isPresented: Binding(
                get: { pendingBulkDeletion != nil },
                set: { if !$0 { pendingBulkDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let deletion = pendingBulkDeletion {
                Button(deletion.confirmLabel, role: .destructive) {
                    let records = deletion.records
                    pendingBulkDeletion = nil
                    Task { await model.remove(records) }
                }
                Button("Cancel", role: .cancel) { pendingBulkDeletion = nil }
            }
        } message: {
            if let deletion = pendingBulkDeletion {
                Text(deletion.message)
            }
        }
        .onChange(of: showStillExists) { _, exists in
            if !exists { dismiss() }
        }
        .task { await model.refreshArtwork() }
    }

    private var currentShow: PlozziOSDownloadedShow? {
        model.library.shows.first { $0.id == showID }
    }

    private var showStillExists: Bool {
        model.library.shows.contains { $0.id == showID }
    }

}

private struct PlozziOSDownloadedSeasonSection: View {
    let season: PlozziOSDownloadedSeason
    let model: PlozziOSDownloadsModel
    let horizontalInset: CGFloat
    let openEpisode: (MediaItem) -> Void
    let removeSeason: () -> Void

    var body: some View {
        Section {
            ForEach(season.records) { record in
                PlozziOSDownloadedEpisodeRow(record: record, model: model, openEpisode: openEpisode)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(
                        top: 6, leading: horizontalInset, bottom: 6, trailing: horizontalInset
                    ))
            }
        } header: {
            DownloadSeasonHeader(
                seasonNumber: season.seasonNumber,
                summary: DownloadFormatting.showSubtitle(
                    episodeCount: season.episodeCount, seasonCount: 1, bytes: season.totalBytes
                ),
                isRunning: season.records.contains(where: \.isActiveDownload),
                canResume: season.records.contains(where: \.isResumableDownload),
                toggle: {
                    Task {
                        if season.records.contains(where: \.isActiveDownload) {
                            await model.pause(season.records)
                        } else {
                            await model.resume(season.records)
                        }
                    }
                },
                remove: removeSeason
            )
            .textCase(nil)
            .listRowInsets(EdgeInsets(
                top: 16, leading: horizontalInset + 8, bottom: 6, trailing: horizontalInset
            ))
        }
    }
}

struct DownloadSeasonHeader: View {
    let seasonNumber: Int?
    let summary: LocalizedStringResource
    let isRunning: Bool
    let canResume: Bool
    let toggle: () -> Void
    let remove: () -> Void
    @Environment(\.themePalette) private var palette

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 5) {
                Group {
                    if let seasonNumber {
                        Text("Season \(seasonNumber)")
                    } else {
                        Text("Episodes")
                    }
                }
                .font(.title3.weight(.bold))
                .foregroundStyle(palette.primaryText)
                .accessibilityAddTraits(.isHeader)
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if isRunning || canResume {
                Button(action: toggle) {
                    Image(systemName: isRunning ? "pause.fill" : "play.fill")
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(isRunning ? Text("Pause") : Text("Resume"))
            }
            Menu {
                Button("Remove", systemImage: "trash", role: .destructive, action: remove)
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("More actions")
            .foregroundStyle(palette.secondaryText)
        }
    }
}

private struct PlozziOSDownloadedEpisodeRow: View {
    let record: DownloadedMediaRecord
    let model: PlozziOSDownloadsModel
    let openEpisode: (MediaItem) -> Void

    var body: some View {
        DownloadCompactCard(menu: {
            if record.isActiveDownload {
                Button("Pause", systemImage: "pause.fill") {
                    Task { await model.pause(record) }
                }
            } else if record.isResumableDownload {
                Button("Resume", systemImage: "play.fill") {
                    Task { await model.resume(record) }
                }
            }
            Button("Remove", systemImage: "trash", role: .destructive) {
                Task { await model.remove(record) }
            }
        }, accessibilityTitle: record.snapshot.title) {
            Button {
                if let item = model.playbackItem(for: record) ?? model.detailItem(for: record) {
                    openEpisode(item)
                }
            } label: {
                DownloadRowContent(
                    title: DownloadFormatting.episodeLabel(for: record),
                    subtitle: DownloadFormatting.status(for: record),
                    subtitleColor: DownloadFormatting.statusColor(for: record),
                    fraction: DownloadFormatting.activeFraction(for: record),
                    failure: DownloadFormatting.failure(for: record),
                    artworkURL: model.artworkURL(for: record),
                    kind: record.snapshot.kind
                )
            }
            .buttonStyle(.plain)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button("Remove", systemImage: "trash", role: .destructive) {
                Task { await model.remove(record) }
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            if record.isActiveDownload {
                Button {
                    Task { await model.pause(record) }
                } label: {
                    Label("Pause", systemImage: "pause.fill")
                }
                .tint(.orange)
            } else if record.isResumableDownload {
                Button {
                    Task { await model.resume(record) }
                } label: {
                    Label("Resume", systemImage: "play.fill")
                }
                .tint(.blue)
            }
        }
    }
}

private extension DownloadedMediaRecord {
    var isActiveDownload: Bool {
        status == .queued || status == .preparing || status == .downloading
    }

    var isResumableDownload: Bool {
        status == .paused || status == .failed
    }
}

/// Identifiable wrapper so a downloaded episode's detail page can be pushed via
/// `navigationDestination(item:)` from the Downloads show page.
struct PlozziOSDownloadDetailNav: Identifiable, Hashable {
    let item: MediaItem
    var id: String { item.id }

    static func == (
        lhs: PlozziOSDownloadDetailNav,
        rhs: PlozziOSDownloadDetailNav
    ) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
#endif
