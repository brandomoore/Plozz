import AVFoundation
import CoreModels
import XCTest
@testable import FeaturePlayback

@MainActor
final class NativePlaybackLifecycleTests: XCTestCase {
    func testRepeatedStopDisconnectsRetainedPlayersAndTheirOutputs() async throws {
        let engine = NativeVideoEngine(startsMuted: true)
        defer { engine.stop() }
        var retiredPlayers: [AVPlayer] = []
        for _ in 0..<8 {
            await engine.load(request: request(), startPosition: 0)
            let player = try XCTUnwrap(engine.underlyingPlayer)
            let item = try XCTUnwrap(player.currentItem)
            XCTAssertFalse(item.outputs.isEmpty)
            retiredPlayers.append(player)

            engine.stop()
            engine.stop()

            XCTAssertNil(engine.underlyingPlayer)
            XCTAssertEqual(engine.status, .idle)
            XCTAssertEqual(player.rate, 0)
            XCTAssertTrue(item.outputs.isEmpty, "Stop must detach owned outputs even before their tasks resume.")
            XCTAssertTrue(retiredPlayers.allSatisfy { $0.currentItem == nil },
                          "A retained presentation or diagnostic player must not retain a stopped media pipeline.")
        }
    }

    func testReloadDisconnectsOldPlayerBeforeReplacementResolutionCompletes() async throws {
        let resolver = SuspendedResolver()
        let engine = NativeVideoEngine(authenticatedHTTPResolver: resolver, startsMuted: true)
        defer { engine.stop() }
        let surface = engine.makeVideoOutputView()
        await engine.load(request: request(), startPosition: 0)
        let oldPlayer = try XCTUnwrap(engine.underlyingPlayer)
        let layer = try XCTUnwrap(surface.layer as? AVPlayerLayer)
        XCTAssertTrue(layer.player === oldPlayer)

        let replacement = try authenticatedRequest()
        let load = Task { await engine.load(request: replacement, startPosition: 0) }
        await fulfillment(of: [resolver.started], timeout: 2)
        let retiredItem = oldPlayer.currentItem
        let disconnectedSurface = layer.player == nil
        resolver.resume()
        await load.value

        XCTAssertNil(retiredItem, "Reload must release the old item before waiting on the new provider.")
        XCTAssertTrue(disconnectedSurface, "Both platforms must disconnect the outgoing layer during resolution.")
        XCTAssertFalse(engine.underlyingPlayer === oldPlayer)
        XCTAssertTrue(layer.player === engine.underlyingPlayer)
    }

    func testCancelledLoadReturnsToIdleWithoutReportingFailure() async throws {
        let resolver = SuspendedResolver()
        let engine = NativeVideoEngine(authenticatedHTTPResolver: resolver, startsMuted: true)
        defer { engine.stop() }
        var failures: [AppError] = []
        engine.onFailure = { failures.append($0) }
        let request = try authenticatedRequest()
        let load = Task { await engine.load(request: request, startPosition: 0) }
        await fulfillment(of: [resolver.started], timeout: 2)
        load.cancel()
        resolver.resume()
        await load.value
        XCTAssertEqual(engine.status, .idle)
        XCTAssertNil(engine.underlyingPlayer)
        XCTAssertTrue(failures.isEmpty)
    }

    func testCancelledOldLoadCannotStopNewerPlayback() async throws {
        let resolver = SuspendedResolver()
        let engine = NativeVideoEngine(authenticatedHTTPResolver: resolver, startsMuted: true)
        defer { engine.stop() }
        let oldRequest = try authenticatedRequest()
        let load = Task { await engine.load(request: oldRequest, startPosition: 0) }
        await fulfillment(of: [resolver.started], timeout: 2)
        await engine.load(request: request(), startPosition: 0)
        let current = try XCTUnwrap(engine.underlyingPlayer)
        load.cancel()
        resolver.resume()
        await load.value
        XCTAssertTrue(engine.underlyingPlayer === current)
        XCTAssertNotNil(current.currentItem)
        XCTAssertNotEqual(engine.status, .idle)
    }

    private func request() -> PlaybackRequest {
        .init(
            item: .init(id: "reopen", title: "Reopen fixture", kind: .movie),
            streamURL: URL(fileURLWithPath: "/dev/null"),
            sourceMetadata: .init(video: .init(codec: "h264")),
            sourceProvider: .jellyfin
        )
    }

    private func authenticatedRequest() throws -> PlaybackRequest {
        .init(
            item: .init(id: "replacement", title: "Replacement fixture", kind: .movie),
            playbackSource: .authenticatedHTTP(try .init(
                provider: .jellyfin, accountID: "fixture", credentialRevision: CredentialRevision(),
                itemID: "replacement", deliveryMode: .directFile, purpose: .mediaStream,
                resource: .init(pathBase: .configuredBaseURL, path: "Videos/replacement/stream")
            ))
        )
    }

    private final class SuspendedResolver: AuthenticatedHTTPResourceResolving {
        let started = XCTestExpectation(description: "Playback resolution started")
        private var continuation: CheckedContinuation<URL, Never>?

        func resolve(_ locator: AuthenticatedHTTPPlaybackLocator) async throws -> URL {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                started.fulfill()
            }
        }

        func resume() {
            continuation?.resume(returning: URL(fileURLWithPath: "/dev/null"))
            continuation = nil
        }
    }
}
