import CoreModels
import CoreUI
@testable import FeaturePlayback
import SwiftUI
import UIKit
import Vision
import XCTest

@MainActor
final class PlayerChapterHostedTests: XCTestCase {
    func testArtworkCardsHaveEvenInsetsAndConcentricCorners() async throws {
        try await waitUntil {
            UIApplication.shared.connectedScenes.contains { $0.activationState == .foregroundActive }
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
        let metrics = PlayerCardMetrics.tv
        let inset = InfoPanelView.contentPadding
        let layout = PlayerMediaArtworkLayout(
            height: metrics.cardHeight, inset: inset, cornerRadius: metrics.panelCornerRadius
        )
        let probe = ChapterArtworkProbe()
        window.rootViewController = UIHostingController(rootView:
            layout {
                LinearGradient(colors: [.cyan, .blue], startPoint: .topLeading, endPoint: .bottomTrailing)
                    .clipShape(layout.thumbnailShape)
                    .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { probe.artwork = $0 }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Chapter 12").font(metrics.castNameFont)
                    Text("1:21:50").font(metrics.captionFont).monospacedDigit()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { probe.caption = $0 }
            }
            .background(PlayerOverVideoSurface(cornerRadius: metrics.panelCornerRadius, mediaGlass: true))
            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { probe.card = $0 }
            .environment(\.colorScheme, .dark)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.black)
        )
        window.makeKeyAndVisible()
        try await waitUntil { probe.caption.height > 0 }
        XCTAssertEqual(probe.card.height, metrics.cardHeight, accuracy: 0.5)
        XCTAssertEqual(probe.artwork.minX - probe.card.minX, inset, accuracy: 0.5)
        XCTAssertEqual(probe.artwork.minY - probe.card.minY, inset, accuracy: 0.5)
        XCTAssertEqual(probe.card.maxX - probe.artwork.maxX, inset, accuracy: 0.5)
        XCTAssertEqual(probe.card.maxY - probe.caption.maxY, metrics.panelCornerRadius, accuracy: 0.5)
        XCTAssertEqual(probe.caption.minX, probe.artwork.minX, accuracy: 0.5)
        XCTAssertEqual(probe.caption.minY - probe.artwork.maxY, 8, accuracy: 0.5)
        XCTAssertEqual(probe.artwork.width / probe.artwork.height, 16.0 / 9.0, accuracy: 0.005)
        let radius = layout.thumbnailShape.cornerSize.width
        XCTAssertEqual(probe.artwork.minX + radius, probe.card.minX + metrics.panelCornerRadius, accuracy: 0.5)
        XCTAssertEqual(probe.artwork.minY + radius, probe.card.minY + metrics.panelCornerRadius, accuracy: 0.5)
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "TV chapter artwork with even padding and concentric corners"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testChapterCardsRenderAndNativeFocusSurvivesPlayheadUpdates() async throws {
        try await waitUntil {
            UIApplication.shared.connectedScenes.contains { $0.activationState == .foregroundActive }
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

        for (reducedGlass, hasArtwork) in [(false, false), (true, false), (false, true), (true, true)] {
            let model = PlayerControlsModel()
            model.duration = 3_600
            model.currentSeconds = 100
            model.infoCard.chapters = [
                .init(start: 0, title: "Opening"),
                .init(start: 180, title: "The journey"),
                .init(start: 360, imageURL: hasArtwork ? URL(string: "https://chapters.invalid/still.jpg") : nil)
            ] + (3..<20).map { MediaChapter(start: Double($0) * 180) }
            let driver = ChapterFocusDriver()
            window.rootViewController = UIHostingController(rootView:
                ChapterFocusFixture(model: model, driver: driver)
                    .frame(width: 1600)
                    .environment(\.plozzReducePanelGlass, reducedGlass)
                    .environment(\.colorScheme, .dark)
                    .environment(\.locale, Locale(identifier: "en_US"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.black)
            )
            window.makeKeyAndVisible()
            try await waitUntil { driver.requestFocus != nil }
            for target in [PlayerControls.FocusSlot.chapter(0), .chapter(180), .button(.chapters)] {
                let before = UIFocusSystem.focusSystem(for: window)?.focusedItem
                driver.requestFocus?(target)
                try await waitUntil {
                    guard let focused = UIFocusSystem.focusSystem(for: window)?.focusedItem else { return false }
                    return focused !== before && driver.observedFocus == target
                }
            }
            driver.requestFocus?(.chapter(180))
            try await waitUntil { driver.observedFocus == .chapter(180) }
            let focused = try XCTUnwrap(UIFocusSystem.focusSystem(for: window)?.focusedItem)
            XCTAssertGreaterThanOrEqual(focused.frame.height, PlayerCardMetrics.tv.cardHeight - 1,
                                        "Every horizontal chapter card must fill the shared player stage.")
            XCTAssertLessThanOrEqual(focused.frame.height, PlayerCardMetrics.tv.cardHeight * 1.10 + 1)
            if !hasArtwork {
                XCTAssertGreaterThanOrEqual(focused.frame.width, PlayerCardMetrics.tv.castCardWidth - 1)
                XCTAssertLessThanOrEqual(focused.frame.width, PlayerCardMetrics.tv.castCardWidth * 1.10 + 1,
                                        "Text-only cards must use Cast's narrow width, not reserve thumbnail space.")
            }
            for time in [179.9, 180, 359.9, 360] {
                model.currentSeconds = time
                try await Task.sleep(for: .milliseconds(50))
                XCTAssertTrue(UIFocusSystem.focusSystem(for: window)?.focusedItem === focused)
            }
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let recognition = VNRecognizeTextRequest()
            recognition.recognitionLevel = .accurate
            recognition.recognitionLanguages = ["en-US"]
            try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([recognition])
            let text = (recognition.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
            for expected in ["Opening", "The journey", "Chapter 3", "3:00", "6:00"] {
                XCTAssertTrue(text.localizedCaseInsensitiveContains(expected), "Missing chapter content: \(text)")
            }
            let timeBox = try XCTUnwrap(recognition.results?.first {
                $0.topCandidates(1).first?.string.contains("0:00") == true
            }?.boundingBox)
            let inset = max(PlayerCardMetrics.tv.contentPadding, PlayerCardMetrics.tv.panelCornerRadius / 2)
            XCTAssertGreaterThanOrEqual(timeBox.minX * window.bounds.width - driver.panelFrame.minX, inset - 2)
            if hasArtwork {
                XCTAssertGreaterThanOrEqual(
                    driver.panelFrame.maxY - (1 - timeBox.minY) * window.bounds.height, inset - 2,
                    "Chapter time must clear the rounded bottom corner, including while another card is focused."
                )
            } else {
                let titleBox = try XCTUnwrap(recognition.results?.first {
                    $0.topCandidates(1).first?.string == "Opening"
                }?.boundingBox)
                let captionTop = (1 - titleBox.maxY) * window.bounds.height
                let captionBottom = (1 - timeBox.minY) * window.bounds.height
                XCTAssertEqual((captionTop + captionBottom) / 2, driver.panelFrame.midY, accuracy: 4,
                               "Text-only captions must be centered in the full-height horizontal card.")
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = "Chapter cards \(hasArtwork ? "mixed" : "text") - \(reducedGlass ? "reduced" : "native glass")"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(condition())
    }
}

@MainActor
private final class ChapterFocusDriver {
    var requestFocus: ((PlayerControls.FocusSlot) -> Void)?
    var observedFocus: PlayerControls.FocusSlot?
    var panelFrame: CGRect = .zero
}

@MainActor
private final class ChapterArtworkProbe {
    var card: CGRect = .zero
    var artwork: CGRect = .zero
    var caption: CGRect = .zero
}

private struct ChapterFocusFixture: View {
    let model: PlayerControlsModel
    let driver: ChapterFocusDriver
    @FocusState private var focus: PlayerControls.FocusSlot?

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Button("Chapters") {}
                .focused($focus, equals: .button(.chapters))
                .frame(maxWidth: .infinity, alignment: .leading)
                .focusSection()
            PlayerChapterPanel(model: model, spoilerSettings: .default, focus: $focus) { _ in }
                .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { driver.panelFrame = $0 }
        }
        .onAppear {
            driver.requestFocus = { focus = $0 }
            focus = .button(.chapters)
        }
        .onChange(of: focus) { _, value in driver.observedFocus = value }
        .onDisappear { driver.requestFocus = nil }
    }
}
