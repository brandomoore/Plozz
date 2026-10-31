import CoreModels
import CoreUI
@testable import FeaturePlayback
import SwiftUI
import UIKit
import Vision
import XCTest

@MainActor
final class PlayerControlsRenderingHostedTests: XCTestCase {
    func testRemoteScanLevelRendersOnTheDirectionSideOfTheTimestamp() async throws {
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
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        let model = PlayerControlsModel()
        model.controlsVisible = true
        model.duration = 3600
        model.isScrubbing = true
        model.scrubSeconds = 600
        window.rootViewController = UIHostingController(rootView:
            PlayerTimelineTimes(model: model)
                .frame(width: 1400, height: 60)
                .environment(\.locale, Locale(identifier: "en_US"))
                .background(.black)
        )
        window.makeKeyAndVisible()
        for level in [-2, 2] {
            model.skipGesture.scanLevel = level
            // Accurate OCR can discard a standalone level beside the circle glyph.
            let image = try await captureTimeline(
                in: window, matching: level < 0 ? "2.*10:00" : "10:00.*2", recognitionLevel: .fast
            )
            let attachment = XCTAttachment(image: image)
            attachment.name = level < 0 ? "Rewind level 2 left of timestamp" : "Forward level 2 right of timestamp"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        model.scrubSeconds = 0
        model.skipGesture.scanLevel = -8
        _ = try await captureTimeline(in: window, matching: "8.*0:00")
        model.scrubSeconds = 3600
        model.skipGesture.scanLevel = 8
        _ = try await captureTimeline(in: window, matching: "1:00:00.*8")
    }

    func testOutgoingTimelineKeepsClockLabelsUntilNextReveal() async throws {
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
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        let model = PlayerControlsModel()
        model.controlsVisible = true
        model.duration = 3_600
        model.currentSeconds = 600
        window.rootViewController = UIHostingController(rootView:
            // Inspect the production labels without the parent's fading opacity,
            // so changing them under an outgoing fade cannot escape detection.
            PlayerTimelineTimes(model: model)
                .frame(width: 1400, height: 60)
                .foregroundStyle(.white)
                .environment(\.locale, Locale(identifier: "en_US"))
                .environment(\.timeZone, .gmt)
                .background(.black)
        )
        window.makeKeyAndVisible()
        _ = try await captureTimeline(in: window, matching: "10:00.*50:00")
        model.timelineClock.isEnabled = true
        let clockPattern = #"\d{1,2}:\d{2}\s*(AM|PM).*\d{1,2}:\d{2}\s*(AM|PM)"#
        _ = try await captureTimeline(in: window, matching: clockPattern)
        model.controlsVisible = false
        let outgoing = try await captureTimeline(in: window, matching: clockPattern)
        let attachment = XCTAttachment(image: outgoing)
        attachment.name = "Outgoing timeline preserves clock labels"
        attachment.lifetime = .keepAlways
        add(attachment)
        model.controlsVisible = true
        _ = try await captureTimeline(in: window, matching: "10:00.*50:00")
    }

    func testClockUpdatesAndRepeatedCardRevealsPreserveBothNativeMaterials() async throws {
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
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }

        for performance in [false, true] {
            let model = PlayerControlsModel()
            model.controlsVisible = true
            model.duration = 3_600
            model.currentSeconds = 600
            model.bufferedSeconds = 800
            model.title = "Rendering fixture"
            model.subtitle = "Season 1, Episode 2"
            model.infoCard.headline = "Episode two"
            model.infoCard.overview = "A stable, local fixture for the production controls."
            model.engineCapabilities = [.playbackSpeed]
            window.rootViewController = UIHostingController(rootView:
                PlayerControls(
                    model: model, palette: .dark, actions: PlayerOptionsActions(), onExitToSurface: {}
                )
                .environment(\.plozzReducePanelGlass, performance)
                .environment(\.colorScheme, .dark)
                .environment(\.locale, Locale(identifier: "en_US"))
                .environment(\.timeZone, .gmt)
                .background(Color(red: 0.08, green: 0.12, blue: 0.18))
            )
            window.makeKeyAndVisible()
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(800))
            let initial = try XCTUnwrap(model.subtitleLayout.frame(for: .timeline))
            _ = try await captureTimeline(in: window, matching: "10:00.*50:00")

            for _ in 0..<20 {
                model.currentSeconds += 0.25
                model.bufferedSeconds += 0.25
                try await Task.sleep(for: .milliseconds(25))
            }
            XCTAssertEqual(model.subtitleLayout.frame(for: .timeline), initial)

            model.timelineClock.isEnabled = true
            let clockPattern = #"\d{1,2}:\d{2}\s*(AM|PM).*\d{1,2}:\d{2}\s*(AM|PM)"#
            let initialClockImage = try await captureTimeline(in: window, matching: clockPattern)
            let clockLabels = try recognizedTimelineText(in: initialClockImage)
                .filter { $0.topCandidates(1).first?.string.range(of: #"\d+:\d{2}"#, options: .regularExpression) != nil }
                .sorted { $0.boundingBox.minX < $1.boundingBox.minX }
            XCTAssertEqual(clockLabels.count, 2, "Clock values must replace the existing two timeline numbers.")
            let currentClock = try XCTUnwrap(clockLabels.first).boundingBox
            let endClock = try XCTUnwrap(clockLabels.last).boundingBox
            let knobX = initial.minX + initial.width * CGFloat(model.progressFraction)
            XCTAssertEqual(currentClock.midX * window.bounds.width, knobX, accuracy: 8,
                           "The current clock must stay under the scrubber instead of moving to the left edge.")
            XCTAssertEqual(endClock.maxX * window.bounds.width, initial.maxX, accuracy: 8,
                           "The finish clock must replace the trailing remaining-time label.")
            XCTAssertEqual(model.subtitleLayout.frame(for: .timeline), initial,
                           "Clock mode must reuse the existing timeline without adding a row.")
            model.isScrubbing = true
            model.scrubSeconds = 1_200
            _ = try await captureTimeline(in: window, matching: "20:00")
            XCTAssertEqual(model.subtitleLayout.frame(for: .timeline), initial,
                           "Returning to media timestamps while seeking must preserve timeline bounds.")
            model.isScrubbing = false
            let clockImage = try await captureTimeline(in: window, matching: clockPattern)
            let clockAttachment = XCTAttachment(image: clockImage)
            clockAttachment.name = "On-demand clock - \(performance ? "flat" : "glass")"
            clockAttachment.lifetime = .keepAlways
            add(clockAttachment)

            for _ in 0..<3 {
                model.controlBar.entry = .info
                model.controlBar.focusArmed = false
                model.controlBar.settled = false
                model.controlBarVisible = true
                try await Task.sleep(for: .milliseconds(650))
                XCTAssertTrue(model.controlBar.focusArmed)
                model.controlBar.settled = true
                XCTAssertTrue(model.controlBar.infoCardOpen)
                let card = try XCTUnwrap(model.subtitleLayout.frame(for: .card))
                XCTAssertGreaterThan(card.minY, 0)
                XCTAssertLessThanOrEqual(card.maxY, window.bounds.maxY + 1)
                model.controlBarVisible = false
                try await Task.sleep(for: .milliseconds(650))
                XCTAssertFalse(model.controlBar.infoCardOpen)
                let restored = try XCTUnwrap(model.subtitleLayout.frame(for: .timeline))
                XCTAssertEqual(restored.minX, initial.minX, accuracy: 1)
                XCTAssertEqual(restored.minY, initial.minY, accuracy: 1)
                XCTAssertEqual(restored.width, initial.width, accuracy: 1)
                XCTAssertEqual(restored.height, initial.height, accuracy: 1)
            }

            let driver = InfoFocusDriver()
            model.infoCard.hasPreviousEpisode = true
            model.infoCard.hasNextEpisode = true
            window.rootViewController = UIHostingController(rootView:
                InfoFocusFixture(model: model, driver: driver)
                    .frame(width: 1600)
                    .environment(\.plozzReducePanelGlass, performance)
                    .environment(\.colorScheme, .dark)
                    .background(Color(red: 0.08, green: 0.12, blue: 0.18))
            )
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(500))
            for _ in 0..<3 {
                for target in [PlayerControls.FocusSlot.infoNext, .infoPrev, .infoRestart, .infoStats] {
                    let previousFocus = UIFocusSystem.focusSystem(for: window)?.focusedItem
                    try XCTUnwrap(driver.requestFocus)(target)
                    try await Task.sleep(for: .milliseconds(250))
                    let currentFocus = try XCTUnwrap(UIFocusSystem.focusSystem(for: window)?.focusedItem)
                    XCTAssertFalse(currentFocus === previousFocus, "Native focus must move to the requested action.")
                }
            }
            NotificationCenter.default.post(name: .metadataProviderSettingsDidChange, object: nil)
            try await Task.sleep(for: .milliseconds(100))
        }
    }
}

@MainActor
private final class InfoFocusDriver {
    var requestFocus: ((PlayerControls.FocusSlot) -> Void)?
}

@MainActor
private func captureTimeline(
    in window: UIWindow, matching expected: String,
    recognitionLevel: VNRequestTextRecognitionLevel = .accurate
) async throws -> UIImage {
    let deadline = ContinuousClock.now + .seconds(4)
    var rendered = UIImage()
    var text = ""
    repeat {
        try await Task.sleep(for: .milliseconds(100))
        window.layoutIfNeeded()
        rendered = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        text = try recognizedTimelineText(in: rendered, recognitionLevel: recognitionLevel)
            .compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
        if text.range(of: expected, options: .regularExpression) != nil { return rendered }
    } while ContinuousClock.now < deadline
    XCTFail("Timeline did not render \(expected): \(text)")
    return rendered
}

private func recognizedTimelineText(
    in image: UIImage, recognitionLevel: VNRequestTextRecognitionLevel = .accurate
) throws -> [VNRecognizedTextObservation] {
    let recognition = VNRecognizeTextRequest()
    recognition.recognitionLevel = recognitionLevel
    recognition.recognitionLanguages = ["en-US"]
    if recognitionLevel == .fast {
        recognition.minimumTextHeight = 0.005
        recognition.usesLanguageCorrection = false
    }
    try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([recognition])
    return recognition.results ?? []
}

private struct InfoFocusFixture: View {
    let model: PlayerControlsModel
    let driver: InfoFocusDriver
    @FocusState private var focus: PlayerControls.FocusSlot?

    var body: some View {
        InfoPanelView(model: model, actions: PlayerOptionsActions(), focus: $focus, onClose: {})
            .onAppear {
                driver.requestFocus = { focus = $0 }
                focus = .infoRestart
            }
            .onDisappear { driver.requestFocus = nil }
    }
}
