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
        let visibleTitles = ProcessInfo.processInfo.arguments.contains("--single-download-episode")
            ? Array(titles.prefix(1)) : titles
        return visibleTitles.enumerated().map { index, title in
            let versions: [MediaVersion] = (1...15).map { version in
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
                id: "episode-\(index)", title: title, kind: .episode,
                seasonNumber: index < 6 ? 1 : 2,
                episodeNumber: index < 6 ? index + 1 : index - 5,
                seriesID: "northbound", sourceAccountID: "fixture",
                versions: versions
            )
        }
    }
}
