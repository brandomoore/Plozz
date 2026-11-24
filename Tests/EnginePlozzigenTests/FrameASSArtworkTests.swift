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

    func testLineArtDeliveryMapsAuthoredRegionsOntoTheUpscaledPicture() throws {
        var plan = UpscalePlan(sourceWidth: 1920, sourceHeight: 1080, mlScale: nil,
            mlOutputWidth: 3840, mlOutputHeight: 2160, targetWidth: 3840, targetHeight: 2160,
            displayWidth: 3840, displayHeight: 2160, scaler: .lineArt)
        XCTAssertTrue(plan.supportsFrameASS)
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 20, height: 10, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = SubtitleImage(cgImage: try XCTUnwrap(ctx.makeImage()),
            position: CGRect(x: 0.25, y: 0.125, width: 20.0 / 1920, height: 10.0 / 1080),
            canvasSize: CGSize(width: 1920, height: 1080))
        let layer = try XCTUnwrap(SubtitleFrameCompositor.regionOverlay([image], width: 3840, height: 2160, options: [:]))
        XCTAssertEqual(layer.extent, CGRect(x: 960, y: 1870, width: 40, height: 20))
        plan.scaler = .automatic
        XCTAssertFalse(plan.supportsFrameASS)
        plan.scaler = .lineArt
        plan.targetHeight = 1600
        XCTAssertFalse(plan.supportsFrameASS)
    }

    func testIndexReadsCannotCompeteWithSingleSlotPlaybackOrExceedTheOriginLimit() throws {
        let origin = try XCTUnwrap(URL(string: "https://subtitle-index.invalid/video"))
        let budget = OriginRequestBudget()
        budget.setHostLimit(1, for: origin)
        XCTAssertNil(MatroskaASSIndex.reserveRange(for: origin, budget: budget))
        let playback = try XCTUnwrap(budget.tryAcquire(for: origin, label: "playback"))
        defer { budget.release(playback) }
        XCTAssertNil(MatroskaASSIndex.reserveRange(for: origin, budget: budget))
        budget.setHostLimit(2, for: origin)
        let index = try XCTUnwrap(MatroskaASSIndex.reserveRange(for: origin, budget: budget))
        defer { budget.release(index) }
        XCTAssertNil(budget.tryAcquire(for: origin, label: "over limit"))
    }

    func testFarLandingRequiresEveryIndexedOverlapAndTrackIdentity() throws {
        typealias Cue = MatroskaASSIndex.Cue
        let cues = [Cue(interval:.init(start:10, duration:1_060_750), location:100),
                    Cue(interval:.init(start:1_060_740,duration:3010), location:200),
                    Cue(interval:.init(start:1_060_740,duration:3010), location:300)]
        XCTAssertNil(MatroskaASSIndex(cues, expected:4))
        XCTAssertNil(MatroskaASSIndex([cues[0], cues[1], cues[1]], expected:3))
        let index = try XCTUnwrap(MatroskaASSIndex(cues,expected:3))
        let store = SubtitlePacketStore()
        store.noteHarvestAnchor(.prefetch,at:1_017)
        store.noteHarvestProgress(.prefetch,through:1_100)
        store.installFrameASSIndex(index,stream:3)
        store.append(streamIndex:3,ptsSeconds:1_060.740,durationSeconds:3.010,payload:Data([1]))
        XCTAssertNil(store.activeASSPackets(stream:3,at:1_060.768)) // second layer absent
        store.append(streamIndex:3,ptsSeconds:1_060.740,durationSeconds:3.010,payload:Data([2]))
        XCTAssertNil(store.activeASSPackets(stream:3,at:1_060.750)) // overlap from before the landing
        XCTAssertEqual(store.activeASSPackets(stream:3,at:1_060.768)?.count,2)
        XCTAssertTrue(try XCTUnwrap(store.activeASSPackets(stream:3,at:1_063.750)).isEmpty)
        XCTAssertNil(store.activeASSPackets(stream:4,at:1_063.750))
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
        // A server can offer its own rendition alongside the same embedded track.
        let sidecar = MediaTrack(id: 3, kind: .subtitle, displayTitle: "English", language: "en",
                                 codec: "webvtt", deliverySource: .localFile(url.appendingPathExtension("vtt")),
                                 isExternal: true)
        return .init(item: try await item(id: itemID), streamURL: url, subtitleTracks: [sidecar])
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
