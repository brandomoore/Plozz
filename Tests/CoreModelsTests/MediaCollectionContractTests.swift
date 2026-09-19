import CoreModels
import XCTest

final class MediaCollectionContractTests: XCTestCase {
    func testUnsupportedProviderDoesNotAdvertiseOrPretendCollectionsAreEmpty() async {
        let provider = CollectionUnsupportedProvider()
        XCTAssertFalse(provider.capabilities.contains(.libraryCollections))
        do {
            _ = try await provider.collections(in: "library", page: PageRequest())
            XCTFail("Unsupported discovery must not return a successful empty list")
        } catch {
            XCTAssertEqual(error as? AppError, .notFound)
        }
    }

    func testCollectionCapabilityDoesNotOverlapExistingCapabilities() throws {
        let previous: ProviderCapability = [.video, .music, .remoteSubtitles]
        XCTAssertFalse(previous.contains(.libraryCollections))
        let combined = previous.union(.libraryCollections)
        let decoded = try JSONDecoder().decode(
            ProviderCapability.self, from: JSONEncoder().encode(combined)
        )
        XCTAssertTrue(decoded.contains(.libraryCollections))
        XCTAssertTrue(decoded.isSuperset(of: previous))
    }
}

private struct CollectionUnsupportedProvider: MediaProvider, CapabilityReporting {
    let kind: ProviderKind = .mediaShare
    let session = UserSession(
        server: MediaServer(
            id: "server", name: "Server",
            baseURL: URL(string: "https://media.example")!, provider: .mediaShare
        ),
        userID: "user", userName: "Viewer", deviceID: "device", accessToken: ""
    )
    func libraries() async throws -> [MediaLibrary] { [] }
    func continueWatching(limit: Int) async throws -> [MediaItem] { [] }
    func latest(limit: Int) async throws -> [MediaItem] { [] }
    func item(id: String) async throws -> MediaItem { throw AppError.notFound }
    func children(of itemID: String) async throws -> [MediaItem] { throw AppError.notFound }
    func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        throw AppError.notFound
    }
    func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
    func playbackInfo(for itemID: String) async throws -> PlaybackRequest { throw AppError.notFound }
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {}
    func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
}
