import CoreModels
@testable import CoreUI
@testable import FeaturePlayback
import Observation
import SwiftUI
import UIKit
import Vision
import XCTest

@MainActor
final class SubtitleSystemFontHostedTests: XCTestCase {
    func testSystemSubmenuAndSelectedCaptionFontReceiveVisibleNativeFocus() async throws {
        try await waitUntil {
            UIApplication.shared.connectedScenes.contains { $0.activationState == .foregroundActive }
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let state = SubtitleFontFixtureState()
        state.model.subtitleStyle.systemFont = .caption(.smallCapitals)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        window.rootViewController = UIHostingController(rootView: SubtitleFontFixture(state: state))
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        XCTAssertEqual(PlayerControls.SubtitleScreen.styleSystemFont.parent, .styleFont)
        XCTAssertTrue(PlayerControls.SubtitleScreen.styleSystemFont.isStyleFamily)
        for (screen, title) in [(PlayerControls.SubtitleScreen.styleFont, "System"),
                                (.styleSystemFont, "Small Capitals")] {
            state.screen = screen
            try await waitUntil {
                guard let frame = self.focusFrame(in: window) else { return false }
                return state.focusedRow == state.requestedRow && frame.width > 500
                    && window.bounds.contains(frame)
            }
            let image = DetailTransitionSnapshot.image(of: window)
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["en-US"]
            try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
            let matches = (request.results ?? []).filter {
                $0.topCandidates(1).first?.string.localizedCaseInsensitiveContains(title) == true
            }
            let focused = try XCTUnwrap(focusFrame(in: window))
            XCTAssertTrue(matches.contains { match in
                let text = match.boundingBox
                let center = CGPoint(x: text.midX * window.bounds.width, y: (1 - text.midY) * window.bounds.height)
                return focused.contains(center)
            },
                          "The actual focused row must display \(title).")
            let attachment = XCTAttachment(image: image)
            attachment.name = "Subtitle font - \(title)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
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
        XCTAssertTrue(condition(), "The caption font row must receive native focus.")
    }
}

@MainActor @Observable
private final class SubtitleFontFixtureState {
    let model = PlayerControlsModel()
    var screen = PlayerControls.SubtitleScreen.styleFont
    var focusedRow: Int?
    var requestedRow: Int {
        screen == .styleFont ? SubtitleFontFamily.allCases.count
            : SubtitleSystemFonts.all.firstIndex { $0.id == model.subtitleStyle.systemFont } ?? 0
    }
}

private struct SubtitleFontFixture: View {
    let state: SubtitleFontFixtureState
    @FocusState private var focus: PlayerControls.FocusSlot?

    var body: some View {
        ScrollView {
            SubtitleStylePanel(
                screen: state.screen, model: state.model, palette: .dark,
                actions: PlayerOptionsActions(), focus: $focus,
                openScreen: { state.screen = $0 }
            )
        }
        .frame(width: 760, height: 720)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
        .environment(\.themePalette, .dark)
        .environment(\.colorScheme, .dark)
        .task(id: state.screen) {
            focus = nil
            await Task.yield()
            focus = .row(state.requestedRow)
        }
        .onChange(of: focus) { _, value in
            if case .row(let index)? = value { state.focusedRow = index }
            else { state.focusedRow = nil }
        }
    }
}
