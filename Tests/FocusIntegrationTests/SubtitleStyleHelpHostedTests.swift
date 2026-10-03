import CoreModels
@testable import CoreUI
@testable import FeaturePlayback
import Observation
import SwiftUI
import UIKit
import Vision
import XCTest

@MainActor
final class SubtitleStyleHelpHostedTests: XCTestCase {
    func testBurnedInSubtitleMenuHidesStyleButKeepsDualSelectionReachable() async throws {
        try await waitUntil {
            UIApplication.shared.connectedScenes.contains { $0.activationState == .foregroundActive }
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let model = BurnedSubtitleMenuModel()
        model.controls.primarySubtitleIsBurnedIn = true
        model.controls.subtitleOptions = [
            .init(id: PlayerTrackOption.offID, title: Text("Off"), isSelected: false),
            .init(id: 3, title: Text("English ASS"), isSelected: true)
        ]
        model.setSecondary(false)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        window.rootViewController = UIHostingController(rootView: BurnedSubtitleMenuFixture(model: model))
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        try await waitUntil { self.focusFrame(in: window) != nil }
        try await Task.sleep(for: .milliseconds(300))
        func labels() throws -> [String] {
            window.layoutIfNeeded()
            return try recognize(window).compactMap { $0.topCandidates(1).first?.string }
        }
        let text = try labels()
        XCTAssertTrue(text.contains("Dual Subtitles"), "\(text)")
        XCTAssertFalse(text.contains("Style"), "\(text)")

        model.screen = .styleDual
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(try labels().contains("Second Track"))
        model.setSecondary(true)
        model.screen = .tracks
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(try labels().contains("Style"))

        model.screen = .styleFont
        try await Task.sleep(for: .milliseconds(100))
        model.setSecondary(false)
        try await waitUntil { model.screen == .tracks }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(try labels().contains("Style"))

        model.controls.primarySubtitleIsBurnedIn = false
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(try labels().contains("Style"))
    }

    func testSystemStyleLabelExplainsTheDeviceWithoutAChangingHelperRow() async throws {
        try await waitUntil {
            UIApplication.shared.connectedScenes.contains { $0.activationState == .foregroundActive }
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let model = SubtitleHelpFocusFixtureModel()
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        window.rootViewController = UIHostingController(rootView: SubtitleHelpFocusFixture(model: model))
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        try await waitUntil { model.focused == 0 && self.focusFrame(in: window) != nil }
        try await Task.sleep(for: .milliseconds(300))
        var observations = try recognize(window)
        let toggle = try XCTUnwrap(observations.first {
            $0.topCandidates(1).first?.string.contains("Match Apple TV Subtitle Style") == true
        })
        XCTAssertFalse(observations.contains {
            $0.topCandidates(1).first?.string.contains("Matches the subtitle style") == true
        })
        let firstFont = try XCTUnwrap(observations.first { $0.topCandidates(1).first?.string == "Font" })
        XCTAssertLessThan(firstFont.boundingBox.maxY, toggle.boundingBox.minY)

        model.requested = 1
        try await waitUntil { model.focused == 1 }
        try await Task.sleep(for: .milliseconds(300))
        window.layoutIfNeeded()
        observations = try recognize(window)
        XCTAssertFalse(observations.contains {
            $0.topCandidates(1).first?.string.contains("Matches the subtitle style") == true
        })
        let font = try XCTUnwrap(observations.first { $0.topCandidates(1).first?.string == "Font" })
        XCTAssertEqual(font.boundingBox.midY, firstFont.boundingBox.midY, accuracy: 0.002,
                       "Font must stay in place when focus leaves the matching option: \(firstFont.boundingBox) -> \(font.boundingBox)")
        let center = CGPoint(x: font.boundingBox.midX * window.bounds.width,
                             y: (1 - font.boundingBox.midY) * window.bounds.height)
        XCTAssertTrue(try XCTUnwrap(focusFrame(in: window)).contains(center))
    }

    private func recognize(_ window: UIWindow) throws -> [VNRecognizedTextObservation] {
        let image = DetailTransitionSnapshot.image(of: window)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
        return request.results ?? []
    }

    private func focusFrame(in window: UIWindow) -> CGRect? {
        guard let item = UIFocusSystem(for: window)?.focusedItem else { return nil }
        var environment: (any UIFocusEnvironment)? = item
        while let current = environment {
            if let container = current.focusItemContainer {
                return container.coordinateSpace.convert(item.frame, to: window)
            }
            environment = current.parentFocusEnvironment
        }
        return nil
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition())
    }
}

@MainActor @Observable
private final class BurnedSubtitleMenuModel {
    let controls = PlayerControlsModel()
    var screen = PlayerControls.SubtitleScreen.tracks
    var heights: [PlayerControls.Category: CGFloat] = [:]

    func setSecondary(_ enabled: Bool) {
        controls.secondarySubtitleOptions = [
            .init(id: PlayerTrackOption.offID, title: Text("Off"), isSelected: !enabled),
            .init(id: 4, title: Text("Signs"), isSelected: enabled)
        ]
    }
}

private struct BurnedSubtitleMenuFixture: View {
    let model: BurnedSubtitleMenuModel
    @FocusState private var focus: PlayerControls.FocusSlot?

    var body: some View {
        PlayerOptionsPanel(
            category: .subtitles, model: model.controls, palette: .dark, actions: .init(),
            subtitleScreen: Binding(get: { model.screen }, set: { model.screen = $0 }),
            heightCache: Binding(get: { model.heights }, set: { model.heights = $0 }),
            focus: $focus, close: {}, backRequest: 0, maximumHeight: 850
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
        .environment(\.locale, Locale(identifier: "en_US"))
        .onChange(of: model.screen, initial: true) { _, screen in
            focus = PlayerOptionsPanel.preferredFocus(for: .subtitles, subtitleScreen: screen, model: model.controls)
        }
    }
}

@MainActor @Observable
private final class SubtitleHelpFocusFixtureModel {
    let controls = PlayerControlsModel()
    var requested = 0
    var focused: Int?
}

private struct SubtitleHelpFocusFixture: View {
    let model: SubtitleHelpFocusFixtureModel
    @FocusState private var focus: PlayerControls.FocusSlot?

    var body: some View {
        ScrollView {
            SubtitleStylePanel(
                screen: .style, model: model.controls, palette: .dark,
                actions: PlayerOptionsActions(), focus: $focus, openScreen: { _ in }
            )
        }
        .frame(width: SubtitleStylePanel.panelWidth, height: 850)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
        .environment(\.themePalette, .dark)
        .environment(\.colorScheme, .dark)
        .onChange(of: model.requested, initial: true) { _, row in focus = .row(row) }
        .onChange(of: focus) { _, value in
            if case .row(let row)? = value { model.focused = row }
            else { model.focused = nil }
        }
    }
}
