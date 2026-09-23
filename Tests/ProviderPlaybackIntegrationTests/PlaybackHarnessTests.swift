import Foundation
import XCTest

final class PlaybackHarnessTests: XCTestCase {
    func testConfigurationIncludesSiloButRejectsLocalShares() throws {
        XCTAssertNoThrow(try configuration(provider: "silo").validate())
        XCTAssertThrowsError(try configuration(provider: "mediaShare").validate())
        for provider in ["jellyfin", "plex", "emby"] {
            XCTAssertNoThrow(try configuration(provider: provider).validate())
        }
    }

    func testConfigurationRejectsUnboundedOrInvalidRuns() throws {
        for seconds in ["0", "1000", "-1"] {
            XCTAssertThrowsError(try configuration(startup: seconds).validate())
        }
        for url in ["http://user:secret@localhost:8096", "file:///tmp/test", "http://localhost/?api_key=secret"] {
            XCTAssertThrowsError(try configuration(url: url).validate())
        }
    }

    func testSegmentRetainsExactIssuedQueryAndInitializationURL() throws {
        let result = try PlaybackTestPlaylist.segment("""
        #EXTM3U
        #EXT-X-TARGETDURATION:3
        #EXT-X-MAP:URI="init.mp4?api_key=child%2Btoken"
        #EXTINF:3.0,
        segment0.mp4?api_key=issued&session=fixture
        """, baseURL: URL(string: "https://server.test/video/main.m3u8?api_key=parent")!)
        XCTAssertEqual(result.initialization?.absoluteString, "https://server.test/video/init.mp4?api_key=child%2Btoken")
        XCTAssertEqual(result.media.absoluteString, "https://server.test/video/segment0.mp4?api_key=issued&session=fixture")
        XCTAssertFalse(result.media.absoluteString.contains("parent"))
        let playing = try PlaybackTestPlaylist.segment("""
        #EXTM3U
        #EXT-X-MAP:URI="init.mp4"
        #EXTINF:3.0,
        first.mp4
        #EXTINF:3.0,
        current.mp4
        """, baseURL: URL(string: "https://server.test/video/main.m3u8")!, position: 4)
        XCTAssertEqual(playing.media.lastPathComponent, "current.mp4",
                       "Audio proof should read the current media, not restart an encoder at the first segment")
    }

    func testNeverForwardsMediaCredentialsToAnotherOriginOrPretendsEncryptedAudioWasDecoded() {
        let base = URL(string: "https://server.test/video/main.m3u8")!
        for line in ["//foreign.test/segment.mp4", "http://server.test/segment.mp4", "https://server.test:444/segment.mp4",
                     "#EXT-X-KEY:METHOD=AES-128,URI=\"key\"\nsegment.mp4",
                     "#EXT-X-BYTERANGE:500@0\nsegment.mp4",
                     "#EXT-X-STREAM-INF:BANDWIDTH=500000\nmain.m3u8",
                     "#EXT-X-MAP:URI=\"//foreign.test/init.mp4\"\nsegment.mp4"] {
            XCTAssertThrowsError(try PlaybackTestPlaylist.segment("#EXTM3U\n" + line, baseURL: base))
        }
    }

    private func configuration(
        provider: String = "jellyfin", startup: String = "30", url: String = "http://127.0.0.1:8096"
    ) throws -> PlaybackTestConfiguration {
        let json = """
        {"startupTimeoutSeconds":\(startup),"playbackSeconds":10,"seekSeconds":20,"resumeSeconds":10,
         "servers":{"\(provider)":{"baseURL":"\(url)","serverID":"fixture","userID":"fixture",
         "tokenFile":"/private/fixture-token","itemID":"fixture","codecs":["\(provider == "silo" ? "server" : "h264")"]}}}
        """
        return try JSONDecoder().decode(PlaybackTestConfiguration.self, from: Data(json.utf8))
    }
}
