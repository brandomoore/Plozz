#if canImport(AVFoundation)
import CoreModels
import Foundation
import XCTest
@testable import FeaturePlayback

private actor DisplayTransitionSleeper {
    private struct Waiter {
        let seconds: TimeInterval
        let continuation: CheckedContinuation<Void, Error>
    }
    private var waiters: [UUID: Waiter] = [:]

    func sleep(_ seconds: TimeInterval) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                waiters[id] = Waiter(seconds: seconds, continuation: continuation)
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    private func cancel(_ id: UUID) {
        waiters.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError())
    }

    func contains(_ seconds: TimeInterval) -> Bool {
        waiters.values.contains { $0.seconds == seconds }
    }

    func release(_ seconds: TimeInterval) {
        guard let id = waiters.first(where: { $0.value.seconds == seconds })?.key else { return }
        waiters.removeValue(forKey: id)?.continuation.resume()
    }
}

@MainActor
final class LiveChannelDisplayTransitionTests: XCTestCase {
    private func makeTransition(_ sleeper: DisplayTransitionSleeper) -> LiveChannelDisplayTransition {
        .init(veil: .init(
            configuration: .init(veilFade: 0.1),
            sleep: { try await sleeper.sleep($0) }
        ))
    }

    private func eventually(
        _ predicate: () async -> Bool, file: StaticString = #filePath, line: UInt = #line
    ) async {
        for _ in 0..<1_000 {
            if await predicate() { return }
            await Task.yield()
        }
        XCTFail("Transition did not reach the expected state", file: file, line: line)
    }

    func testHDRPolicyWaitsForOpaqueAndRevealWaitsForFrameAndSettle() async {
        let sleeper = DisplayTransitionSleeper()
        let transition = makeTransition(sleeper)
        defer { transition.reset() }
        let token = transition.beginPlayback(
            isFullscreen: true, changesSource: false, range: .dolbyVision, settings: .default
        )
        XCTAssertTrue(transition.hidesControls)
        transition.displayDidSettle() // A prior switch cannot settle a policy not yet applied.
        var applied = false
        let task = Task { applied = await transition.preparePlayback(token) }
        await eventually { await sleeper.contains(0.1) }
        XCTAssertFalse(applied)
        await sleeper.release(0.1)
        await task.value
        XCTAssertTrue(applied)
        transition.displayDidSettle()
        transition.update(range: .dolbyVision, hasPresentedFrame: false, failed: false)
        let prematureReveal = await sleeper.contains(0.35)
        XCTAssertFalse(prematureReveal)
        transition.update(range: .dolbyVision, hasPresentedFrame: true, failed: false)
        await eventually { await sleeper.contains(0.35) }
        await sleeper.release(0.35)
        await eventually { !transition.veil.isVeiled }
        XCTAssertFalse(transition.hidesControls)
    }

    func testPreviewReadySDRAndDisabledFadesNeverWait() async {
        let transition = LiveChannelDisplayTransition()
        var disabled = PlaybackSettings.default
        disabled.fadeOnDynamicRangeChange = false
        for (fullscreen, changesSource, range, settings) in [
            (false, true, SourceDynamicRange.dolbyVision, PlaybackSettings.default),
            (true, false, .sdr, .default),
            (true, true, .dolbyVision, disabled)
        ] {
            let token = transition.beginPlayback(
                isFullscreen: fullscreen, changesSource: changesSource, range: range, settings: settings
            )
            XCTAssertFalse(transition.veil.isVeiled)
            let prepared = await transition.preparePlayback(token)
            XCTAssertTrue(prepared)
        }
        transition.reset()
    }

    func testExitHandsOpaqueBlackToRootBeforeOutputRestoreAndDismissal() async throws {
        let sleeper = DisplayTransitionSleeper()
        let transition = makeTransition(sleeper)
        let window = DisplayVeilModel()
        defer { transition.reset(); window.lower() }
        let token = try XCTUnwrap(transition.beginExit(kind: .dynamicRange))
        XCTAssertNil(transition.beginExit(kind: .dynamicRange))
        var actions: [String] = []
        let task = Task {
            await transition.finishExit(
                token, kind: .dynamicRange, windowVeil: window,
                restoreOutput: {
                    XCTAssertEqual(window.veilOpacity, 1)
                    XCTAssertEqual(transition.veil.veilOpacity, 1)
                    actions.append("restore")
                },
                dismiss: { XCTAssertEqual(window.veilOpacity, 1); actions.append("dismiss") }
            )
        }
        await eventually { await sleeper.contains(0.1) }
        XCTAssertTrue(actions.isEmpty)
        XCTAssertEqual(window.veilOpacity, 0)
        await sleeper.release(0.1)
        await task.value
        XCTAssertEqual(actions, ["restore", "dismiss"])
        transition.reset()
        XCTAssertFalse(transition.isExiting)
        XCTAssertFalse(transition.veil.isExiting)
        XCTAssertEqual(transition.veil.veilOpacity, 0, "Retained preview must not stay black")
        XCTAssertEqual(window.veilOpacity, 1, "Root continues to cover the HDMI handoff")
    }

    func testStandaloneExitWaitsForSettleOrBoundedFallback() async throws {
        for settles in [true, false] {
            let sleeper = DisplayTransitionSleeper()
            let transition = makeTransition(sleeper)
            let token = try XCTUnwrap(transition.beginExit(kind: .dynamicRange))
            var restored = false
            var dismissed = false
            let task = Task {
                await transition.finishExit(
                    token, kind: .dynamicRange, windowVeil: nil,
                    restoreOutput: { restored = true }, dismiss: { dismissed = true }
                )
            }
            await eventually { await sleeper.contains(0.1) }
            await sleeper.release(0.1)
            await eventually { restored }
            XCTAssertFalse(dismissed)
            if settles { transition.displayDidSettle() }
            let wait = settles ? 0.35 : 5.0
            await eventually { await sleeper.contains(wait) }
            await sleeper.release(wait)
            await task.value
            XCTAssertTrue(dismissed)
            transition.reset()
        }
    }

    func testSupersededEntryCannotApplyItsOldOutputPolicy() async {
        let sleeper = DisplayTransitionSleeper()
        let transition = makeTransition(sleeper)
        let old = transition.beginPlayback(
            isFullscreen: true, changesSource: false, range: .dolbyVision, settings: .default
        )
        let task = Task { await transition.preparePlayback(old) }
        await eventually { await sleeper.contains(0.1) }
        let current = transition.beginPlayback(
            isFullscreen: false, changesSource: true, range: .sdr, settings: .default
        )
        await sleeper.release(0.1)
        let stalePrepared = await task.value
        XCTAssertFalse(stalePrepared)
        let prepared = await transition.preparePlayback(current)
        XCTAssertTrue(prepared)
        XCTAssertFalse(transition.veil.isVeiled)
        transition.reset()
    }

    func testRevocationResumesExitWaiterWithoutDismissingNewPresentation() async throws {
        let sleeper = DisplayTransitionSleeper()
        let transition = makeTransition(sleeper)
        let token = try XCTUnwrap(transition.beginExit(kind: .dynamicRange))
        var restored = false
        var dismissed = false
        let task = Task {
            await transition.finishExit(
                token, kind: .dynamicRange, windowVeil: nil,
                restoreOutput: { restored = true }, dismiss: { dismissed = true }
            )
        }
        await eventually { await sleeper.contains(0.1) }
        await sleeper.release(0.1)
        await eventually { restored }
        transition.reset()
        await task.value
        XCTAssertFalse(dismissed)
        XCTAssertFalse(transition.veil.isExiting)
        XCTAssertFalse(transition.veil.isVeiled)
    }

    func testProbeFailureAndMissingSettleDoNotStrandBlack() async {
        for fails in [true, false] {
            let sleeper = DisplayTransitionSleeper()
            let transition = makeTransition(sleeper)
            let token = transition.beginPlayback(
                isFullscreen: true, changesSource: true, range: nil, settings: .default
            )
            let task = Task { await transition.preparePlayback(token) }
            await eventually { await sleeper.contains(0.1) }
            await sleeper.release(0.1)
            let prepared = await task.value
            XCTAssertTrue(prepared)
            if fails {
                transition.update(range: nil, hasPresentedFrame: false, failed: true)
            } else {
                await eventually { await sleeper.contains(4.5) }
                await sleeper.release(4.5)
            }
            await eventually { !transition.veil.isVeiled }
            transition.reset()
        }
    }

    func testExitHonorsBothProfileFadeSettings() {
        var settings = PlaybackSettings.default
        XCTAssertEqual(LiveChannelDisplayTransition.exitKind(range: .dolbyVision, settings: settings), .dynamicRange)
        XCTAssertEqual(LiveChannelDisplayTransition.exitKind(range: nil, settings: settings), .dynamicRange)
        XCTAssertEqual(LiveChannelDisplayTransition.exitKind(range: .sdr, settings: settings), .frameRate)
        settings.fadeOnDynamicRangeChange = false
        XCTAssertEqual(LiveChannelDisplayTransition.exitKind(range: .dolbyVision, settings: settings), .frameRate)
        settings.fadeOnFrameRateChange = false
        XCTAssertNil(LiveChannelDisplayTransition.exitKind(range: .dolbyVision, settings: settings))
    }
}
#endif
