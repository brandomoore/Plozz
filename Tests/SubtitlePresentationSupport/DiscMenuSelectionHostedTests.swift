import CoreModels
@testable import EnginePlozzigen
import FeaturePlayback
import MediaTransportCore
import XCTest

@MainActor
final class DiscMenuSelectionHostedTests: XCTestCase {
    private struct UnusedResolver: MediaTransportNetworkFileResolving {
        func resolve(_ locator: NetworkFileLocator) async throws -> MediaTransportResolvedSource {
            XCTFail("Selection scheduling must not open the fixture's transport")
            throw MediaTransportError.unsupportedCapability("Selection fixture has no media")
        }
    }

    private func makeSession(
        load: @escaping (TransportDiscDirectoryReader, TimeInterval, DiscMenuClip?) async throws -> Bool
    ) throws -> DiscMenuSession {
        let index = try NetworkFileLocator(
            accountID: "fixture", sourceID: "fixture", credentialRevision: CredentialRevision(),
            relativePath: "Movie/BDMV/index.bdmv",
            representation: .init(
                size: 40, identity: .init(kind: .strongETag, value: "\"index\""), consistency: .changeDetecting
            ),
            formatHint: .init(container: "bdmv")
        )
        let locator = try NetworkDiscLocator(anchor: index, files: [.init(path: "BDMV/index.bdmv", locator: index)])
        let reader = TransportDiscDirectoryReader(locator: locator, resolver: UnusedResolver())
        let session = try DiscMenuSession(
            reader: reader, region: 1, state: DiscMenuPlaybackState(),
            load: load, pause: {}, resume: {}, isPaused: { false },
            selectAudio: { _ in true }, selectSubtitle: { _, _ in true }
        )
        addTeardownBlock { @MainActor in
            session.stop()
            await session.drain()
        }
        return session
    }

    func testIdenticalPendingSelectionsShareOneLoadButLaterReplayReloads() async throws {
        let started = expectation(description: "First load started")
        var resume: CheckedContinuation<Void, Never>?
        var loads = 0
        let session = try makeSession { _, _, _ in
            loads += 1
            if loads == 1 {
                await withCheckedContinuation {
                    resume = $0
                    started.fulfill()
                }
            }
            try Task.checkCancellation()
            return false
        }
        session.select(800, position: 0, generation: 1)
        await fulfillment(of: [started], timeout: 3)
        session.select(800, position: 0, generation: 2)
        resume?.resume()
        await session.drain()
        XCTAssertEqual(loads, 1)
        XCTAssertEqual(session.state.playlist, 800)
        XCTAssertFalse(session.state.isOpening)
        XCTAssertNil(session.state.failure)

        session.select(800, position: 0, generation: 3)
        await session.drain()
        XCTAssertEqual(loads, 2, "A later replay is not a duplicate in-flight request")
    }

    func testChangedPositionCancelsAndReplacesThePendingLoad() async throws {
        try await checkReplacement(
            firstClip: nil, nextClip: nil, nextPosition: 14,
            nextPlaylist: 800
        )
    }

    func testRepeatedClipKeepsDistinctAuthoredItemIdentity() async throws {
        try await checkReplacement(
            firstClip: DiscMenuClip(index: 0, path: "BDMV/STREAM/00001.m2ts",
                                    sourceRange: 0..<4, playlistStart: 0),
            nextClip: DiscMenuClip(index: 1, path: "BDMV/STREAM/00001.m2ts",
                                   sourceRange: 0..<4, playlistStart: 0),
            nextPosition: 0, nextPlaylist: 800
        )
    }

    func testChangedPlaylistCancelsAndReplacesThePendingLoad() async throws {
        try await checkReplacement(firstClip: nil, nextClip: nil, nextPosition: 0, nextPlaylist: 20)
    }

    func testSharedLoadFailureRemainsVisible() async throws {
        let started = expectation(description: "Shared load started")
        var resume: CheckedContinuation<Void, Never>?
        var loads = 0
        let session = try makeSession { _, _, _ in
            loads += 1
            await withCheckedContinuation {
                resume = $0
                started.fulfill()
            }
            throw CocoaError(.fileReadCorruptFile)
        }
        session.select(800, position: 0, generation: 1)
        await fulfillment(of: [started], timeout: 3)
        session.select(800, position: 0, generation: 2)
        resume?.resume()
        await session.drain()
        XCTAssertEqual(loads, 1)
        XCTAssertNotNil(session.state.failure)
        XCTAssertNil(session.state.playlist)
        XCTAssertFalse(session.state.isOpening)
    }

    func testStoppingSharedLoadDoesNotPublishLateSuccess() async throws {
        let started = expectation(description: "Shared load started")
        var resume: CheckedContinuation<Void, Never>?
        var loads = 0
        var cancelled = false
        let session = try makeSession { _, _, _ in
            loads += 1
            await withCheckedContinuation {
                resume = $0
                started.fulfill()
            }
            cancelled = Task.isCancelled
            return false
        }
        session.select(800, position: 0, generation: 1)
        await fulfillment(of: [started], timeout: 3)
        session.select(800, position: 0, generation: 2)
        session.stop()
        resume?.resume()
        await session.drain()
        XCTAssertEqual(loads, 1)
        XCTAssertTrue(cancelled)
        XCTAssertNil(session.state.playlist)
        XCTAssertNil(session.state.failure)
    }

    private func checkReplacement(
        firstClip: DiscMenuClip?, nextClip: DiscMenuClip?, nextPosition: Double, nextPlaylist: Int
    ) async throws {
        let started = expectation(description: "First load started")
        var resume: CheckedContinuation<Void, Never>?
        var positions: [Double] = []
        var clips: [DiscMenuClip?] = []
        var cancelled = false
        let session = try makeSession { _, position, clip in
            positions.append(position)
            clips.append(clip)
            if positions.count == 1 {
                await withCheckedContinuation {
                    resume = $0
                    started.fulfill()
                }
                cancelled = Task.isCancelled
                try Task.checkCancellation()
            }
            return false
        }
        session.select(800, position: 0, generation: 1, clip: firstClip)
        await fulfillment(of: [started], timeout: 3)
        session.select(nextPlaylist, position: nextPosition, generation: 2, clip: nextClip)
        resume?.resume()
        await session.drain()
        XCTAssertTrue(cancelled)
        XCTAssertEqual(positions, [0, nextPosition])
        XCTAssertEqual(clips, [firstClip, nextClip])
        XCTAssertEqual(session.state.playlist, nextPlaylist)
        XCTAssertEqual(session.state.playItem, nextClip?.index)
        XCTAssertNil(session.state.failure)
    }
}
