import CoreModels
import Foundation
import MetadataKit
import XCTest
@testable import AppRuntime

@MainActor
final class DiscoverRuntimeTests: XCTestCase {
    func testPublicRequestsReloadUserConfigurationOffMainActor() async throws {
        for token in ["first-test-key", "replacement-test-key"] {
            let result = try await DiscoverRuntime.publicPage(
                .popularMovies, page: 2, language: "fr",
                configurationLoader: {
                    XCTAssertFalse(Thread.isMainThread)
                    return MetadataProviderConfig(tmdb: .disabled).withUserToken(token)
                },
                browse: { feed, page, language, config in
                    XCTAssertEqual(feed, .popularMovies)
                    XCTAssertEqual(page, 2)
                    XCTAssertEqual(language, "fr")
                    guard case .userToken(let actual) = config.tmdb else {
                        XCTFail("Discover must use the saved user credential")
                        return DiscoverPage(items: [], nextPage: nil)
                    }
                    XCTAssertEqual(actual, token)
                    return DiscoverPage(items: [], nextPage: 3)
                }
            )
            XCTAssertEqual(result.nextPage, 3)
        }
    }

    func testCancelledPublicRequestDoesNotLoadCredentialsOrBrowse() async {
        let request = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await DiscoverRuntime.publicPage(
                    .trending, page: 1, language: "en",
                    configurationLoader: {
                        XCTFail("A cancelled request must not read credentials")
                        return MetadataProviderConfig(tmdb: .disabled)
                    },
                    browse: { _, _, _, _ in
                        XCTFail("A cancelled request must not browse")
                        return DiscoverPage(items: [], nextPage: nil)
                    }
                )
                XCTFail("Expected cancellation")
            } catch is CancellationError {
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
        await request.value
    }
}
