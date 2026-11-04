import CoreModels
import FeatureHomeCore
import MediaDownloads
import SwiftUI
@testable import AppShelliOS

struct DownloadSelectionFixture: View {
    @State private var showsSheet = false
    @State private var selection = EpisodeDownloadSelection(
        items: Self.items, preferences: Preferences(), capabilities: .default
    )
    @State private var quality: DownloadQuality = .original
    @State private var downloadedCount = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Button("Download Season") { showsSheet = true }
                Text("Queued: \(downloadedCount)")
            }
            .navigationTitle("Northbound")
        }
        .sheet(isPresented: $showsSheet) {
            PlozziOSDownloadSelectionContent(
                title: Text("Northbound"), selection: $selection, quality: $quality,
                supportsReducedQuality: true,
                availableSpace: "72 GB",
                alwaysAsk: !ProcessInfo.processInfo.arguments.contains("--download-ask-off"),
                isBulk: !ProcessInfo.processInfo.arguments.contains("--single-download-episode")
                    && !ProcessInfo.processInfo.arguments.contains("--download-movie"),
                onCancel: { showsSheet = false },
                onDownload: {
                    downloadedCount = selection.selectedOptions.count
                    showsSheet = false
                }
            )
        }
    }

    private struct Preferences: VersionPreferenceStoring {
        func preferredVersionID(forTitle titleID: String) -> String? { nil }
        func setPreferredVersionID(_ versionID: String?, forTitle titleID: String) {}
    }

    private static let titles = [
        "First Light", "The Crossing", "A Long Way Home", "The Last Train",
        "Through the Pines", "Northern Lights", "Open Water", "The Lookout",
        "Before the Storm", "Home Again"
    ]

    private static var items: [MediaItem] {
        let isMovie = ProcessInfo.processInfo.arguments.contains("--download-movie")
        let visibleTitles = ProcessInfo.processInfo.arguments.contains("--single-download-episode") || isMovie
            ? Array(titles.prefix(1)) : titles
        return visibleTitles.enumerated().map { index, title in
            let versionCount = ProcessInfo.processInfo.arguments.contains("--one-download-version") ? 1 : 15
            let versions: [MediaVersion] = (1...versionCount).map { version in
                let resolution = version == 1 ? "1080p" : "720p"
                let size: Int64 = version == 1 ? 420_000_000 : Int64(200_000_000 + version * 1_000_000)
                return MediaVersion(
                    id: "file-\(version)",
                    fileName: "Northbound.S01E\(index + 1).\(resolution).\(version).mkv",
                    height: version == 1 ? 1080 : 720, sizeBytes: size,
                    videoCodec: "h264", videoRange: "SDR",
                    audioCodec: "aac", audioChannels: 2, container: "mkv"
                )
            }
            return MediaItem(
                id: "episode-\(index)", title: title, kind: isMovie ? .movie : .episode,
                seasonNumber: index < 6 ? 1 : 2,
                episodeNumber: index < 6 ? index + 1 : index - 5,
                seriesID: "northbound", sourceAccountID: "fixture",
                versions: versions
            )
        }
    }
}
