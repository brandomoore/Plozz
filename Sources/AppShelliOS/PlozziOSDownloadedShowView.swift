#if os(iOS)
import CoreModels
import MediaDownloads
import SwiftUI
import CoreUI

/// The drill-in page for a single downloaded show: episodes grouped by season, each
/// with its own episode count, size, and removal actions. Reads the show live from the
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
    @State private var editMode: EditMode = .inactive
    @State private var selectedIDs: Set<String> = []
    @State private var playbackRequest: PlozziOSPlaybackRequest?
    @State private var pendingResumeRequest: PlozziOSPlaybackRequest?

    var body: some View {
        let show = currentShow
        Group {
            if let show {
                ScrollViewReader { proxy in
                    GeometryReader { geometry in
                        let horizontalInset = max(20, (geometry.size.width - 900) / 2)
                        List(selection: $selectedIDs) {
                            Text(show.title)
                                .font(.largeTitle.bold())
                                .foregroundStyle(palette.primaryText)
                                .accessibilityAddTraits(.isHeader)
                                .accessibilityIdentifier("download-show-title")
                                .selectionDisabled()
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                                .listRowInsets(EdgeInsets(
                                    top: 0, leading: horizontalInset, bottom: 0, trailing: horizontalInset
                                ))
                            ForEach(show.seasons) { season in
                                PlozziOSDownloadedSeasonRows(
                                    season: season, model: model, appModel: appModel,
                                    horizontalInset: horizontalInset,
                                    isEditing: editMode.isEditing,
                                    openEpisode: { item in
                                        detailNav = PlozziOSDownloadDetailNav(item: item)
                                    },
                                    playEpisode: play,
                                    removeSeason: {
                                        pendingBulkDeletion = .season(season, showTitle: show.title)
                                    }
                                )
                            }
                        }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                        .environment(\.editMode, $editMode)
                        .task(id: initialSeasonID) {
                            guard let initialSeasonID else { return }
                            await Task.yield()
                            proxy.scrollTo(initialSeasonID, anchor: .top)
                        }
                    }
                }
                .background { AppBackground(palette: palette) }
                .navigationTitle(Text(verbatim: ""))
                .navigationBarTitleDisplayMode(.inline)
                // Capturing this view's dismiss environment creates an iOS 18 navigation update loop.
                .navigationDestination(item: $detailNav) { [appModel] nav in
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
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        if editMode.isEditing {
                            Button("Select All") {
                                selectedIDs = Set(show.records.map(\.id))
                            }
                            Button("Remove", role: .destructive) {
                                pendingBulkDeletion = .selection(
                                    show.records.filter { selectedIDs.contains($0.id) }
                                )
                            }
                            .disabled(selectedIDs.isEmpty)
                            .accessibilityIdentifier("download-remove-selected")
                        }
                        EditButton()
                            .environment(\.editMode, $editMode)
                    }
                }
            } else {
                ContentUnavailableView(
                    "No Downloads",
                    systemImage: "arrow.down.circle"
                )
            }
        }
        .detailOpenFeedback()
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
                    Task {
                        await model.remove(records)
                        selectedIDs.subtract(records.map(\.id))
                    }
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
        .onChange(of: currentShow?.records.map(\.id)) { _, ids in
            selectedIDs.formIntersection(ids ?? [])
        }
        .onChange(of: editMode) { _, mode in
            if !mode.isEditing {
                selectedIDs.removeAll()
                pendingBulkDeletion = nil
            }
        }
        .onChange(of: appModel.profiles.activeProfileID) { _, _ in
            endEditing()
            pendingResumeRequest = nil
        }
        .onChange(of: appModel.isActiveProfileAuthorized) { _, authorized in
            if !authorized {
                endEditing()
                pendingResumeRequest = nil
            }
        }
        .resumePrompt(request: $pendingResumeRequest, mediaItem: { $0.item }) { request, position in
            var request = request
            request.startPosition = position
            pendingResumeRequest = nil
            playbackRequest = request
        }
        .plozziOSPlayerCover(
            item: $playbackRequest, orientation: appModel.settings.playback.settings.orientation
        ) { [appModel] request, orientation in
            if let provider = appModel.provider(for: request.item) {
                PlozziOSPlayerView(request: request, provider: provider, orientation: orientation)
            } else {
                ContentUnavailableView("Server unavailable", systemImage: "server.rack")
            }
        }
        .onDisappear { pendingResumeRequest = nil }
        .task { await model.refreshArtwork() }
    }

    private func endEditing() {
        editMode = .inactive
        selectedIDs.removeAll()
        pendingBulkDeletion = nil
    }

    private func play(_ item: MediaItem) {
        guard appModel.isActiveProfileAuthorized else { return }
        let request = PlozziOSPlaybackRequest(
            item: item, startPosition: item.resumePosition ?? 0,
            versionPreferences: appModel.versionPreferences
        )
        if appModel.settings.playback.settings.shouldAskBeforeResuming(at: request.startPosition) {
            pendingResumeRequest = request
        } else {
            playbackRequest = request
        }
    }

    private var currentShow: PlozziOSDownloadedShow? {
        let library = appModel.isOfflineMode ? model.offlineLibrary : model.library
        return library.shows.first { $0.id == showID }
    }

    private var showStillExists: Bool {
        currentShow != nil
    }

}

private struct PlozziOSDownloadedSeasonRows: View {
    let season: PlozziOSDownloadedSeason
    let model: PlozziOSDownloadsModel
    let appModel: PlozziOSAppModel
    let horizontalInset: CGFloat
    let isEditing: Bool
    let openEpisode: (MediaItem) -> Void
    let playEpisode: (MediaItem) -> Void
    let removeSeason: () -> Void

    var body: some View {
        Group {
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
            .id(season.id)
            .selectionDisabled()
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .textCase(nil)
            .listRowInsets(EdgeInsets(
                top: 16, leading: horizontalInset, bottom: 6, trailing: horizontalInset
            ))
            ForEach(season.records) { record in
                PlozziOSDownloadedEpisodeRow(
                    record: record, model: model, appModel: appModel,
                    isEditing: isEditing, openEpisode: openEpisode, playEpisode: playEpisode
                )
                    .tag(record.id)
                    .selectionDisabled(!isEditing)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(
                        top: 6, leading: horizontalInset, bottom: 6, trailing: horizontalInset
                    ))
            }
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
    let appModel: PlozziOSAppModel
    let isEditing: Bool
    let openEpisode: (MediaItem) -> Void
    let playEpisode: (MediaItem) -> Void

    var body: some View {
        let item = model.playbackItem(for: record) ?? model.detailItem(for: record)
        DownloadCompactCard(menu: {
            Button("Play", systemImage: "play.fill") {
                if let item { playEpisode(item) }
            }
            .disabled(record.status != .completed || item.flatMap { appModel.provider(for: $0) } == nil)
            PlozziOSDownloadNavigationAction(
                records: [record], model: model, appModel: appModel, open: openEpisode
            )
            if record.isActiveDownload {
                Button("Pause", systemImage: "pause.fill") {
                    Task { await model.pause(record) }
                }
            } else if record.isResumableDownload {
                Button("Resume", systemImage: "play.fill") {
                    Task { await model.resume(record) }
                }
            }
            PlozziOSDownloadSubtitleAction(record: record, model: model)
            Button("Remove Download", systemImage: "trash", role: .destructive) {
                Task { await model.remove(record) }
            }
        }, accessibilityTitle: record.snapshot.title) {
            let content = DownloadRowContent(
                title: DownloadFormatting.episodeLabel(for: record),
                subtitle: DownloadFormatting.status(for: record),
                status: record.status,
                fraction: DownloadFormatting.activeFraction(for: record),
                failure: DownloadFormatting.failure(for: record),
                artworkURL: model.artworkURL(for: record),
                kind: record.snapshot.kind
            )
            if isEditing {
                content
            } else {
                Button {
                    if let item { openEpisode(item) }
                } label: {
                    content
                }
                .buttonStyle(.plain)
            }
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
