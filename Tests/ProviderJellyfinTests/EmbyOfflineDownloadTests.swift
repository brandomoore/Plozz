import XCTest
@testable import ProviderJellyfin

final class EmbyOfflineDownloadTests: XCTestCase {
    func testExtraAudioUsesAudioOnlyRouteAndExactSourceWithoutChangingAuthentication() throws {
        let url = try EmbyOfflineDownloadURLBuilder.makeURL(
            from: XCTUnwrap(URL(string: "https://emby.test/base/Videos/movie/master.m3u8?api_key=test-token&DeviceId=device&AudioStreamIndex=1&VideoCodec=hevc&SubtitleStreamIndex=5")),
            itemID: "movie", mediaSourceID: "edition2", audioStreamIndex: 3,
            audioOnly: true, sessionID: "owned-session",
            maximumVideoBitrateBps: 2_000_000, maximumHeight: 720
        )
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value) })
        XCTAssertEqual(components.path, "/base/Audio/movie/stream.aac")
        XCTAssertEqual(query["api_key"], "test-token")
        XCTAssertEqual(query["DeviceId"], "device")
        XCTAssertEqual(query["MediaSourceId"], "edition2")
        XCTAssertEqual(query["AudioStreamIndex"], "3")
        XCTAssertEqual(query["PlaySessionId"], "owned-session")
        XCTAssertNil(query["VideoCodec"])
        XCTAssertNil(query["SubtitleStreamIndex"])
        XCTAssertEqual(query["AllowAudioStreamCopy"], "false")
    }

    func testPrimaryVideoUsesBoundedProgressiveMP4() throws {
        let url = try EmbyOfflineDownloadURLBuilder.makeURL(
            from: XCTUnwrap(URL(string: "https://emby.test/Videos/movie/master.m3u8?VideoBitrate=9000000&MaxHeight=2160")),
            itemID: "movie", mediaSourceID: "edition2", audioStreamIndex: 3,
            audioOnly: false, sessionID: "owned-session",
            maximumVideoBitrateBps: 2_000_000, maximumHeight: 720
        )
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value) })
        XCTAssertEqual(components.path, "/Videos/movie/stream.mp4")
        XCTAssertEqual(query["VideoCodec"], "h264")
        XCTAssertEqual(query["VideoBitrate"], "2000000")
        XCTAssertEqual(query["MaxHeight"], "720")
        XCTAssertEqual(query["AudioStreamIndex"], "3")
        XCTAssertEqual(query["StartTimeTicks"], "0")
    }

    func testDifferentItemOrNonHTTPInputIsRejected() throws {
        for value in ["https://emby.test/Videos/other/master.m3u8", "file:///Videos/movie/master.m3u8"] {
            XCTAssertThrowsError(try EmbyOfflineDownloadURLBuilder.makeURL(
                from: XCTUnwrap(URL(string: value)), itemID: "movie", mediaSourceID: "edition2",
                audioStreamIndex: 1, audioOnly: true, sessionID: "owned",
                maximumVideoBitrateBps: 2_000_000, maximumHeight: 720
            ))
        }
    }
}
