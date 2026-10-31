#if os(tvOS) && DEBUG
import CoreModels
import CoreUI
@testable import FeaturePlayback
import SwiftUI
import Synchronization
import UIKit
import XCTest

@MainActor
final class PlayerControlsRevealPerformanceTests: XCTestCase {
    func testPerformanceControlsReveal() async throws {
        try await measure(readDelay: 0, scenario: "player-controls-reveal")
    }

    func testPerformanceControlsRevealWithContendedPreferences() async throws {
        try await measure(readDelay: 0.18, scenario: "player-controls-reveal-contended")
    }

    private func measure(readDelay: TimeInterval, scenario: String) async throws {
        try PerformanceProbe.requireEnabled()
        let reads = Mutex((total: 0, onMain: 0))
        let audio = SystemPlaybackAudio(backend: SystemPlaybackAudioPreferences(readState: {
            reads.withLock {
                $0.total += 1
                if Thread.isMainThread { $0.onMain += 1 }
            }
            Thread.sleep(forTimeInterval: readDelay)
            return .init(values: [.reduceLoudSounds: false, .enhanceDialogue: false])
        }))
        let model = PlayerControlsModel(systemAudio: audio)
        model.title = "Controls responsiveness fixture"
        model.duration = 7_200
        model.currentSeconds = 1_800
        model.bufferedSeconds = 1_840
        model.engineCapabilities = [.playbackSpeed]
        model.audioOptions = (0..<16).map {
            .init(id: $0, title: Text("Audio \($0)"), isSelected: $0 == 0)
        }
        model.subtitleOptions = (0..<32).map {
            .init(id: $0, title: Text("Subtitle \($0)"), isSelected: false)
        }
        let deadline = ContinuousClock.now + .seconds(5)
        while !UIApplication.shared.connectedScenes.contains(where: { $0.activationState == .foregroundActive }),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        window.rootViewController = UIHostingController(rootView:
            PlayerControls(model: model, palette: .dark, actions: .init(), onExitToSurface: {})
                .environment(\.scenePhase, .active)
                .environment(\.locale, Locale(identifier: "en_US"))
                .background(.black)
        )
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        try await Task.sleep(for: .milliseconds(500))
        try await PerformanceProbe.measure(self, scenario: scenario) {
            let before = reads.withLock { $0 }
            var largestGap = Duration.zero
            let heartbeat = Task {
                var last = ContinuousClock.now
                while !Task.isCancelled {
                    try await Task.sleep(for: .milliseconds(2))
                    let now = ContinuousClock.now
                    largestGap = max(largestGap, last.duration(to: now))
                    last = now
                }
            }
            defer { heartbeat.cancel() }
            for _ in 0..<4 {
                try await Task.sleep(for: .milliseconds(10))
                model.controlsVisible = true
                try await Task.sleep(for: .milliseconds(450))
                XCTAssertNotNil(model.subtitleLayout.frame(for: .timeline))
                XCTAssertEqual(model.systemAudio.values[.reduceLoudSounds], false)
                model.controlsVisible = false
                try await Task.sleep(for: .milliseconds(350))
                XCTAssertNil(model.subtitleLayout.frame(for: .timeline))
            }
            heartbeat.cancel()
            _ = await heartbeat.result
            let after = reads.withLock { $0 }
            XCTAssertEqual(after.total - before.total, 4, "Each reveal must refresh actual system state.")
            let parts = largestGap.components
            return [
                "reveals": 4,
                "preferenceReads": after.total - before.total,
                "mainThreadReads": after.onMain - before.onMain,
                "maxMainActorGapMicroseconds": Int(parts.seconds * 1_000_000 + parts.attoseconds / 1_000_000_000_000)
            ]
        }
    }
}
#endif
