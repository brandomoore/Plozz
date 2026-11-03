#if canImport(UIKit)
import CoreModels
import XCTest
@testable import CoreUI

@MainActor
final class ExternalMediaOpeningTests: XCTestCase {
    private let item = MediaItem(
        id: "movie:fixture", title: "Movie", kind: .movie,
        versions: [.init(id: "Movie.strmlnk", container: "strmlnk")]
    )

    private func link() throws -> ExternalMediaLink {
        try ExternalMediaLink(contents: Data("https://tv.apple.com/us/movie/example/id".utf8))
    }

    func testResolvesExactSourceAndOpensOfficialDestination() async throws {
        let link = try link()
        var requests: [URL] = []
        let opener = ExternalMediaOpening { requests.append($0); return true }
        await opener.open(item, provider: Provider { id, version in
            XCTAssertEqual(id, "movie:fixture")
            XCTAssertEqual(version, "Movie.strmlnk")
            return link
        })
        XCTAssertEqual(requests, [link.url])
        XCTAssertFalse(opener.failed)
    }

    func testUnavailableDestinationAndInvalidFileProduceVisibleFailure() async throws {
        let link = try link()
        let opener = ExternalMediaOpening { _ in false }
        await opener.open(item, provider: Provider { _, _ in link })
        XCTAssertTrue(opener.failed)
        let invalid = ExternalMediaOpening { _ in XCTFail("Must not open"); return true }
        await invalid.open(item, provider: Provider { _, _ in throw AppError.notFound })
        XCTAssertTrue(invalid.failed)
    }

    func testAuthorizationIsRecheckedAfterReadingFile() async throws {
        let link = try link()
        var authorizationChecks = 0
        let opener = ExternalMediaOpening { _ in XCTFail("Scope changed"); return true }
        await opener.open(item, provider: Provider { _, _ in link }) {
            authorizationChecks += 1
            return authorizationChecks == 1
        }
        XCTAssertEqual(authorizationChecks, 2)
        XCTAssertFalse(opener.failed)
    }

    func testCancelledOwnerCannotOpenOrPublishAnError() async throws {
        let link = try link()
        let opener = ExternalMediaOpening { _ in XCTFail("Owner disappeared"); return true }
        await opener.open(item, provider: Provider { _, _ in
            await opener.cancel()
            return link
        })
        XCTAssertFalse(opener.failed)
    }

    private struct Provider: MediaProvider {
        let resolve: @Sendable (String, String?) async throws -> ExternalMediaLink
        var kind: ProviderKind { .mediaShare }
        var session: UserSession {
            .init(server: .init(id: "share", name: "Share", baseURL: URL(string: "https://nas.example")!,
                                provider: .mediaShare),
                  userID: "user", userName: "User", deviceID: "device", accessToken: "")
        }
        func externalMediaLink(for id: String, mediaSourceID: String?) async throws -> ExternalMediaLink {
            try await resolve(id, mediaSourceID)
        }
        func libraries() async throws -> [MediaLibrary] { [] }
        func continueWatching(limit: Int) async throws -> [MediaItem] { [] }
        func latest(limit: Int) async throws -> [MediaItem] { [] }
        func item(id: String) async throws -> MediaItem { throw AppError.notFound }
        func children(of itemID: String) async throws -> [MediaItem] { [] }
        func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
            throw AppError.notFound
        }
        func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
        func playbackInfo(for itemID: String) async throws -> PlaybackRequest { throw AppError.notFound }
        func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {}
        func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
    }
}
#endif
