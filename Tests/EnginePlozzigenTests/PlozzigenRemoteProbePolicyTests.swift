import AetherEngine
import CoreModels
import Foundation
import XCTest
@testable import EnginePlozzigen

final class PlozzigenRemoteProbePolicyTests: XCTestCase {
    func testOnlyKnownRemoteAV1MatroskaGetsTheBoundedScan() {
        var options = LoadOptions()
        options.preserveASSMarkup = true
        XCTAssertTrue(PlozzigenRemoteProbePolicy.apply(
            to: &options, request: request(), url: URL(string: "https://fixture.test/video")!
        ))
        XCTAssertEqual(options.probesize, 2 * 1024 * 1024)
        XCTAssertEqual(options.maxAnalyzeDuration, 2_000_000)
        XCTAssertTrue(options.preserveASSMarkup)

        var cases: [(PlaybackRequest, URL)] = [(request(), URL(fileURLWithPath: "/fixture.mkv"))]
        var changed = request()
        changed.sourceMetadata = nil
        cases.append((changed, remoteURL))
        changed = request()
        changed.sourceMetadata?.video?.codec = "hevc"
        cases.append((changed, remoteURL))
        changed = request()
        changed.sourceMetadata?.container = "mp4"
        cases.append((changed, remoteURL))
        changed = request()
        changed.isTranscoding = true
        cases.append((changed, remoteURL))
        changed = request()
        changed.isManifestStream = true
        cases.append((changed, remoteURL))
        for (request, url) in cases {
            var untouched = LoadOptions()
            XCTAssertFalse(PlozzigenRemoteProbePolicy.apply(to: &untouched, request: request, url: url))
            XCTAssertNil(untouched.probesize)
            XCTAssertNil(untouched.maxAnalyzeDuration)
        }
    }

    func testCompletenessRequiresVideoAudioAndEveryDeclaredEmbeddedSubtitle() {
        XCTAssertTrue(PlozzigenRemoteProbePolicy.isComplete(probe(), for: request()))
        XCTAssertFalse(PlozzigenRemoteProbePolicy.isComplete(nil, for: request()))
        XCTAssertFalse(PlozzigenRemoteProbePolicy.isComplete(probe(width: 0), for: request()))
        XCTAssertFalse(PlozzigenRemoteProbePolicy.isComplete(probe(width: 1280), for: request()))
        XCTAssertFalse(PlozzigenRemoteProbePolicy.isComplete(probe(audio: []), for: request()))
        XCTAssertFalse(PlozzigenRemoteProbePolicy.isComplete(probe(subtitles: []), for: request()))
        let unresolved = TrackInfo(id: 1, name: "Japanese", codec: "opus", language: "jpn", isDefault: true)
        XCTAssertFalse(PlozzigenRemoteProbePolicy.isComplete(probe(audio: [unresolved]), for: request()))
        let noHeader = TrackInfo(id: 3, name: "Full", codec: "ass", language: "eng", isDefault: true)
        XCTAssertFalse(PlozzigenRemoteProbePolicy.isComplete(probe(subtitles: [noHeader]), for: request()))
        var changed = request()
        changed.preferredAudioTrackID = 99
        XCTAssertFalse(PlozzigenRemoteProbePolicy.isComplete(probe(), for: changed))
        changed = request()
        changed.subtitleTracks.append(.init(id: 4, kind: .subtitle, displayTitle: "Missing", codec: "ass"))
        XCTAssertFalse(PlozzigenRemoteProbePolicy.isComplete(probe(), for: changed))
        changed.subtitleTracks[1].isExternal = true
        XCTAssertTrue(PlozzigenRemoteProbePolicy.isComplete(probe(), for: changed),
                      "A provider's separate sidecar is not an embedded demuxed track")
    }

    private var remoteURL: URL { URL(string: "https://fixture.test/video.mkv")! }

    private func request() -> PlaybackRequest {
        PlaybackRequest(
            item: .init(id: "episode", title: "Episode", kind: .episode), streamURL: remoteURL,
            audioTracks: [.init(id: 1, kind: .audio, displayTitle: "Japanese", codec: "opus", channels: 2)],
            subtitleTracks: [.init(id: 3, kind: .subtitle, displayTitle: "Full", codec: "ass")],
            sourceMetadata: .init(
                container: "mkv", video: .init(codec: "av1", width: 1920, height: 1080),
                audio: .init(codec: "opus", channels: 2)
            )
        )
    }

    private func probe(width: Int32 = 1920, audio: [TrackInfo]? = nil, subtitles: [TrackInfo]? = nil) -> SourceProbe {
        SourceProbe(
            url: remoteURL, durationSeconds: 1440, videoFormat: .sdr, videoCodecID: 225,
            videoCodecName: "av1", videoWidth: width, videoHeight: 1080, videoFrameRate: 24,
            isDolbyVision: false,
            audioTracks: audio ?? [.init(
                id: 1, name: "Japanese", codec: "opus", language: "jpn",
                channels: 2, isDefault: true, sampleRate: 48_000
            )],
            subtitleTracks: subtitles ?? [.init(
                id: 3, name: "Full", codec: "ass", language: "eng",
                isDefault: true, assHeader: "[Script Info]"
            )]
        )
    }
}
