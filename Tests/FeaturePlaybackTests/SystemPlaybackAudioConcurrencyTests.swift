#if os(tvOS)
import Synchronization
import XCTest
@testable import FeaturePlayback

@MainActor
final class SystemPlaybackAudioConcurrencyTests: XCTestCase {
    func testProductionReaderRunsOffMainAndCoalescesInitializationWithRefreshes() async {
        let reads = Mutex((count: 0, onMain: false))
        let audio = SystemPlaybackAudio(backend: SystemPlaybackAudioPreferences(readState: {
            reads.withLock {
                $0.count += 1
                $0.onMain = $0.onMain || Thread.isMainThread
            }
            return .init(values: [.reduceLoudSounds: true])
        }))
        let first = audio.refresh()
        let second = audio.refresh()
        await first.value
        await second.value
        XCTAssertEqual(reads.withLock { $0.count }, 1)
        XCTAssertFalse(reads.withLock { $0.onMain })
        XCTAssertEqual(audio.values, [.reduceLoudSounds: true])
    }

    func testCancellationDuringPreflightNeverPostsAndRepeatPressCannotStartAnotherChange() async throws {
        let backend = SuspendedSystemAudioBackend()
        let audio = SystemPlaybackAudio(backend: backend)
        let change = Task { await audio.setEnabled(true, for: .reduceLoudSounds) }
        defer {
            change.cancel()
            backend.resume()
        }
        let deadline = ContinuousClock.now + .seconds(2)
        while (backend.readCount == 0 || audio.pending.isEmpty), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertEqual(backend.readCount, 1)
        XCTAssertEqual(audio.pending, [.reduceLoudSounds])
        await audio.setEnabled(true, for: .reduceLoudSounds)
        XCTAssertEqual(backend.writeCount, 0)
        change.cancel()
        backend.resume()
        await change.value
        XCTAssertEqual(backend.writeCount, 0)
        XCTAssertTrue(audio.pending.isEmpty)
        XCTAssertNil(audio.failure)
        XCTAssertEqual(audio.values[.reduceLoudSounds], false)
    }

    func testCancellingOneWaiterDoesNotCancelTheSharedRead() async throws {
        let backend = SuspendedSystemAudioBackend()
        let audio = SystemPlaybackAudio(backend: backend)
        let shared = audio.refresh()
        let waiter = Task { await audio.refresh().value }
        defer {
            waiter.cancel()
            backend.resume()
        }
        let deadline = ContinuousClock.now + .seconds(2)
        while backend.readCount == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        waiter.cancel()
        backend.resume()
        await shared.value
        await waiter.value
        XCTAssertEqual(backend.readCount, 1)
        XCTAssertEqual(audio.values[.reduceLoudSounds], false)
    }

    func testPendingReadDoesNotRetainItsOwner() async throws {
        let backend = SuspendedSystemAudioBackend()
        defer { backend.resume() }
        var audio: SystemPlaybackAudio? = SystemPlaybackAudio(backend: backend)
        weak var owner = audio
        let read = try XCTUnwrap(audio).refresh()
        let deadline = ContinuousClock.now + .seconds(2)
        while backend.readCount == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        audio = nil
        XCTAssertNil(owner)
        backend.resume()
        await read.value
    }
}

@MainActor
private final class SuspendedSystemAudioBackend: SystemPlaybackAudioControlling {
    var readCount = 0
    var writeCount = 0
    private var suspended = true
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func read() async -> SystemPlaybackAudioState {
        readCount += 1
        if suspended {
            await withCheckedContinuation { continuations.append($0) }
        }
        return .init(values: [.reduceLoudSounds: false])
    }

    func resume() {
        suspended = false
        let pending = continuations
        continuations.removeAll()
        for continuation in pending { continuation.resume() }
    }

    func setEnabled(_ enabled: Bool, for setting: SystemPlaybackAudioSetting) {
        writeCount += 1
    }
}
#endif
