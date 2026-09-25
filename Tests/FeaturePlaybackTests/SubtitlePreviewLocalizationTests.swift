#if canImport(UIKit) && canImport(SwiftUI)
import CoreModels
import Observation
import SwiftUI
import UIKit
import XCTest
@testable import FeaturePlayback

@MainActor
final class SubtitlePreviewLocalizationTests: XCTestCase {
    func testSampleStringsResolveAtTheBoundaryUsingTheRequestedLocale() {
        for identifier in ["en_US", "de_DE", "es_ES", "ja_JP"] {
            let locale = Locale(identifier: identifier)
            for sample in SubtitlePreviewSample.allCases {
                var expected = sample.resource
                expected.locale = locale
                XCTAssertEqual(sample.resolve(locale: locale), String(localized: expected))
                XCTAssertFalse(sample.resolve(locale: locale).isEmpty)
            }
        }
    }

    func testSampleEnglishWordingAndNewlineRemainUnchanged() {
        let english = Locale(identifier: "en")
        XCTAssertEqual(SubtitlePreviewSample.primary.resolve(locale: english),
                       "Keep going. We're almost there.\nThe train leaves at 9:45.")
        XCTAssertEqual(SubtitlePreviewSample.secondary.resolve(locale: english),
                       "This is how a second subtitle appears.")
        XCTAssertEqual(SubtitlePreviewSample.positioned.resolve(locale: english),
                       "A sign placed by the subtitle file")
    }

    func testLocaleChangesReplacePassiveCaptionViewsButStyleEditsDoNot() async throws {
        let state = PreviewLocaleState()
        let host = UIHostingController(rootView: LocaleChangingPreview(state: state))
        host.safeAreaRegions = []
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 960, height: 540))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.frame = window.bounds

        func lines(in view: UIView) -> [SubtitleLineView] {
            if let line = view as? SubtitleLineView { return [line] }
            return view.subviews.flatMap { lines(in: $0) }
        }
        func waitForLines(_ predicate: ([SubtitleLineView]) -> Bool) async throws -> [SubtitleLineView] {
            let deadline = ContinuousClock.now + .seconds(3)
            while ContinuousClock.now < deadline {
                host.view.layoutIfNeeded()
                let current = lines(in: host.view)
                if current.count == 3, current.allSatisfy({ $0.bounds.width > 0 }), predicate(current) { return current }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTFail("Preview caption views did not reflect the requested locale/style update.")
            return lines(in: host.view)
        }

        let original = try await waitForLines { _ in true }
        let originalIDs = Set(original.map(ObjectIdentifier.init))
        let originalWidths = original.map(\.bounds.width)
        state.style.fontScale = 1.25
        let resized = try await waitForLines { $0.map(\.bounds.width) != originalWidths }
        XCTAssertEqual(Set(resized.map(ObjectIdentifier.init)), originalIDs)

        // Translation catalogs are not guaranteed in the package-test host.
        // Even when strings fall back to English, locale identity must refresh
        // the passive renderer because SubtitleCue equality ignores its text.
        state.locale = Locale(identifier: "de_DE")
        let localized = try await waitForLines {
            Set($0.map(ObjectIdentifier.init)).isDisjoint(with: originalIDs)
        }
        XCTAssertEqual(localized.count, 3)
        XCTAssertEqual(state.style.fontScale, 1.25)
    }
}

@MainActor @Observable
private final class PreviewLocaleState {
    var locale = Locale(identifier: "en_US")
    var style: SubtitleStyle = {
        var value = SubtitleStyle.default
        value.fontFamily = .system
        value.secondary = .init()
        return value
    }()
}

@MainActor
private struct LocaleChangingPreview: View {
    let state: PreviewLocaleState

    var body: some View {
        // No decoder or video lifecycle is needed to test the caption boundary.
        SubtitleStylePreviewCanvas(
            style: state.style, secondaryVisible: true,
            referenceSize: SubtitleStylePreviewMetrics.televisionCanvas,
            showsFileFormatting: true, animate: false
        )
        .environment(\.locale, state.locale)
    }
}
#endif
