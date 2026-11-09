import CoreModels
import CoreUI
import SwiftUI
import UIKit
@testable import FeaturePlayback

struct EpisodeRowRemoteFixture: View {
    @State private var player: PlayerViewModel
    @State private var focusTrace: [Int] = []
    @State private var peakCellCount = 0
    @State private var drawerVisible = true
    @State private var closeRequest = 0
    @State private var engine = EpisodeInputFixtureEngine()
    @State private var subtitles = LiveSubtitleModel()
    @State private var artworkCapture = ""
    @State private var captureRun = UUID().uuidString
    @State private var playbackSurfaceFocused = false
    @State private var nativeFocusTrace: [String] = []
    @FocusState private var focus: PlayerControls.FocusSlot?

    init() {
        let long = ProcessInfo.processInfo.arguments.contains("--long-season")
        let single = long || ProcessInfo.processInfo.arguments.contains("--single-season")
        let provider = EpisodeRemoteProvider(singleSeason: single, episodeCount: long ? 1000 : 24)
        let episode = EpisodeRemoteProvider.episode(season: single ? 1 : 2, number: long ? 500 : (single ? 1 : 12))
        _player = State(initialValue: PlayerViewModel(
            provider: provider, itemID: episode.id, episodeItem: episode
        ))
    }

    var body: some View {
        Group {
            if ProcessInfo.processInfo.arguments.contains("--production-player-input") {
                productionPlayer
            } else {
                isolatedRow
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
        .environment(\.plozzCardFocusStyle, .system)
        .environment(\.locale, Locale(identifier:
            ProcessInfo.processInfo.arguments.contains("--refresh-on-focus") && focusTrace.count.isMultiple(of: 2)
                ? "en_GB" : "en_US"
        ))
        .environment(\.layoutDirection, ProcessInfo.processInfo.arguments.contains("--rtl") ? .rightToLeft : .leftToRight)
        .onAppear { focus = .button(.episodes) }
        .onReceive(NotificationCenter.default.publisher(for: UIFocusSystem.didUpdateNotification)) { notification in
            guard let context = notification.userInfo?[UIFocusSystem.focusUpdateContextUserInfoKey]
                as? UIFocusUpdateContext else { return }
            playbackSurfaceFocused = context.nextFocusedView is PlayerInputView
            if ProcessInfo.processInfo.arguments.contains("--song") {
                nativeFocusTrace.append(context.nextFocusedView.map {
                    "\(type(of: $0)):\($0.accessibilityLabel ?? "-")"
                } ?? "none")
                nativeFocusTrace = Array(nativeFocusTrace.suffix(8))
            }
            guard let cell = context.nextFocusedView as? PlayerEpisodeNativeCell,
                  let title = cell.accessibilityLabel, title.hasPrefix("Episode "),
                  let episode = Int(title.dropFirst("Episode ".count)) else { return }
            if focusTrace.last != episode { focusTrace.append(episode) }
            if ProcessInfo.processInfo.arguments.contains("--interrupt-focus"), closeRequest < 3 {
                closeRequest += 1
            }
        }
        .onPlayPauseCommand { drawerVisible.toggle() }
        .task(id: closeRequest) {
            guard closeRequest > 0 else { return }
            do {
                try await Task.sleep(for: .milliseconds(40))
                drawerVisible = false
                focus = .button(.episodes)
                try await Task.sleep(for: .milliseconds(180))
                drawerVisible = true
            } catch is CancellationError {
                return
            } catch {
                preconditionFailure("Fixture drawer transition failed: \(error)")
            }
        }
        .task {
            await prepareArtwork()
            if ProcessInfo.processInfo.arguments.contains("--production-player-input") {
                await player.episodeBrowser?.loadIfNeeded()
            }
            if ProcessInfo.processInfo.arguments.contains("--song") {
                player.controls.infoCard.headline = "Episode fixture"
                player.controls.infoCard.hasPreviousEpisode = false
                player.controls.infoCard.hasNextEpisode = true
                player.controls.songRecognition.isAvailable = true
                player.controls.songRecognition.state = .found(SongMatch(
                    title: "Test song", artist: "Test artist", artworkURL: nil,
                    appleMusicURL: URL(string: "https://music.apple.com/album/example?i=123")
                ))
            }
            while !Task.isCancelled {
                let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
                peakCellCount = max(peakCellCount, windows.map(countCells).max() ?? 0)
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            }
        }
        .task(id: player.controls.controlBarActivity) {
            guard ProcessInfo.processInfo.arguments.contains("--capture-artwork") else { return }
            let activity = player.controls.controlBarActivity
            do {
                try await Task.sleep(for: .milliseconds(700))
                try captureArtwork(activity: activity)
            } catch is CancellationError {
                return
            } catch {
                artworkCapture = "\(activity):error:\(error.localizedDescription)"
            }
        }
    }

    private var isolatedRow: some View {
        VStack(spacing: 40) {
            Button("Browse episodes") {}
                .focused($focus, equals: .button(.episodes))
                .frame(maxWidth: .infinity)
                .focusSection()
            PlayerSequencePanel(player: player, source: .episodes, focus: $focus)
                .frame(width: 1400)
                .disabled(!drawerVisible)
                .offset(y: drawerVisible ? 0 : 300)
                .opacity(drawerVisible ? 1 : 0)
                .animation(.easeInOut(duration: 0.25), value: drawerVisible)
            Text(verbatim: drawerVisible ? "Open" : "Closed")
                .accessibilityIdentifier("episode-row-drawer-state")
            Text(verbatim: player.episodeBrowser?.hasLoaded == true ? "Ready" : "Loading")
                .accessibilityIdentifier("episode-row-ready")
            Text(verbatim: String(player.episodeBrowser?.episodes.count ?? 0))
                .accessibilityIdentifier("episode-row-count")
            Text(verbatim: focusTrace.map(String.init).joined(separator: ","))
                .font(.caption2)
                .lineLimit(1)
                .frame(width: 1000, height: 25)
                .accessibilityIdentifier("episode-row-trace")
            Text(verbatim: String(peakCellCount))
                .accessibilityIdentifier("episode-row-peak-cells")
        }
    }

    private var productionPlayer: some View {
        CustomPlayerContainer(
            engine: engine, model: player.controls, subtitleModel: subtitles,
            actions: PlayerActions(), scrubPreview: nil, authenticatedHTTPResolver: nil,
            themePalette: ThemePaletteBox(
                makeControls: { model, actions, exit in
                    AnyView(PlayerControls(
                        model: model, player: player, palette: .dark,
                        actions: actions, onExitToSurface: exit
                    ))
                },
                makeSkipButton: { _, _, _, _ in AnyView(EmptyView()) },
                makeUpNextCard: { _, _, _, _ in AnyView(EmptyView()) }
            )
        )
        .overlay(alignment: .topLeading) {
            VStack {
                Text(verbatim: player.controls.controlBarVisible ? "Open" : "Closed")
                    .accessibilityIdentifier("episode-row-drawer-state")
                Text(verbatim: player.episodeBrowser?.hasLoaded == true ? "Ready" : "Loading")
                    .accessibilityIdentifier("episode-row-ready")
                Text(verbatim: String(player.controls.controlBarActivity))
                    .accessibilityIdentifier("episode-row-activity")
                Text(verbatim: artworkCapture)
                    .accessibilityIdentifier("episode-row-artwork-capture")
                Text(verbatim: playbackSurfaceFocused ? "Playback" : "Controls")
                    .accessibilityIdentifier("episode-row-focus-owner")
                if ProcessInfo.processInfo.arguments.contains("--song") {
                    Text(verbatim: nativeFocusTrace.joined(separator: " > "))
                        .font(.caption2)
                        .accessibilityIdentifier("song-native-focus-trace")
                }
            }
            .allowsHitTesting(false)
        }
    }

    private func countCells(in view: UIView) -> Int {
        (view is PlayerEpisodeNativeCell ? 1 : 0) + view.subviews.map(countCells).reduce(0, +)
    }

    @MainActor
    private func captureArtwork(activity: Int) throws {
        guard player.controls.controlBarVisible else {
            artworkCapture = "\(activity):closed"
            return
        }
        guard let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows).first(where: \.isKeyWindow) else {
            preconditionFailure("Episode capture requires its own visible window")
        }
        func cells(in view: UIView) -> [PlayerEpisodeNativeCell] {
            (view as? PlayerEpisodeNativeCell).map { [$0] } ?? view.subviews.flatMap { cells(in: $0) }
        }
        let visible = cells(in: window).filter {
            guard let collection = $0.superview as? UICollectionView else { return false }
            return $0.isFocused || collection.bounds.insetBy(dx: -1, dy: -1).contains($0.frame)
        }
        guard visible.count >= 2 else {
            artworkCapture = "\(activity):no-row"
            return
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            precondition(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
        guard let source = image.cgImage, let png = image.pngData() else {
            preconditionFailure("Episode capture must produce a readable image")
        }
        var clean = true
        var measurements: [[String: Any]] = []
        for cell in visible {
            let frame = cell.convert(cell.bounds, to: window)
            guard let crop = source.cropping(to: CGRect(
                x: frame.midX, y: frame.minY - 4, width: 1, height: 40
            ).integral) else { preconditionFailure("Episode artwork must be inside the capture") }
            var pixels = [UInt8](repeating: 0, count: crop.width * crop.height * 4)
            let firstBlue = pixels.withUnsafeMutableBytes { bytes -> Int? in
                guard let context = CGContext(
                    data: bytes.baseAddress, width: crop.width, height: crop.height,
                    bitsPerComponent: 8, bytesPerRow: crop.width * 4,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                ) else { preconditionFailure("Episode artwork must be drawable") }
                context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
                return (0..<crop.height).first {
                    let offset = $0 * crop.width * 4
                    return bytes[offset + 2] > 150 && Double(bytes[offset + 2]) > Double(bytes[offset]) * 1.5
                }
            }
            let inset = firstBlue.map { $0 - 4 }
            let matches = inset.map { cell.isFocused ? $0 < 4 : abs($0 - 12) <= 2 } ?? false
            clean = clean && matches
            measurements.append([
                "title": cell.accessibilityLabel ?? "", "focused": cell.isFocused,
                "highlighted": cell.isHighlighted, "selected": cell.isSelected,
                "configurationFocused": cell.configurationState.isFocused,
                "paintedInset": inset ?? -100, "matches": matches
            ])
        }
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("episode-focus-\(captureRun)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try png.write(to: directory.appendingPathComponent("\(activity).png"))
        try JSONSerialization.data(withJSONObject: measurements, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("\(activity).json"))
        artworkCapture = "\(activity):\(clean ? "clean" : "stale")"
    }

    @MainActor
    private func prepareArtwork() async {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 320, height: 180)).image {
            UIColor.systemBlue.setFill()
            $0.fill(CGRect(x: 0, y: 0, width: 320, height: 180))
            UIColor.systemOrange.setFill()
            $0.fill(CGRect(x: 25, y: 20, width: 75, height: 140))
        }
        let url = ArtworkImageVariant.landscapeCard.requestURL(for: EpisodeRemoteProvider.artworkURL)
        guard let cache = ArtworkSession.shared.configuration.urlCache, let data = image.pngData(),
              let response = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "image/png", "Cache-Control": "max-age=3600"]
              ) else { preconditionFailure("Episode fixture requires its isolated artwork cache") }
        cache.storeCachedResponse(CachedURLResponse(response: response, data: data), for: URLRequest(url: url))
        guard await ArtworkImageCache.shared.image(
            for: EpisodeRemoteProvider.artworkURL, variant: .landscapeCard
        ) != nil else { preconditionFailure("Episode fixture artwork must decode") }
    }
}

@MainActor
private final class EpisodeInputFixtureEngine: VideoEngine {
    var status: VideoEngineStatus = .ready
    var isPaused = false
    private var position: TimeInterval = 100
    private var startedAt = ProcessInfo.processInfo.systemUptime
    var currentTime: TimeInterval { position + (isPaused ? 0 : ProcessInfo.processInfo.systemUptime - startedAt) }
    var duration: TimeInterval = 7200
    var furthestObservedPosition: TimeInterval { currentTime }
    var preventsDisplaySleep: Bool { !isPaused }
    var audioTracks: [MediaTrack] = []
    var subtitleTracks: [MediaTrack] = []
    var onProgress: (@MainActor () -> Void)?
    var onFailure: (@MainActor (AppError) -> Void)?
    var onEnded: (@MainActor () -> Void)?
    var onTracksChanged: (@MainActor () -> Void)?
    var onSubtitleCues: (@MainActor ([SubtitleCue]) -> Void)?
    var onSecondarySubtitleCues: (@MainActor ([SubtitleCue]) -> Void)?
    var onProbedSourceFactsChanged: (@MainActor (EngineProbedSourceFacts) -> Void)?

    func load(request: PlaybackRequest, startPosition: TimeInterval) async {}
    func play() { startedAt = ProcessInfo.processInfo.systemUptime; isPaused = false }
    func pause() { position = currentTime; isPaused = true }
    func seek(to seconds: TimeInterval) async { position = seconds; startedAt = ProcessInfo.processInfo.systemUptime }
    func stop() { status = .idle }
    func selectAudioTrack(_ track: MediaTrack?) {}
    func selectSubtitleTrack(_ track: MediaTrack?) {}
    func makeVideoOutputView() -> UIView {
        let view = UIView()
        if ProcessInfo.processInfo.arguments.contains("--song") {
            view.backgroundColor = UIColor(red: 0.6, green: 0.65, blue: 0.7, alpha: 1)
        }
        return view
    }
}

private actor EpisodeRemoteProvider: MediaProvider {
    nonisolated static let artworkURL = URL(string: "https://episode-row-fixture.example.test/artwork.png")!
    nonisolated let kind = ProviderKind.jellyfin
    nonisolated let session = UserSession(
        server: MediaServer(id: "fixture", name: "Fixture", baseURL: URL(string: "https://fixture.test")!, provider: .jellyfin),
        userID: "viewer", userName: "Viewer", deviceID: "fixture", accessToken: "fixture"
    )
    let singleSeason: Bool
    let episodeCount: Int
    init(singleSeason: Bool, episodeCount: Int) {
        self.singleSeason = singleSeason
        self.episodeCount = episodeCount
    }

    nonisolated static func episode(season: Int, number: Int) -> MediaItem {
        MediaItem(
            id: "\(season)-\(number)", title: "Episode \((season - 1) * 24 + number)", kind: .episode,
            seasonNumber: season, episodeNumber: number, seriesID: "series", seasonID: "season-\(season)",
            posterURL: artworkURL, backdropURL: artworkURL
        )
    }

    func children(of itemID: String) async throws -> [MediaItem] {
        try await Task.sleep(for: .milliseconds(180))
        if itemID == "series" {
            return (1...(singleSeason ? 1 : 3)).map { (number: Int) in
                MediaItem(id: "season-\(number)", title: "Season \(number)", kind: .season, seasonNumber: number)
            }
        }
        guard let season = Int(itemID.replacingOccurrences(of: "season-", with: "")) else {
            throw AppError.notFound
        }
        return (1...episodeCount).map { Self.episode(season: season, number: $0) }
    }
    func libraries() async throws -> [MediaLibrary] { [] }
    func continueWatching(limit: Int) async throws -> [MediaItem] { [] }
    func latest(limit: Int) async throws -> [MediaItem] { [] }
    func item(id: String) async throws -> MediaItem {
        let parts = id.split(separator: "-")
        guard parts.count == 2, let season = Int(parts[0]), let number = Int(parts[1]) else {
            throw AppError.notFound
        }
        return Self.episode(season: season, number: number)
    }
    func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        MediaPage(items: [], startIndex: page.startIndex, totalCount: 0)
    }
    func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
    func playbackInfo(for itemID: String) async throws -> PlaybackRequest { throw AppError.notFound }
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {}
    nonisolated func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
}
