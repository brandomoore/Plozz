#if os(tvOS) && DEBUG
import CoreModels
import CoreUI
@testable import FeaturePlayback
import SwiftUI
import UIKit
import XCTest

@MainActor
final class PlayerControlsClockPerformanceTests: XCTestCase {
    func testPerformanceHiddenClock() async throws {
        try await measure(visible: false, advancing: true, scenario: "player-controls-hidden-clock")
    }

    func testPerformanceHiddenStatic() async throws {
        try await measure(visible: false, advancing: false, scenario: "player-controls-hidden-static")
    }

    func testPerformanceVisibleClock() async throws {
        try await measure(visible: true, advancing: true, scenario: "player-controls-visible-clock")
    }

    private func measure(visible: Bool, advancing: Bool, scenario: String) async throws {
        try PerformanceProbe.requireEnabled()
        let audio = SystemPlaybackAudio(backend: SystemPlaybackAudioPreferences(readState: {
            .init(values: [.reduceLoudSounds: false, .enhanceDialogue: false])
        }))
        let model = PlayerControlsModel(systemAudio: audio)
        model.title = "Playback clock workload"
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
        model.controlsVisible = true
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertNotNil(model.subtitleLayout.frame(for: .timeline))
        model.controlsVisible = visible
        try await Task.sleep(for: .milliseconds(500))
        try await PerformanceProbe.measure(self, scenario: scenario) {
            let start = model.currentSeconds
            for tick in 1...32 {
                if advancing {
                    model.currentSeconds = start + Double(tick) * 0.25
                    model.bufferedSeconds = model.currentSeconds + 40
                }
                try await Task.sleep(for: .milliseconds(250))
            }
            XCTAssertEqual(model.currentSeconds, start + (advancing ? 8 : 0))
            XCTAssertEqual(model.bufferedSeconds, model.currentSeconds + 40)
            XCTAssertEqual(model.subtitleLayout.frame(for: .timeline) != nil, visible)
            return [
                "ticks": 32,
                "clockUpdates": advancing ? 32 : 0,
                "controlsVisible": visible ? 1 : 0,
                "observationMilliseconds": 8_000
            ]
        }
    }
}
#endif
