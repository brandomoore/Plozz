import CoreModels
import AetherEngine
@testable import EnginePlozzigen
import FeaturePlayback
import MediaTransportCore
import XCTest

@MainActor
final class DiscMenuSelectionHostedTests: XCTestCase {
    func testPresentationClockWaitsForOutstandingSeeks() async throws {
        let session = try makeSession { _, _, _ in false }
        session.select(1, position: 0, generation: 1)
        await session.drain()
        let first = session.beginSeek()
        let second = session.beginSeek()
        session.updateTime(3, sourceSeconds: 3, hasPresentedFrame: true)
        XCTAssertFalse(session.state.hasPresentedVideoFrame)
        session.endSeek(generation: first)
        session.updateTime(3, sourceSeconds: 3, hasPresentedFrame: true)
        XCTAssertFalse(session.state.hasPresentedVideoFrame)
        session.endSeek(generation: second)
        session.updateTime(3, sourceSeconds: 3, hasPresentedFrame: true)
        XCTAssertTrue(session.state.hasPresentedVideoFrame)
    }

    func testAudioWarningRequiresReadyTracksWithKnownMissingIdentity() {
        let trueHD = TrackInfo(id: 1, name: "Fixture", codec: "truehd", language: "eng",
                               isDefault: true, mpegTSPID: 0x1100)
        let companion = TrackInfo(id: 2, name: "Fixture", codec: "ac3", language: "eng",
                                  isDefault: false, mpegTSPID: 0x1100)
        let other = TrackInfo(id: 3, name: "Fixture", codec: "ac3", language: "fra",
                              isDefault: false, mpegTSPID: 0x1101)
        let unknown = TrackInfo(id: 4, name: "Fixture", codec: "ac3", language: nil, isDefault: false)
        func result(_ tracks: [TrackInfo], active: Int?, ready: Bool = true, pid: Int = 0x1100)
            -> DiscAudioSelectionResult {
            PlozzigenVideoEngine.discAudioSelectionResult(
                pid: pid, tracks: tracks, activeTrackID: active, hasPresentedFrame: ready
            )
        }
        XCTAssertEqual(result([], active: nil), .pending)
        XCTAssertEqual(result([other], active: 3, ready: false), .pending)
        XCTAssertEqual(result([trueHD, companion], active: nil), .pending)
        XCTAssertEqual(result([trueHD, companion, other], active: 3), .pending)
        XCTAssertEqual(result([unknown, other], active: 3), .pending)
        XCTAssertEqual(result([other], active: 3, pid: -1), .pending)
        XCTAssertEqual(result([trueHD, companion], active: 1), .selected)
        XCTAssertEqual(result([trueHD, companion], active: 2), .selected)
        XCTAssertEqual(result([other], active: 3), .unavailable)
    }

    func testPendingAudioIsRetriedAndOnlyConfirmedFailureShowsNotice() async throws {
        var result = DiscAudioSelectionResult.pending
        let session = try makeSession(selectAudio: { _ in result }) { _, _, _ in false }
        session.select(800, position: 0, generation: 1)
        session.selectAudio(pid: 0x1100, generation: 1)
        await session.drain()
        XCTAssertNil(session.state.notice)
        result = .unavailable
        session.tracksReady()
        XCTAssertTrue(session.state.audioSelectionUnavailable)
        result = .selected
        session.tracksReady()
        XCTAssertNil(session.state.notice)
        result = .unavailable
        session.selectAudio(pid: 0x1101, generation: 0)
        session.tracksReady()
        XCTAssertNil(session.state.notice, "An old generation cannot restore a warning")
    }

    private struct UnusedResolver: MediaTransportNetworkFileResolving {
        func resolve(_ locator: NetworkFileLocator) async throws -> MediaTransportResolvedSource {
            XCTFail("Selection scheduling must not open the fixture's transport")
            throw MediaTransportError.unsupportedCapability("Selection fixture has no media")
        }
    }

    private func makeSession(
        selectAudio: @escaping (Int) -> DiscAudioSelectionResult = { _ in .selected },
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
            selectAudio: selectAudio, selectSubtitle: { _, _ in true }
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

    func testStoppedPlaylistWaitsForANewPresentedFrame() async throws {
        let session = try makeSession { _, _, _ in false }
        session.state.isFirstPlay = false
        session.select(800, position: 0, generation: 1)
        await session.drain()
        session.updateTime(1, sourceSeconds: 1, hasPresentedFrame: true)
        XCTAssertFalse(session.state.showsLoadingIndicator)
        session.select(-1, position: 0, generation: 2)
        session.updateTime(2, sourceSeconds: 2, hasPresentedFrame: true)
        XCTAssertFalse(session.state.hasPresentedVideoFrame, "A retired player's clock cannot finish the transition")
        XCTAssertTrue(session.state.showsLoadingIndicator)
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
