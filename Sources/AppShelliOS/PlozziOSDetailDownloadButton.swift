#if os(iOS)
import CoreModels
import CoreUI
import MediaDownloads
import SwiftUI

/// The single-item counterpart of the season manager, always hosted in the detail toolbar.
struct PlozziOSDetailDownloadButton: View {
    @Environment(PlozziOSAppModel.self) private var appModel
    @State private var downloadRecord: DownloadedMediaRecord?
    @State private var downloadError: String?
    @State private var showsDownloadConfirmation = false
    @State private var showsVersionSelection = false

    let downloadItem: MediaItem
    let selectedSource: MediaSourceRef?
    let selectedVersion: MediaVersion?

    var body: some View {
        Group {
            if downloadItem.kind == .episode, let record = currentDownloadRecord, record.status == .completed {
                let profileID = appModel.profiles.activeProfileID
                PlozziOSRemoveDownloadButton {
                    Task { await appModel.removeConfirmedDownload(record, profileID: profileID) }
                } label: {
                    Image(systemName: downloadActionSymbol)
                }
                .id("\(profileID):\(record.identityKey)")
                .contextMenu {
                    Button("Choose Versions") { showsVersionSelection = true }
                }
            } else {
                Button {
                    guard !showsVersionSelection else { return }
                    Task { await performDownloadAction() }
                } label: {
                    Image(systemName: downloadActionSymbol)
                }
                .accessibilityLabel(downloadActionTitle)
            }
        }
        .task {
            downloadRecord = await appModel.downloads.record(forSelectedVersionOf: downloadItem)
            if let provider = appModel.provider(for: downloadItem) {
                await appModel.downloads.refreshReducedQualitySupport(
                    for: downloadItem,
                    provider: provider
                )
            }
        }
        .alert(
            "Download Failed",
            isPresented: Binding(
                get: { downloadError != nil },
                set: { if !$0 { downloadError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(verbatim: downloadError ?? "")
        }
        .confirmationDialog(
            (currentDownloadRecord?.status == .completed
                ? Text("Change Offline Copy of ")
                : Text("Download "))
                + Text(verbatim: downloadItem.title)
                + Text(verbatim: "?"),
            isPresented: $showsDownloadConfirmation,
            titleVisibility: .visible
        ) {
            Button(
                currentDownloadRecord?.status == .completed
                    ? "Use Original"
                    : "Download Original"
            ) {
                Task { await startDownload(quality: .original) }
            }
            if appModel.downloads.supportsReducedQuality(for: downloadItem) {
                Button("Download 1080p • 20 Mbps") {
                    Task { await startDownload(quality: .hd1080) }
                }
                Button("Download 720p • 4 Mbps") {
                    Task { await startDownload(quality: .hd720) }
                }
                Button("Download 480p • 1.5 Mbps") {
                    Task { await startDownload(quality: .sd480) }
                }
                if let custom = appModel.downloads.customDownloadQuality,
                   let title = appModel.downloads.customDownloadQualityTitle {
                    Button(title) {
                        Task { await startDownload(quality: custom) }
                    }
                }
            }
            if currentDownloadRecord?.status == .completed {
                Button("Remove Download", role: .destructive) {
                    Task { await removeDownload() }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            downloadConfirmationMessage
        }
        .background {
            if showsVersionSelection {
                PlozziOSSingleItemDownloadSheet(item: downloadItem) {
                    showsVersionSelection = false
                    Task {
                        downloadRecord = await appModel.downloads.record(forSelectedVersionOf: downloadItem)
                    }
                }
                .id(downloadItem.stablePresentationID)
            }
        }
    }

    private var downloadActionTitle: LocalizedStringResource {
        switch currentDownloadRecord?.status {
        case .queued, .preparing, .downloading: return MediaItemAction.pauseDownload.title
        case .paused, .failed: return MediaItemAction.resumeDownload.title
        case .completed: return MediaItemAction.removeDownload.title
        case nil: return MediaItemAction.startDownload.title
        }
    }

    private var downloadActionSymbol: String {
        switch currentDownloadRecord?.status {
        case .queued, .preparing, .downloading: return "pause.circle"
        case .paused, .failed: return "arrow.clockwise.circle"
        case .completed: return "trash"
        case nil: return "arrow.down.circle"
        }
    }

    private func performDownloadAction() async {
        switch currentDownloadRecord?.status {
        case .queued, .preparing, .downloading:
            await pauseDownload()
        case .paused, .failed:
            await resumeDownload()
        case .completed:
            showsDownloadConfirmation = true
        case nil:
            showsVersionSelection = true
        }
    }

    private var currentDownloadRecord: DownloadedMediaRecord? {
        if let record = appModel.downloads.cachedRecord(forSelectedVersionOf: downloadItem) {
            return record
        }
        guard let downloadRecord else { return nil }
        return appModel.downloads.records.first {
            $0.identityKey == downloadRecord.identityKey
        }
    }

    private func startDownload(quality: DownloadQuality? = nil) async {
        do {
            guard let provider = appModel.provider(for: downloadItem) else {
                downloadError = String(localized: "The selected server is no longer available.") // l10n:content — alert storage requires resolved text
                return
            }
            downloadRecord = try await appModel.downloads.enqueue(
                item: downloadItem,
                provider: provider,
                quality: quality
            )
        } catch {
            downloadError = error.localizedDescription
        }
    }

    private var downloadConfirmationMessage: Text {
        let source = selectedSource.map {
            Text(verbatim: $0.displayName)
        } ?? Text("Selected server")
        let size = selectedVersion?.sizeBytes.map {
            Text(verbatim: $0.formatted(.byteCount(style: .file)))
        } ?? Text("Size unavailable")
        let quality: Text
        if appModel.downloads.supportsReducedQuality(for: downloadItem) {
            quality = Text("Smaller copies require server conversion and may include fewer tracks.")
        } else {
            quality = Text("Only Original is available for this source.")
        }
        let subtitles = Text("Available external text subtitles are saved too.")
        return Text("\(source) • \(size)\n\(quality)\n\(subtitles)")
    }

    private func pauseDownload() async {
        guard let record = currentDownloadRecord else { return }
        await appModel.downloads.pause(record)
        downloadRecord = appModel.downloads.records.first { $0.identityKey == record.identityKey }
    }

    private func resumeDownload() async {
        guard let record = currentDownloadRecord else { return }
        await appModel.downloads.resume(record)
        downloadRecord = appModel.downloads.records.first { $0.identityKey == record.identityKey }
    }

    private func removeDownload() async {
        guard let record = currentDownloadRecord else { return }
        await appModel.downloads.remove(record)
        downloadRecord = nil
    }
}

struct PlozziOSRemoveDownloadButton<Label: View>: View {
    let onRemove: () -> Void
    @ViewBuilder let label: () -> Label
    @State private var showsConfirmation = false

    var body: some View {
        Button { showsConfirmation = true } label: { label() }
            .accessibilityLabel("Remove Download")
            .confirmationDialog(
                "Remove this download from this device?",
                isPresented: $showsConfirmation,
                titleVisibility: .visible
            ) {
                Button("Remove Download", role: .destructive, action: onRemove)
                Button("Cancel", role: .cancel) {}
            }
    }
}
#endif
