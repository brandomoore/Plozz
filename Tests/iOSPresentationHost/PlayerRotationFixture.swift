import AVFoundation
import CoreModels
import CoreUI
import FeatureHomeCore
import Observation
import SwiftUI
import UIKit
@testable import AppShelliOS
@testable import FeaturePlayback

@MainActor
@Observable
final class RotationLoadProbe {
    var count = 0
    var interfaceOrientation = 0
    var playbackRate: Double?
    var maximumRate: Double?
    var videoFit = ""
    var brightness: Double?
    var systemVolume: Double?
    private var server: IPTVTestHTTPServer?
    private var streamingURL: URL?

    func playbackURL(file: URL, streaming: Bool) async throws -> URL {
        guard streaming else { return file }
        if let streamingURL { return streamingURL }
        let bytes = try Data(contentsOf: file)
        let server = try IPTVTestHTTPServer { request in
            var headers = ["Content-Type": "video/quicktime", "Accept-Ranges": "bytes"]
            guard let range = request.components(separatedBy: "\r\n")
                .first(where: { $0.lowercased().hasPrefix("range: bytes=") }) else {
                return .init(data: bytes, headers: headers)
            }
            let bounds = range.split(separator: "=").last?.split(separator: "-", omittingEmptySubsequences: false)
            guard let bounds, bounds.count == 2, let start = Int(bounds[0]),
                  start >= 0, start < bytes.count else {
                return .init(status: 416, headers: ["Content-Range": "bytes */\(bytes.count)"])
            }
            let end = min(Int(bounds[1]) ?? (bytes.count - 1), bytes.count - 1)
            guard end >= start else {
                return .init(status: 416, headers: ["Content-Range": "bytes */\(bytes.count)"])
            }
            headers["Content-Range"] = "bytes \(start)-\(end)/\(bytes.count)"
            return .init(data: bytes.subdata(in: start..<(end + 1)), status: 206, headers: headers)
        }
        self.server = server
        let url = try await server.start().appendingPathComponent("rotation-fixture.mov")
        streamingURL = url
        return url
    }
}

struct PlayerRotationFixture: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var model: PlozziOSAppModel
    @State private var hero = HeroTrailerController()
    @State private var probe = RotationLoadProbe()
    @State private var request: PlozziOSPlaybackRequest?

    init() {
        SyncSetupFeatureFlag().isEnabled = false
        let model = PlozziOSAppModel()
        model.settings.playback.settings = .default
        model.settings.playback.settings.useCommunityMarkers = false
        model.settings.playback.settings.syncWatchAcrossServers = false
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--force-transcoding") {
            model.settings.playback.settings.streaming.forceTranscoding = true
        }
        if arguments.contains("--gesture-player-fixture") {
            model.settings.playback.settings.skipForwardInterval = .five
            model.settings.playback.settings.skipBackwardInterval = .thirty
        }
        if arguments.contains("--no-level-gestures") {
            model.settings.playback.settings.volumeBrightnessGestures = false
        }
        if arguments.contains("--keyboard-up-next-fixture") {
            model.settings.playback.settings.autoPlayNextEpisode = false
            model.settings.playback.settings.showUpNextCard = true
            model.settings.playback.settings.upNextLeadSeconds = 90
        }
        if arguments.contains("--auto") { model.settings.playback.settings.orientation = .auto }
        if arguments.contains("--portrait") { model.settings.playback.settings.orientation = .portrait }
        _model = State(initialValue: model)
    }

    var body: some View {
        Group {
            if ProcessInfo.processInfo.arguments.contains("--nested-player-presentation") {
                TabView {
                    NavigationStack { playerSurface.navigationTitle("Fixture") }
                        .tabItem { Label("Home", systemImage: "house") }
                }
            } else {
                playerSurface
            }
        }
        .environment(model)
        .environment(hero)
        .environment(\.plozzMetrics, .touch(density: .standard))
        .environment(\.locale, Locale(identifier: "en_US"))
        .dynamicTypeSize(
            ProcessInfo.processInfo.arguments.contains("--large-player-text") ? .accessibility3 : dynamicTypeSize
        )
    }

    private var playerSurface: some View {
        openButton.plozziOSPlayerCover(item: $request, orientation: model.settings.playback.settings.orientation) {
            request, orientation in
            player(request: request, orientation: orientation)
        }
    }

    private var openButton: some View {
        VStack {
            Button("Open rotation player") {
                request = .init(
                    item: RotationProvider.media,
                    startPosition: ProcessInfo.processInfo.arguments.contains("--keyboard-up-next-fixture")
                        ? 135 : (ProcessInfo.processInfo.arguments.contains("--gesture-player-fixture") ? 60 : 0),
                    versionPreferences: model.versionPreferences
                )
            }
            Text(model.settings.playback.settings.orientation.rawValue)
                .accessibilityIdentifier("saved-orientation")
        }
    }

    private func player(
        request: PlozziOSPlaybackRequest, orientation: PlozziOSPlayerOrientation
    ) -> some View {
        PlozziOSPlayerView(
            request: request, provider: RotationProvider(probe: probe), orientation: orientation
        )
        .overlay {
            if ProcessInfo.processInfo.arguments.contains("--gesture-player-fixture") {
                Color.clear
                    .frame(width: 280, height: 160)
                    .accessibilityElement()
                    .accessibilityLabel("Video pinch area")
                    .accessibilityIdentifier("gesture-pinch-area")
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .topTrailing) {
            VStack {
                Text("Loads \(probe.count)").accessibilityIdentifier("rotation-load-count")
                Text("\(probe.interfaceOrientation)").accessibilityIdentifier("rotation-interface-orientation")
                if ProcessInfo.processInfo.arguments.contains("--gesture-player-fixture") {
                    Text(verbatim: probe.playbackRate.map { String($0) } ?? "unavailable")
                        .accessibilityIdentifier("gesture-rate")
                    Text(verbatim: probe.maximumRate.map { String($0) } ?? "unavailable")
                        .accessibilityIdentifier("gesture-maximum-rate")
                    Text(verbatim: probe.videoFit).accessibilityIdentifier("gesture-video-fit")
                    Text(verbatim: probe.brightness.map { String($0) } ?? "unavailable")
                        .accessibilityIdentifier("gesture-screen-brightness")
                    Text(verbatim: probe.systemVolume.map { String($0) } ?? "unavailable")
                        .accessibilityIdentifier("gesture-system-volume")
                }
            }
            .foregroundStyle(.white)
            .font(.caption2)
            .dynamicTypeSize(.xSmall)
            .allowsHitTesting(false)
        }
        .task {
            while !Task.isCancelled {
                if let window = orientation.host?.view.window {
                    markVideo(in: window)
                    probe.brightness = window.windowScene.map { Double($0.screen.brightness) }
                    probe.systemVolume = Double(AVAudioSession.sharedInstance().outputVolume)
                    let value = window.windowScene?.effectiveGeometry.interfaceOrientation.rawValue ?? 0
                    if probe.interfaceOrientation != value {
                        probe.interfaceOrientation = value
                    }
                }
                do { try await Task.sleep(for: .milliseconds(100)) }
                catch { return }
            }
        }
    }

    @MainActor
    private func markVideo(in view: UIView) {
        if let presentation = view as? VideoPresentationView {
            view.isAccessibilityElement = true
            view.accessibilityIdentifier = "rotation-video-surface"
            if ProcessInfo.processInfo.arguments.contains("--gesture-player-fixture") {
                let rate = playbackRate(in: presentation.layer)
                probe.playbackRate = rate
                if let rate { probe.maximumRate = max(probe.maximumRate ?? rate, rate) }
                if let rect = presentation.videoRect {
                    let safe = presentation.fitBounds ?? presentation.bounds
                    probe.videoFit = safe.insetBy(dx: -1, dy: -1).contains(rect) ? "safe" : "cropped"
                }
            }
        }
        for child in view.subviews { markVideo(in: child) }
    }

    @MainActor
    private func playbackRate(in layer: CALayer) -> Double? {
        if let player = (layer as? AVPlayerLayer)?.player { return Double(player.rate) }
        if let display = layer as? AVSampleBufferDisplayLayer {
            // Plozzigen's software route renders against its synchronizer, not an AVPlayer.
            // The renderer's own rate can remain 1 while its source timebase runs at 2.
            let rate = CMTimebaseGetEffectiveRate(display.sampleBufferRenderer.timebase)
            return rate.isFinite ? rate : nil
        }
        for child in layer.sublayers ?? [] {
            if let rate = playbackRate(in: child) { return rate }
        }
        return nil
    }
}

private struct RotationProvider: MediaProvider, StreamingQualityProviding {
    private static var failsPlayback: Bool {
        ProcessInfo.processInfo.arguments.contains("--failed-player-fixture")
            || ProcessInfo.processInfo.arguments.contains("--failed-conversion-fixture")
    }
    private static var embyStreaming: Bool {
        ProcessInfo.processInfo.arguments.contains("--emby-streaming-fixture")
    }
    private static var keyboardUpNext: Bool {
        ProcessInfo.processInfo.arguments.contains("--keyboard-up-next-fixture")
    }
    static var media: MediaItem {
        if keyboardUpNext { return episode(index: 1) }
        return MediaItem(
            id: "rotation", title: "Rotation fixture", kind: embyStreaming || failsPlayback ? .movie : .video, runtime: 180,
            allowsTitleBasedMetadataMatching: false
        )
    }
    private static func episode(index: Int) -> MediaItem {
        let seriesTitle = ProcessInfo.processInfo.arguments.contains("--long-up-next-title")
            ? "The exceptionally long series title for thumbnail layout" : "Keyboard fixture"
        return MediaItem(
            id: index == 1 ? "rotation" : "rotation-next",
            title: "Keyboard episode \(index)", kind: .episode, parentTitle: seriesTitle,
            seasonNumber: 1, episodeNumber: index,
            seriesID: "keyboard-series", seasonID: "keyboard-season", runtime: 180,
            allowsTitleBasedMetadataMatching: false
        )
    }
    let probe: RotationLoadProbe
    var kind: ProviderKind { Self.failsPlayback ? .silo : Self.embyStreaming ? .emby : .jellyfin }
    var session: UserSession {
        UserSession(
            server: MediaServer(
                id: "rotation", name: "Local fixture", baseURL: URL(string: "https://example.invalid")!,
                provider: kind
            ),
            userID: "fixture", userName: "Fixture", deviceID: "fixture", accessToken: ""
        )
    }
    func libraries() async throws -> [MediaLibrary] { [] }
    func continueWatching(limit: Int) async throws -> [MediaItem] { [] }
    func latest(limit: Int) async throws -> [MediaItem] { [] }
    func item(id: String) async throws -> MediaItem {
        Self.keyboardUpNext && id == "rotation-next" ? Self.episode(index: 2) : Self.media
    }
    func children(of itemID: String) async throws -> [MediaItem] {
        Self.keyboardUpNext && itemID == "keyboard-season"
            ? [Self.episode(index: 1), Self.episode(index: 2)] : []
    }
    func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        MediaPage(items: [], startIndex: 0, totalCount: 0)
    }
    func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
    func playbackInfo(for itemID: String) async throws -> PlaybackRequest {
        await MainActor.run { probe.count += 1 }
        if ProcessInfo.processInfo.arguments.contains("--failed-conversion-fixture") {
            throw StreamingQualityError.unavailable
        }
        if Self.failsPlayback {
            throw StreamingQualityError.serverRefusal("Synthetic playback preparation failure.")
        }
        let file = try await Self.movie()
        let url = try await probe.playbackURL(file: file, streaming: Self.embyStreaming)
        return PlaybackRequest(
            item: Self.keyboardUpNext && itemID == "rotation-next" ? Self.episode(index: 2) : Self.media,
            streamURL: url
        )
    }
    func playbackInfo(
        for itemID: String, mediaSourceID: String?, forceTranscode: Bool,
        streaming: StreamingPlaybackOptions
    ) async throws -> PlaybackRequest {
        try await playbackInfo(for: itemID)
    }
    func releaseStreamingSession(_ request: PlaybackRequest) async {}
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {}
    func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }

    private static func movie() async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rotation-fixture.mov")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        guard let source = Bundle.main.url(forResource: "four-three", withExtension: "mp4") else {
            throw AppError.notFound
        }
        let asset = AVURLAsset(url: source)
        let duration = try await asset.load(.duration)
        let composition = AVMutableComposition()
        for index in 0..<90 {
            try await composition.insertTimeRange(
                CMTimeRange(start: .zero, duration: duration), of: asset,
                at: CMTimeMultiply(duration, multiplier: Int32(index))
            )
        }
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw AppError.notFound
        }
        try await exporter.export(to: url, as: .mov)
        return url
    }
}
