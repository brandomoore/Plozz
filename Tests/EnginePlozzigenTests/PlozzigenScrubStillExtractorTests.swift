#if canImport(UIKit)
import CoreModels
import CoreNetworking
import Foundation
import XCTest
@testable import EnginePlozzigen

@MainActor
final class PlozzigenScrubStillExtractorTests: XCTestCase {
    func testStopInvalidatesAnOpeningExtractorWhilePreviewHostRetainsIt() async throws {
        let started = expectation(description: "source resolution started")
        let resolver = SuspendedStillResolver { started.fulfill() }
        let engine = try PlozzigenVideoEngine()
        let locator = try AuthenticatedHTTPPlaybackLocator(
            provider: .jellyfin, accountID: "account",
            credentialRevision: CredentialRevision(), itemID: "movie",
            deliveryMode: .directFile, purpose: .originalFile,
            resource: try AuthenticatedHTTPResource(pathBase: .configuredBaseURL, path: "movie.mp4")
        )
        let extractor = PlozzigenScrubStillExtractor(
            source: .authenticatedHTTP(locator), activeEngine: { engine },
            authenticatedHTTPResolver: resolver
        )
        XCTAssertEqual(resolver.requestCount, 0, "Construction must not open the source")
        let pending = Task { await extractor.thumbnail(atSeconds: 4, maxWidth: 480) }
        await fulfillment(of: [started], timeout: 2)
        engine.stop()
        resolver.finish()
        let image = await pending.value
        XCTAssertNil(image)
        let later = await extractor.thumbnail(atSeconds: 8, maxWidth: 480)
        XCTAssertNil(later)
        XCTAssertEqual(resolver.requestCount, 1, "A retained outgoing host must not reopen playback")
        await engine.drainTransport()
    }
}

@MainActor
private final class SuspendedStillResolver: AuthenticatedHTTPResourceResolving {
    private let onStart: () -> Void
    private var continuation: CheckedContinuation<URL, Never>?
    private(set) var requestCount = 0

    init(onStart: @escaping () -> Void) { self.onStart = onStart }

    func resolve(_ locator: AuthenticatedHTTPPlaybackLocator) async throws -> URL {
        requestCount += 1
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            onStart()
        }
    }

    func finish() {
        continuation?.resume(returning: URL(string: "https://example.test/movie.mp4")!)
        continuation = nil
    }
}
#endif
