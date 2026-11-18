#if canImport(UIKit)
import CoreUI
import SwiftUI
import UIKit
import XCTest

@MainActor
final class PlayResumeButtonLabelTests: XCTestCase {
    private func size(of view: some View) -> CGSize {
        let host = UIHostingController(rootView: view)
        return host.sizeThatFits(in: CGSize(width: 2_000, height: 200))
    }

    func testPlaceholderIsCompactWithoutConstrainingReadyButtons() {
        for fontSize in [CGFloat(17), 30] {
            for style in [
                PlayResumeButtonLabel.ResumeTrailingStyle.full,
                .seasonEpisodeOnly,
                .hidden
            ] {
                func label(pending: Bool, progress: Double?) -> some View {
                    PlayResumeButtonLabel(
                        title: "Play",
                        progress: progress,
                        remainingText: progress == nil ? nil : "35m",
                        seasonEpisodeText: pending ? nil : "S4 E1",
                        onLight: true,
                        spacing: fontSize == 17 ? 10 : 16,
                        capsuleWidth: fontSize == 17 ? 60 : 75,
                        resumeTrailingStyle: style,
                        isPlaceholder: pending
                    )
                    .font(.system(size: fontSize))
                }
                let placeholder = size(of: label(pending: true, progress: nil))
                let plain = size(of: label(pending: false, progress: nil))
                let resume = size(of: label(pending: false, progress: 0.3))
                XCTAssertGreaterThan(placeholder.width, 0)
                XCTAssertGreaterThan(placeholder.height, 0)
                XCTAssertLessThanOrEqual(placeholder.width, plain.width * 1.15)
                if style == .full {
                    XCTAssertLessThan(placeholder.width, resume.width)
                }
                XCTAssertEqual(placeholder.height, plain.height, accuracy: 0.5)
                XCTAssertEqual(placeholder.height, resume.height, accuracy: 0.5)
            }
        }
    }

    func testStartWatchingUsesTheSeparatedEpisodeLabelAtItsNaturalWidth() {
        let label = PlayResumeButtonLabel(
            title: "Start watching", progress: nil, remainingText: nil,
            seasonEpisodeText: "S1 E1", onLight: true, separatesEpisodeText: true
        )
        let expected = HStack(spacing: 16) {
            Image(systemName: "play.fill")
            Text("Start watching · S1 E1")
        }
        XCTAssertEqual(
            size(of: label.font(.system(size: 30))).width,
            size(of: expected.font(.system(size: 30))).width,
            accuracy: 0.5
        )
    }

    func testReadyResumeLabelHasNoHiddenPlaceholderWidth() {
        let label = PlayResumeButtonLabel(
            title: "Play", progress: 0.3, remainingText: "35m",
            seasonEpisodeText: "S4 E1", onLight: true
        )
        let expected = HStack(spacing: 16) {
            Image(systemName: "play.fill")
            ResumeProgressCapsule(progress: 0.3, onLight: true, width: 75)
            Text("S4 E1 • 35m")
        }
        XCTAssertEqual(
            size(of: label.font(.system(size: 30))).width,
            size(of: expected.font(.system(size: 30))).width,
            accuracy: 0.5
        )
    }

    func testExistingPlainButtonsKeepTheirCompactSizeByDefault() {
        let label = PlayResumeButtonLabel(
            title: "Play", progress: nil, remainingText: nil, onLight: true
        )
        let original = HStack(spacing: 16) {
            Image(systemName: "play.fill")
            Text("Play")
        }
        let actual = size(of: label.font(.system(size: 30)))
        let expected = size(of: original.font(.system(size: 30)))
        XCTAssertEqual(actual.width, expected.width, accuracy: 0.5)
        XCTAssertEqual(actual.height, expected.height, accuracy: 0.5)
    }

    func testResumeTextCanWrapInTheVerticalActionFallback() {
        let label = PlayResumeButtonLabel(
            title: "Play", progress: 0.64, remainingText: "1h 43m",
            seasonEpisodeText: "S20 E100", onLight: true, wrapsText: true
        )
        .font(.system(size: 34))
        let host = UIHostingController(rootView: label)
        let wide = host.sizeThatFits(in: CGSize(width: 2_000, height: 500))
        let narrow = host.sizeThatFits(in: CGSize(width: 200, height: 500))
        XCTAssertLessThanOrEqual(narrow.width, 200)
        XCTAssertGreaterThan(narrow.height, wide.height)
    }
}
#endif
