import XCTest
@testable import FeaturePlayback

final class HLSPlaylistSummaryTests: XCTestCase {
    private let master = """
    #EXTM3U
    #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aac",NAME="English",LANGUAGE="en",DEFAULT=YES,CHANNELS="2",URI="en.m3u8"
    #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aac",NAME="Deutsch",LANGUAGE="de",CHANNELS="2",URI="de.m3u8"
    #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aac-lo",NAME="English",LANGUAGE="en",DEFAULT=YES,CHANNELS="2",URI="en-lo.m3u8"
    #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="English",LANGUAGE="en",URI="subs.m3u8"
    #EXT-X-MEDIA:TYPE=CLOSED-CAPTIONS,GROUP-ID="cc",NAME="CC1",LANGUAGE="en",INSTREAM-ID="CC1"
    #EXT-X-STREAM-INF:BANDWIDTH=6000000,AVERAGE-BANDWIDTH=5000000,RESOLUTION=1920x1080,FRAME-RATE=50.000,CODECS="avc1.640028,mp4a.40.2",AUDIO="aac",SUBTITLES="subs"
    1080.m3u8
    #EXT-X-STREAM-INF:BANDWIDTH=6000000,RESOLUTION=1920x1080,FRAME-RATE=50.000,CODECS="avc1.640028,mp4a.40.2",AUDIO="aac"
    https://backup.example.invalid/1080.m3u8
    #EXT-X-STREAM-INF:BANDWIDTH=1500000,RESOLUTION=640x360,CODECS="avc1.4d401e,mp4a.40.2",AUDIO="aac-lo"
    360.m3u8
    """

    func testReadsVariantsAndQuotedCommaSeparatedCodecs() {
        let summary = HLSPlaylistSummary(playlist: master)
        XCTAssertTrue(summary.isMaster)
        XCTAssertEqual(summary.variants.count, 3)
        let top = summary.variants[0]
        XCTAssertEqual(top.bandwidth, 6_000_000)
        XCTAssertEqual(top.averageBandwidth, 5_000_000)
        XCTAssertEqual(top.resolution, "1920x1080")
        XCTAssertEqual(top.frameRate, 50)
        XCTAssertEqual(top.codecs, ["avc1.640028", "mp4a.40.2"])
        XCTAssertEqual(top.audioGroup, "aac")
        XCTAssertEqual(top.subtitleGroup, "subs")
        XCTAssertEqual(top.uri, "1080.m3u8")
    }

    func testUniqueListsCollapseRedundantCopies() {
        let summary = HLSPlaylistSummary(playlist: master)
        XCTAssertEqual(summary.uniqueVideoVariants.map(\.resolution), ["1920x1080", "640x360"])
        XCTAssertEqual(summary.uniqueAudioRenditions.map(\.name), ["English", "Deutsch"])
        XCTAssertEqual(summary.uniqueSubtitleRenditions.map(\.kind), [.subtitles, .closedCaptions])
        XCTAssertEqual(summary.muxedAudioCodecs, ["mp4a.40.2"])
    }

    func testMediaPlaylistIsASingleVariant() {
        let summary = HLSPlaylistSummary(playlist: """
        #EXTM3U
        #EXT-X-TARGETDURATION:6
        #EXTINF:6.0,
        seg1.ts
        """)
        XCTAssertFalse(summary.isMaster)
        XCTAssertTrue(summary.variants.isEmpty)
    }

    func testNearestBandwidthPicksTheClosestVariant() {
        let summary = HLSPlaylistSummary(playlist: master)
        XCTAssertEqual(summary.variant(nearestBandwidth: 1_700_000)?.resolution, "640x360")
        XCTAssertEqual(summary.variant(nearestBandwidth: 5_000_000)?.resolution, "1920x1080")
        XCTAssertNil(summary.variant(nearestBandwidth: 0))
    }

    func testBandwidthIsNotReadFromAverageBandwidth() {
        let attributes = HLSPlaylistSummary.attributes(#"AVERAGE-BANDWIDTH=10,BANDWIDTH=20,CODECS="a,b""#)
        XCTAssertEqual(attributes["BANDWIDTH"], "20")
        XCTAssertEqual(attributes["AVERAGE-BANDWIDTH"], "10")
        XCTAssertEqual(attributes["CODECS"], "a,b")
    }
}
