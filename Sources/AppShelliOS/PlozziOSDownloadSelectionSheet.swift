#if os(iOS)
import CoreModels
import CoreUI
import FeatureHomeCore
import MediaDownloads
import ProviderShare
import SwiftUI

struct PlozziOSSingleItemDownloadSheet: View {
    @Environment(PlozziOSAppModel.self) private var appModel
    let item: MediaItem
    let onFinish: () -> Void

    var body: some View {
        PlozziOSDownloadSelectionSheet(
            title: appModel.settings.spoilers.settings.shouldHideText(for: item)
                ? Text(appModel.settings.spoilers.settings.maskedTitle(for: item))
                : Text(verbatim: item.title),
            items: [item], resolvesSingleItem: true, isBulk: false, onFinish: onFinish
        ) { options, quality in
            guard let provider = appModel.provider(for: item) else {
                throw PlozziOSDownloadError.unavailable("The selected server is no longer available.")
            }
            if options.count == 1, let option = options.first {
                _ = try await appModel.downloads.enqueue(item: option.item, provider: provider, quality: quality)
            } else {
                guard item.kind == .episode else {
                    throw PlozziOSDownloadError.unavailable("Select one version.")
                }
                _ = try await appModel.downloads.enqueueSeason(
                    season: item, episodes: options.map(\.item), provider: provider, quality: quality
                )
            }
        }
    }
}

struct PlozziOSDownloadSelectionSheet: View {
    @Environment(PlozziOSAppModel.self) private var appModel
    @State private var quality: DownloadQuality = .original
    @State private var preparedProfileID: String?
    @State private var availableSpace: String?
    @State private var resolvedItems: [MediaItem] = []

    let title: Text
    let items: [MediaItem]
    var resolvesSingleItem = false
    var isBulk = true
    let onFinish: () -> Void
    let onDownload: ([EpisodeDownloadSelection.Option], DownloadQuality) async throws -> Void

    var body: some View {
        PlozziOSDownloadSelectionPresenter(
            alwaysAsk: appModel.downloads.asksBeforeDownloading,
            isBulk: isBulk,
            prepare: prepare,
            onDownload: { selection in
                guard appModel.isActiveProfileAuthorized,
                      preparedProfileID == appModel.profiles.activeProfileID else { throw CancellationError() }
                try await onDownload(selection.selectedOptions, quality)
            },
            onFinish: onFinish
        ) { selection, isDownloading, cancel, download in
            PlozziOSDownloadSelectionContent(
                title: title,
                selection: selection,
                quality: $quality,
                supportsReducedQuality: resolvedItems.allSatisfy {
                    appModel.downloads.supportsReducedQuality(for: $0)
                },
                customQuality: appModel.downloads.customDownloadQuality,
                customQualityTitle: appModel.downloads.customDownloadQualityTitle,
                availableSpace: availableSpace,
                spoilers: appModel.settings.spoilers.settings,
                sourceDetails: sourceDetails,
                isBulk: isBulk,
                isDownloading: isDownloading,
                onCancel: cancel,
                onDownload: download
            )
        }
        .onChange(of: appModel.profiles.activeProfileID) { _, _ in onFinish() }
        .onChange(of: appModel.isActiveProfileAuthorized) { _, authorized in
            if !authorized { onFinish() }
        }
    }

    private func prepare() async throws -> EpisodeDownloadSelection {
        let currentProfile = appModel.profiles.activeProfileID
        guard appModel.isActiveProfileAuthorized else { throw CancellationError() }
        if let bytes = try? DownloadStorageCapacity.device.availableBytes(at: .documentsDirectory) {
            availableSpace = MediaFileSizeFormatter.string(fromByteCount: bytes)
        }
        let choices = try await loadItems()
        try Task.checkCancellation()
        guard appModel.profiles.activeProfileID == currentProfile else { throw CancellationError() }
        var checked = Set<String>()
        for item in choices where checked.insert(item.sourceAccountID ?? "").inserted {
            guard let provider = appModel.provider(for: item) else { continue }
            await appModel.downloads.refreshReducedQualitySupport(for: item, provider: provider)
            try Task.checkCancellation()
            guard appModel.profiles.activeProfileID == currentProfile else { throw CancellationError() }
        }
        if choices.allSatisfy({ appModel.downloads.supportsReducedQuality(for: $0) }) {
            quality = appModel.downloads.downloadQuality
        }
        try Task.checkCancellation()
        guard appModel.profiles.activeProfileID == currentProfile else { throw CancellationError() }
        preparedProfileID = currentProfile
        resolvedItems = choices
        return EpisodeDownloadSelection(
            items: choices, preferences: appModel.versionPreferences,
            capabilities: .detected()
        )
    }

    private func sourceDetails(_ option: EpisodeDownloadSelection.Option) -> PlozziOSDownloadSourceDetails {
        PlozziOSDownloadSourceDetails(item: option.item, accounts: appModel.accounts)
    }

    private func loadItems() async throws -> [MediaItem] {
        guard resolvesSingleItem, let seed = items.first else { return items }
        guard let provider = appModel.provider(for: seed) else {
            throw PlozziOSDownloadError.unavailable("The selected server is no longer available.")
        }
        let detail = try await provider.item(id: seed.id)
        try Task.checkCancellation()
        guard detail.id == seed.id,
              detail.sourceAccountID == nil || detail.sourceAccountID == seed.sourceAccountID else {
            throw AppError.notFound
        }
        var item = PlayerVersionSelection.item(opened: seed, resolved: detail, authoritativeVersions: true)
        item.mediaInfo = detail.mediaInfo ?? item.mediaInfo
        let knownItems = [item] + items.filter { $0.stablePresentationID != item.stablePresentationID }
        guard item.kind == .episode, let seasonID = item.seasonID else { return knownItems }
        let children = try await provider.children(of: seasonID)
        try Task.checkCancellation()
        let candidates = children.filter {
            $0.kind == .episode && $0.locallyValidatedPlayableSource && $0.scheduledAirDate == nil
                && ($0.sourceAccountID == nil || $0.sourceAccountID == seed.sourceAccountID)
        }.map { child in
            var copy = child
            copy.sourceAccountID = seed.sourceAccountID
            return copy
        }
        return EpisodeDownloadSelection.groupedItems(knownItems + candidates)
            .first { $0.contains(where: { $0.stablePresentationID == item.stablePresentationID }) } ?? [item]
    }
}

/// Preparation and automatic downloads never present a sheet. Only a prepared
/// selection requiring a decision can enter the modal presentation path.
struct PlozziOSDownloadSelectionPresenter<Content: View>: View {
    private struct Confirmation: Identifiable {
        let id = UUID()
        let selection: EpisodeDownloadSelection
    }

    let alwaysAsk: Bool
    let isBulk: Bool
    let prepare: () async throws -> EpisodeDownloadSelection
    let onDownload: (EpisodeDownloadSelection) async throws -> Void
    let onFinish: () -> Void
    @ViewBuilder let content: (
        Binding<EpisodeDownloadSelection>, Bool, @escaping () -> Void, @escaping () -> Void
    ) -> Content
    @State private var selection: EpisodeDownloadSelection?
    @State private var confirmation: Confirmation?
    @State private var isDownloading = false
    @State private var errorMessage: String?
    @State private var attempt = 0

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .task(id: attempt) {
                do {
                    let prepared = try await prepare()
                    try Task.checkCancellation()
                    guard !prepared.episodes.isEmpty else {
                        throw PlozziOSDownloadError.unavailable("No downloadable versions are available.")
                    }
                    selection = prepared
                    if prepared.requiresConfirmation(alwaysAsk: alwaysAsk, isBulk: isBulk) {
                        confirmation = Confirmation(selection: prepared)
                    } else {
                        isDownloading = true
                    }
                } catch is CancellationError {
                    guard !Task.isCancelled else { return }
                    onFinish()
                } catch {
                    guard !Task.isCancelled else { return }
                    errorMessage = error.localizedDescription
                }
            }
            .task(id: isDownloading) {
                guard isDownloading, let selection else { return }
                do {
                    try Task.checkCancellation()
                    try await onDownload(selection)
                    try Task.checkCancellation()
                    if confirmation != nil { confirmation = nil } else { onFinish() }
                } catch is CancellationError {
                    guard !Task.isCancelled else { return }
                    if confirmation != nil { confirmation = nil } else { onFinish() }
                } catch {
                    guard !Task.isCancelled else { return }
                    errorMessage = error.localizedDescription
                }
                isDownloading = false
            }
            .plozzSheet(item: $confirmation, onDismiss: onFinish) { presented in
                content(
                    Binding(get: { selection ?? presented.selection }, set: { selection = $0 }),
                    isDownloading, { confirmation = nil }, { isDownloading = true }
                )
                .interactiveDismissDisabled(isDownloading)
                .alert("Download Failed", isPresented: errorPresented(inSheet: true)) {
                    Button("OK", role: .cancel) { errorMessage = nil }
                } message: {
                    Text(verbatim: errorMessage ?? "")
                }
            }
            .alert("Download Failed", isPresented: errorPresented(inSheet: false)) {
                Button("Try Again") { errorMessage = nil; attempt += 1 }
                Button("Cancel", role: .cancel) { onFinish() }
            } message: {
                Text(verbatim: errorMessage ?? "")
            }
    }

    private func errorPresented(inSheet: Bool) -> Binding<Bool> {
        Binding(
            get: { errorMessage != nil && (confirmation != nil) == inSheet },
            set: { if !$0 { errorMessage = nil } }
        )
    }
}

struct PlozziOSDownloadSourceDetails {
    let name: String?
    let folder: String?

    init(item: MediaItem, accounts: [Account]) {
        let account = accounts.first { $0.id == item.sourceAccountID }
        let source = item.sources.first { $0.accountID == item.sourceAccountID && $0.itemID == item.id }
        name = account.map {
            MediaSourceRef(
                accountID: $0.id, itemID: item.id, providerKind: $0.server.provider,
                serverName: $0.server.name, accountName: $0.userName
            ).displayName
        } ?? source?.displayName
        guard account?.server.provider == .mediaShare || source?.providerKind == .mediaShare,
              let path = ShareProvider.exactFileRelativePath(for: item) ?? item.selectedVersionID,
              !path.contains("://"), !path.hasPrefix("/"),
              !path.contains("?"), !path.contains("#") else {
            folder = nil
            return
        }
        let parent = (path as NSString).deletingLastPathComponent
        folder = parent.isEmpty ? "/" : parent
    }
}

/// Shared by the real sheet and hosted interaction fixtures.
struct PlozziOSDownloadSelectionContent: View {
    let title: Text
    @Binding var selection: EpisodeDownloadSelection
    @Binding var quality: DownloadQuality
    var supportsReducedQuality = false
    var customQuality: DownloadQuality?
    var customQualityTitle: LocalizedStringResource?
    var availableSpace: String?
    var spoilers: SpoilerSettings = .default
    var sourceDetails: (EpisodeDownloadSelection.Option) -> PlozziOSDownloadSourceDetails = {
        PlozziOSDownloadSourceDetails(item: $0.item, accounts: [])
    }
    var isBulk = true
    var isDownloading = false
    let onCancel: () -> Void
    let onDownload: () -> Void

    private struct Season: Identifiable {
        let id: String
        let number: Int?
        let episodes: [EpisodeDownloadSelection.Episode]
    }

    private var seasons: [Season] {
        var order: [String] = []
        var grouped: [String: [EpisodeDownloadSelection.Episode]] = [:]
        for episode in selection.episodes {
            let item = episode.item
            let key = [item.sourceAccountID ?? "", item.seriesID ?? "", item.seasonNumber.map(String.init) ?? ""]
                .map { Data($0.utf8).base64EncodedString() }.joined(separator: ":")
            if grouped[key] == nil { order.append(key) }
            grouped[key, default: []].append(episode)
        }
        return order.map { key in
            let episodes = grouped[key] ?? []
            return Season(id: key, number: episodes.first?.item.seasonNumber, episodes: episodes)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if supportsReducedQuality {
                        Picker("Quality", selection: $quality) {
                            Text("Original").tag(DownloadQuality.original)
                            Text("1080p • 20 Mbps").tag(DownloadQuality.hd1080)
                            Text("720p • 4 Mbps").tag(DownloadQuality.hd720)
                            Text("480p • 1.5 Mbps").tag(DownloadQuality.sd480)
                            if let customQuality, let customQualityTitle {
                                Text(customQualityTitle).tag(customQuality)
                            }
                        }
                    }
                    LabeledContent("Selected", value: selection.selectedOptions.count.formatted())
                    if let size = selectedSize {
                        LabeledContent("Size", value: size)
                    }
                    if let availableSpace {
                        LabeledContent("Available", value: availableSpace)
                    }
                } header: {
                    title
                } footer: {
                    if isBulk, selection.episodes.contains(where: { $0.item.kind == .episode && $0.options.count > 1 }) {
                        Text("Open an episode to change its selected versions.")
                    }
                }

                if !isBulk, selection.episodes.count == 1, let focused = selection.episodes.first {
                    if focused.item.kind == .episode || focused.options.count > 1 {
                        Section {
                            versionRows(for: focused)
                        } header: {
                            Text("Versions")
                        } footer: {
                            if focused.item.kind == .episode, focused.options.count > 1 {
                                Text("Each selected version downloads a separate file.")
                            }
                        }
                    }
                } else {
                    ForEach(seasons) { season in
                        Section {
                            ForEach(season.episodes) { episode in
                                episodeRow(episode)
                            }
                        } header: {
                            if let number = season.number {
                                Text("Season \(number)")
                            } else {
                                Text("Episodes")
                            }
                        }
                    }
                }
            }
            .disabled(isDownloading)
            .navigationTitle("Download")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel).disabled(isDownloading)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isDownloading {
                        ProgressView()
                    } else {
                        Button("Download", action: onDownload)
                            .disabled(selection.selectedOptions.isEmpty)
                            .accessibilityIdentifier("confirm-download-selection")
                    }
                }
            }
        }
    }

    private var selectedSize: String? {
        guard quality == .original, !selection.selectedOptions.isEmpty else { return nil }
        var total: Int64 = 0
        for option in selection.selectedOptions {
            guard let size = option.version.sizeBytes, size > 0 else { return nil }
            let sum = total.addingReportingOverflow(size)
            guard !sum.overflow else { return nil }
            total = sum.partialValue
        }
        return MediaFileSizeFormatter.string(fromByteCount: total)
    }

    private func episodeTitle(_ episode: EpisodeDownloadSelection.Episode) -> Text {
        if spoilers.shouldHideText(for: episode.item) {
            return episode.item.episodeNumber.map { Text("Episode \($0)") } ?? Text("Episode")
        }
        return Text(verbatim: episode.item.title)
    }

    @ViewBuilder
    private func episodeRow(_ episode: EpisodeDownloadSelection.Episode) -> some View {
        let selected = episode.options.filter { selection.selectedIDs.contains($0.id) }
        HStack(spacing: 12) {
            Button {
                selection.setSelected(selected.isEmpty, episode: episode)
            } label: {
                Image(systemName: selected.isEmpty ? "circle" : "checkmark.circle.fill")
                    .frame(minWidth: 44, minHeight: 44)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(episodeTitle(episode))
            .accessibilityValue(selected.isEmpty ? Text("Not selected") : Text("Selected"))
            .accessibilityIdentifier("select-episode-\(episode.item.seasonNumber ?? 0)-\(episode.item.episodeNumber ?? 0)")

            if episode.options.count > 1 {
                NavigationLink {
                    versions(for: episode)
                } label: {
                    episodeLabel(episode, selected: selected)
                }
                .accessibilityIdentifier("episode-versions-\(episode.item.seasonNumber ?? 0)-\(episode.item.episodeNumber ?? 0)")
            } else {
                episodeLabel(episode, selected: selected)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func episodeLabel(
        _ episode: EpisodeDownloadSelection.Episode,
        selected: [EpisodeDownloadSelection.Option]
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let number = episode.item.episodeNumber, !spoilers.shouldHideText(for: episode.item) {
                Text("Episode \(number)").font(.caption).foregroundStyle(.secondary)
            }
            episodeTitle(episode)
            if selected.count > 1 {
                Text("\(selected.count) versions selected").font(.caption).foregroundStyle(.secondary)
            } else if let version = selected.first?.version, let detail = technicalSummary(version) {
                Text(verbatim: detail).font(.caption).foregroundStyle(.secondary)
            }
            if episode.options.count > 1 {
                Text("\(episode.options.count) versions").font(.caption).foregroundStyle(.secondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func versions(for episode: EpisodeDownloadSelection.Episode) -> some View {
        List {
            Section {
                versionRows(for: episode)
            } footer: {
                Text("Each selected version downloads a separate file.")
            }
        }
        .navigationTitle(episodeTitle(episode))
        .navigationBarTitleDisplayMode(.inline)
        .disabled(isDownloading)
    }

    private func versionRows(for episode: EpisodeDownloadSelection.Episode) -> some View {
        ForEach(Array(episode.options.enumerated()), id: \.element.id) { index, option in
            Button {
                if episode.item.kind == .movie {
                    for candidate in episode.options {
                        selection.setSelected(false, optionID: candidate.id)
                    }
                    selection.setSelected(true, optionID: option.id)
                    return
                }
                selection.setSelected(!selection.selectedIDs.contains(option.id), optionID: option.id)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: selection.selectedIDs.contains(option.id) ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(.tint)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Version \(index + 1)")
                            .foregroundStyle(.primary)
                        let source = sourceDetails(option)
                        if let name = source.name {
                            Text(verbatim: name).font(.subheadline).foregroundStyle(.secondary)
                        } else {
                            Text("Selected server").font(.subheadline).foregroundStyle(.secondary)
                        }
                        if !spoilers.shouldHideText(for: episode.item), let folder = source.folder {
                            Text(verbatim: folder).font(.caption).foregroundStyle(.secondary)
                        }
                        if let detail = technicalSummary(option.version) {
                            Text(verbatim: detail).font(.subheadline).foregroundStyle(.secondary)
                        }
                        if !spoilers.shouldHideText(for: episode.item),
                           let file = option.version.fileName ?? option.version.name {
                            Text(verbatim: file).font(.caption).foregroundStyle(.secondary)
                        }
                        if option.id == episode.recommendedID {
                            Text("Recommended").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(selection.selectedIDs.contains(option.id) ? Text("Selected") : Text("Not selected"))
            .accessibilityIdentifier("download-version-\(index + 1)")
        }
    }

    private func technicalSummary(_ version: MediaVersion) -> String? {
        let parts = [
            version.resolutionLabel, version.hdrLabel,
            version.audioLabel, MediaFileSizeFormatter.string(fromByteCount: version.sizeBytes)
        ].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
#endif
