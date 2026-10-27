import XCTest
import CoreModels
import CoreNetworking
@testable import ProviderPlex

/// Tests for Feature A (version mapping from Plex `Media[]`) and Feature C
/// (metadata refresh) on the Plex provider.
final class PlexVersionsRefreshTests: XCTestCase {
    private func makeSession() -> UserSession {
        UserSession(
            server: MediaServer(id: "srv", name: "Home", baseURL: URL(string: "https://plex.host:32400")!, provider: .plex),
            userID: "u1", userName: "Alice", deviceID: "d1", accessToken: "TOKEN"
        )
    }

    // MARK: - Feature A: versions from Media[]

    func testVersionsMapMultipleMediaElements() throws {
        let media = try JSONDecoder.plozz.decode([PlexMedia].self, from: Data("""
        [
          {"id":1001,"container":"mkv","videoCodec":"hevc","audioCodec":"truehd",
           "duration":7200000,"bitrate":80000,
           "width":3840,"height":2160,"audioChannels":8,
           "Part":[{"file":"/movies/Movie.Extended.mkv","size":12000000000}]},
          {"id":1002,"container":"mp4","videoCodec":"h264","audioCodec":"aac",
           "width":1920,"height":1080,"audioChannels":2,
           "Part":[{"size":3000000000}]}
        ]
        """.utf8))

        let versions = PlexProvider.versions(from: media)
        XCTAssertEqual(versions.map(\.id), ["1001", "1002"])
        XCTAssertEqual(versions[0].height, 2160)
        XCTAssertEqual(versions[0].videoCodec, "hevc")
        XCTAssertEqual(versions[0].audioFormatLabel, "Dolby TrueHD 7.1")
        XCTAssertEqual(versions[0].sizeBytes, 12_000_000_000)
        XCTAssertEqual(versions[0].sizeLabel, "12 GB")
        XCTAssertEqual(versions[0].fileName, "Movie.Extended.mkv")
        XCTAssertEqual(versions[0].bitrate, 80_000_000)
        XCTAssertEqual(versions[0].duration, 7200)
        XCTAssertTrue(versions[0].isDefault)
        XCTAssertEqual(versions[1].resolutionLabel, "1080p")
        XCTAssertFalse(versions[1].isDefault)
    }

    func testVersionsSumMultipartFileSizes() throws {
        let media = try JSONDecoder.plozz.decode([PlexMedia].self, from: Data("""
        [
          {"id":1001,"Part":[{"size":4000000000},{"size":6000000000}]},
          {"id":1002,"Part":[{"size":3000000000}]}
        ]
        """.utf8))

        XCTAssertEqual(PlexProvider.versions(from: media)[0].sizeBytes, 10_000_000_000)
    }

    func testVersionsKeepStreamQualityAndAllAudioLanguagesSourceLocal() throws {
        let media = try JSONDecoder.plozz.decode([PlexMedia].self, from: Data("""
        [
          {"id":1,"container":"mkv","videoCodec":"hevc","width":3840,"height":1600,
           "audioCodec":"truehd","audioChannels":8,"audioProfile":"Dolby Atmos",
           "Part":[{"file":"/private/media/Movie.REMUX.mkv","size":42000000000,"Stream":[
             {"streamType":1,"codec":"hevc","width":3840,"height":1600,"bitDepth":"10","DOVIPresent":true,"DOVIProfile":8,"DOVIBLCompatID":1},
             {"streamType":2,"codec":"truehd","channels":8,"languageTag":"en","selected":true},
             {"streamType":2,"codec":"ac3","channels":6,"languageCode":"fra","language":"French"},
             {"streamType":3,"languageTag":"ja"}
           ]}]},
          {"id":2,"container":"mp4","videoCodec":"h264","height":1080,"audioCodec":"aac","audioChannels":2}
        ]
        """.utf8))
        let versions = PlexProvider.versions(from: media)
        XCTAssertEqual(versions[0].resolutionLabel, "4K")
        XCTAssertEqual(versions[0].hdrLabel, "Dolby Vision")
        XCTAssertEqual(versions[0].sourceMetadata?.video?.bitDepth, 10)
        XCTAssertEqual(versions[0].audioFormatLabel, "Dolby TrueHD + Dolby Atmos + 7.1")
        XCTAssertEqual(versions[0].audioLanguageNames(in: Locale(identifier: "en_US")), ["English", "French"])
        XCTAssertEqual(versions[0].sourceMetadata?.fileSizeBytes, 42_000_000_000)
        XCTAssertEqual(MediaVersion.PickerPresentation(versions[0]).releaseName, "Movie.REMUX.mkv")
        XCTAssertNil(versions[1].hdrLabel)
        XCTAssertTrue(versions[1].audioLanguageNames().isEmpty)
    }

    func testSingleMediaElementProducesNoVersions() throws {
        let media = try JSONDecoder.plozz.decode([PlexMedia].self, from: Data("""
        [{"id":1,"videoCodec":"h264","height":1080}]
        """.utf8))
        XCTAssertEqual(PlexProvider.versions(from: media), [])
        XCTAssertEqual(PlexProvider.versions(from: nil), [])
    }

    func testFilenameHintOnlyChangesTheDisplayFilename() throws {
        let path = "https://media.example/stream?filename=Film%20%26%20Friends.Extended.REMUX.mkv&id=tt123&media_type=movie"
        let media = try JSONDecoder.plozz.decode([PlexMedia].self, from: Data("""
        [
          {"id":1001,"Part":[{"file":"\(path)"}]},
          {"id":1002,"Part":[{"file":"/movies/Film.mkv"}]}
        ]
        """.utf8))
        let versions = PlexProvider.versions(from: media)
        XCTAssertEqual(versions[0].fileName, "Film & Friends.Extended.REMUX.mkv")
        XCTAssertEqual(versions[0].sourceMetadata?.fileName, versions[0].fileName)
        XCTAssertEqual(MediaVersion.PickerPresentation(versions[0]).releaseName, versions[0].fileName)
        XCTAssertEqual(versions[0].playbackMediaSourceID, "1001")
        XCTAssertEqual(media[0].Part?.first?.file, path)
        XCTAssertEqual(versions[1].fileName, "Film.mkv")
    }

    func testOpaqueSourcePathKeepsServerFactsWithoutGuessingAFileName() throws {
        let path = "https://media.example/stream?source_name=Hidden.Extended.REMUX.mkv&token=fixture"
        let media = try JSONDecoder.plozz.decode([PlexMedia].self, from: Data("""
        [
          {"id":1001,"height":2160,"videoCodec":"hevc","Part":[{"file":"\(path)"}]},
          {"id":1002,"Part":[{"file":"/movies/Film.mkv"}]}
        ]
        """.utf8))
        let versions = PlexProvider.versions(from: media)
        XCTAssertNil(versions[0].fileName)
        XCTAssertNil(versions[0].sourceMetadata?.fileName)
        XCTAssertEqual(versions[0].resolutionLabel, "4K")
        XCTAssertNil(versions[0].editionLabel)
        XCTAssertEqual(versions[0].playbackMediaSourceID, "1001")
        XCTAssertEqual(media[0].Part?.first?.file, path)
        XCTAssertEqual(versions[1].fileName, "Film.mkv")
    }

    // MARK: - Feature C: metadata refresh

    func testRefreshMetadataIssuesPut() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/library/metadata/55/refresh", json: "{}")
        let provider = PlexProvider(session: makeSession(), http: stub)

        try await provider.refreshMetadata(itemID: "55")
        XCTAssertEqual(stub.method(forPathSuffix: "/library/metadata/55/refresh"), .put)
    }
}
