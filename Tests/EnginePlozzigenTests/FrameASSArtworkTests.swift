#if PLOZZ_FRAME_ASS
import AVFoundation
import CoreModels
import FeaturePlayback
import XCTest
@testable import AetherEngine
@testable import EnginePlozzigen

final class FrameASSArtworkTests: XCTestCase {
    /// Exercise ordinary engine + track selection on supplied media without a
    /// server account, synthetic track IDs or a global software-route override.
    @MainActor
    func testPlaybackModelAdmitsAuthoredFramesOnSuppliedSDRMedia() async throws {
        guard let paths = ProcessInfo.processInfo.environment["PLOZZ_ASS_PLAYBACK_FILES"] else {
            throw XCTSkip("Opt in with a JSON array of accessible local SDR Matroska files.")
        }
        let files = try JSONDecoder().decode([String].self, from: Data(paths.utf8))
        XCTAssertFalse(files.isEmpty)
        for (index, path) in files.enumerated() {
            let url = URL(fileURLWithPath: path)
            let provider = LocalPlaybackFile(url: url)
            let engine = try PlozzigenVideoEngine()
            let model = PlayerViewModel(provider: provider, itemID: "clip",
                behavior: .init(subtitleMode: .all, preferredSubtitleLanguage: "en"), style: .default,
                engineFactory: .init(makePlozzigen: { engine }))
            let surface = engine.makeVideoOutputView()
            defer { withExtendedLifetime(surface) {} }
            await model.load()
            let deadline = ContinuousClock.now + .seconds(25)
            var ownedAt: Double?
            while ContinuousClock.now < deadline {
                if model.liveSubtitles.rendersPrimary,
                   model.videoEngine.updateFrameSubtitlePresentation(eligible: true, offset: 0) {
                    if ownedAt == nil { ownedAt = engine.currentTime }
                    if engine.currentTime > (ownedAt ?? 0) + 1 { break }
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            let advanced = ownedAt.map { engine.currentTime > $0 + 1 } ?? false
            let route = model.videoEngine.diagnosticRoute
            await model.stop()
            XCTAssertEqual(route, .software, "Input \(index): ordinary selection did not admit the source.")
            XCTAssertTrue(advanced, "Input \(index): no advancing, frame-owned presentation.")
        }
    }

    func testOverlayFallbackFollowsPresentedSampleNotDecodeOrderOrCurrentRegistration() {
        let gate = SoftwareArtworkGate()
        let epoch = gate.generation
        XCTAssertTrue(gate.submit(epoch, .clear, sourceTime: 105) {})
        XCTAssertTrue(gate.submit(epoch, .notReady, sourceTime: 107) {})
        XCTAssertTrue(gate.submit(epoch, .images([]), sourceTime: 106) {})
        gate.set(nil)
        XCTAssertFalse(gate.owns(104.99))
        XCTAssertTrue(gate.owns(106.99))
        XCTAssertFalse(gate.owns(107))
        XCTAssertFalse(gate.submit(epoch, .clear, sourceTime: 108) {})
        gate.invalidate()
        XCTAssertFalse(gate.owns(106))
    }

    func testColdResumeCertifiesTheClearInsteadOfInferringItFromTheLanding() throws {
        let store = SubtitlePacketStore()
        store.noteHarvestAnchor(.prefetch, at: 40)
        store.noteHarvestProgress(.prefetch, through: 60)
        XCTAssertEqual(store.frameASSInitialReadAnchor(at: 55), 0)
        XCTAssertNil(store.activeASSPackets(stream: 2, at: 55))
        store.noteHarvestAnchor(.prefetch, at: 0)
        for i in 1...60 { store.noteHarvestProgress(.prefetch, through: Double(i)) }
        XCTAssertEqual(store.frameASSInitialReadAnchor(at: 55), 55)
        XCTAssertTrue(try XCTUnwrap(store.activeASSPackets(stream: 2, at: 55)).isEmpty)
        XCTAssertEqual(store.frameASSInitialReadAnchor(at: 1_000), 1_000)
    }

    func testUncertifiedPacketsAreNotAnAuthoredClearAndSelectionRebuildsArtwork() throws {
        let art = FrameASSArtwork()
        let header = """
        [Script Info]
        ScriptType: v4.00+
        PlayResX: 320
        PlayResY: 180
        [V4+ Styles]
        Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
        Style: Default,Arial,24,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,0,0,7,0,0,0,1
        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        """
        func frame(_ packets: [SoftwareASSPacket]?, _ epoch: UInt64) -> SoftwareASSFrame {
            .init(generation: epoch, track: .init(id: Int(epoch), name: "test", codec: "ass", language: "en",
                  isDefault: true, assHeader: header), fonts: [], sourcePTS: CMTime(value: 2, timescale: 1),
                  subtitleSeconds: 2, canvas: CGSize(width: 320, height: 180), packets: packets)
        }
        let event = SoftwareASSPacket(start: 1, duration: 2, data: Data(
            #"0,0,Default,,0,0,0,,{\an7\pos(10,10)\p1}m 0 0 l 20 0 20 20 0 20"#.utf8))
        guard case .images(let images) = art.resolve(frame([event], 1)) else { return XCTFail("Missing artwork") }
        XCTAssertFalse(images.isEmpty)
        guard case .notReady = art.resolve(frame(nil, 1)) else { return XCTFail("Unknown is not clear") }
        guard case .clear = art.resolve(frame([], 2)) else { return XCTFail("Old track persisted") }
    }
}

private struct LocalPlaybackFile: MediaProvider {
    let url: URL
    let kind: ProviderKind = .jellyfin
    var session: UserSession {
        .init(server: .init(id: "local", name: "Local", baseURL: url, provider: kind),
              userID: "local", userName: "Local", deviceID: "local", accessToken: "")
    }
    func item(id: String) async throws -> MediaItem { .init(id: id, title: "Test", kind: .movie) }
    func playbackInfo(for itemID: String) async throws -> PlaybackRequest {
        .init(item: try await item(id: itemID), streamURL: url)
    }
    func libraries() async throws -> [MediaLibrary] { [] }
    func continueWatching(limit: Int) async throws -> [MediaItem] { [] }
    func latest(limit: Int) async throws -> [MediaItem] { [] }
    func children(of itemID: String) async throws -> [MediaItem] { [] }
    func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        .init(items: [], startIndex: 0, totalCount: 0)
    }
    func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {}
    func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
}
#endif
