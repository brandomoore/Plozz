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
    func testSystemStyleHelpSitsBelowItsToggleAndHidesWhenFocusMoves() async throws {
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
        var observations = try recognize(window)
        let toggle = try XCTUnwrap(observations.first {
            $0.topCandidates(1).first?.string.contains("Use System Caption Style") == true
        })
        let help = try XCTUnwrap(observations.first {
            $0.topCandidates(1).first?.string.contains("Matching shows") == true
        })
        XCTAssertLessThan(help.boundingBox.maxY, toggle.boundingBox.minY)
        XCTAssertLessThan(toggle.boundingBox.minY - help.boundingBox.maxY, 0.08)

        model.requested = 1
        try await waitUntil { model.focused == 1 }
        await Task.yield()
        window.layoutIfNeeded()
        observations = try recognize(window)
        XCTAssertFalse(observations.contains {
            $0.topCandidates(1).first?.string.contains("Matching shows") == true
        })
        let font = try XCTUnwrap(observations.first { $0.topCandidates(1).first?.string == "Font" })
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
