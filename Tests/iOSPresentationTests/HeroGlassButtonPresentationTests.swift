#if os(iOS)
import CoreModels
import CoreUI
import SwiftUI
import UIKit
import Vision
import XCTest
@testable import AppShelliOS

@MainActor
final class HeroGlassButtonPresentationTests: XCTestCase {
    func testRequestLoadingPreservesButtonSizeAndUsesTextSizedSpinner() async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !UIApplication.shared.connectedScenes.contains(where: { $0.activationState == .foregroundActive }),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let item = MediaItem(id: "request-loading", title: "Movie", kind: .movie)
        for scheme in [ColorScheme.dark, .light] {
            for reduced in [false, true] {
                for typeSize in [DynamicTypeSize.large, .accessibility3] {
                    func button(loading: Bool) -> some View {
                        PlozziOSHeroRequestButton(item: item, request: .init(
                            cta: .request, isRequesting: loading, onRequest: { _ in }
                        ))
                        .environment(\.themePalette, scheme == .dark ? .dark : .light)
                        .environment(\.colorScheme, scheme)
                        .environment(\.dynamicTypeSize, typeSize)
                        .environment(\.plozzReduceTransparency, reduced)
                    }
                    for width in [CGFloat(276), 720] {
                        let idle = measure(button(loading: false), width: width)
                        let loading = measure(button(loading: true), width: width)
                        XCTAssertEqual(loading.width, idle.width, accuracy: 0.5)
                        XCTAssertEqual(loading.height, idle.height, accuracy: 0.5)
                    }
                    let window = UIWindow(windowScene: scene)
                    window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
                    window.overrideUserInterfaceStyle = scheme == .dark ? .dark : .light
                    window.rootViewController = UIHostingController(rootView: button(loading: true))
                    window.makeKeyAndVisible()
                    defer {
                        window.isHidden = true
                        window.rootViewController = nil
                        previous?.makeKeyAndVisible()
                    }
                    window.layoutIfNeeded()
                    try await Task.sleep(for: .milliseconds(150))
                    let indicators = activityIndicators(in: window).filter { $0.window != nil && !$0.isHidden }
                    XCTAssertEqual(indicators.count, 1)
                    let indicator = try XCTUnwrap(indicators.first)
                    XCTAssertTrue(indicator.isAnimating)
                    let traits = UITraitCollection(preferredContentSizeCategory:
                        typeSize == .large ? .large : .accessibilityExtraLarge)
                    let textHeight = UIFont.preferredFont(forTextStyle: .headline, compatibleWith: traits).lineHeight
                    XCTAssertLessThanOrEqual(indicator.bounds.width, textHeight)
                    XCTAssertLessThanOrEqual(indicator.bounds.height, textHeight)
                    let color = try XCTUnwrap(indicator.color).resolvedColor(with: indicator.traitCollection)
                    var white: CGFloat = 0
                    XCTAssertTrue(color.getWhite(&white, alpha: nil))
                    var nativeGlass = false
                    if #available(iOS 26.0, *) { nativeGlass = !reduced }
                    let lightInk = nativeGlass ? scheme == .dark : scheme == .light
                    if lightInk {
                        XCTAssertGreaterThanOrEqual(white, 0.8)
                    } else {
                        XCTAssertLessThanOrEqual(white, 0.2)
                    }
                    let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                        XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
                    }
                    if let directory = ProcessInfo.processInfo.environment["PLOZZ_SEERR_CAPTURE_DIR"] {
                        try XCTUnwrap(image.pngData()).write(to: URL(fileURLWithPath: directory)
                            .appendingPathComponent("Request loading \(scheme) reduced \(reduced) \(typeSize).png"))
                    }
                    let recognition = VNRecognizeTextRequest()
                    recognition.recognitionLevel = .accurate
                    recognition.recognitionLanguages = ["en-US"]
                    try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([recognition])
                    let text = (recognition.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                    XCTAssertTrue(text.contains { $0.hasSuffix("Request") },
                                  "Retain the visible request label (\(scheme), reduced \(reduced), \(typeSize)): \(text)")
                }
            }
        }
    }

    private func activityIndicators(in view: UIView) -> [UIActivityIndicatorView] {
        (view as? UIActivityIndicatorView).map { [$0] } ?? view.subviews.flatMap { activityIndicators(in: $0) }
    }

    func testAvailableMovieHasNoRequestButtonButSeriesCanStillOpenMissingSeasons() {
        for status in [MediaAvailabilityStatus.available, .partiallyAvailable] {
            let movie = MediaItem(
                id: "discovery:movie:42", title: "Movie", kind: .movie,
                availability: status, locallyValidatedPlayableSource: false
            )
            let request = PlozziOSHeroRequest(
                cta: movie.heroCTA(seerConnected: true), isRequesting: false,
                onRequest: { _ in XCTFail("An available movie must not be requested again.") }
            )
            XCTAssertEqual(measure(PlozziOSHeroRequestButton(item: movie, request: request), width: 400).height, 0)
            var series = movie
            series.kind = .series
            var seasons = request
            seasons.onOpenSeasonRequests = {}
            seasons.seasonAvailability = .init(status: status, seasons: [
                .init(number: 1, title: "Season 1", status: .available),
                .init(number: 2, title: "Season 2", status: .unknown)
            ])
            XCTAssertGreaterThanOrEqual(
                measure(PlozziOSHeroRequestButton(item: series, request: seasons), width: 400).height, 48
            )
        }
    }

    func testSeasonPollingContinuesAfterSupersededLookupUntilRequestsSettle() async {
        var lookups = 0
        var hasInFlightSeasons = true
        await plozziOSPollHeroSeasonRequests(interval: .milliseconds(1)) {
            lookups += 1
            if lookups == 1 {
                // The sheet wins the first lookup; its authoritative state still has a pending season.
                return
            }
            hasInFlightSeasons = false
        } shouldContinue: {
            hasInFlightSeasons
        }
        XCTAssertEqual(lookups, 2, "A superseded fetch must not terminate status polling.")
    }

    func testSeasonPollingStopsOnFailureAndCancellation() async {
        var failedLookups = 0
        await plozziOSPollHeroSeasonRequests(interval: .milliseconds(1)) {
            failedLookups += 1
        } shouldContinue: {
            false
        }
        XCTAssertEqual(failedLookups, 1)

        let started = expectation(description: "Initial status lookup completed")
        var lookups = 0
        let polling = Task {
            await plozziOSPollHeroSeasonRequests(interval: .seconds(20)) {
                lookups += 1
                started.fulfill()
            } shouldContinue: {
                true
            }
        }
        await fulfillment(of: [started], timeout: 2)
        polling.cancel()
        await polling.value
        XCTAssertEqual(lookups, 1)
    }

    func testSeasonRequestButtonKeepsItsPrimaryContainerAcrossAvailabilityStates() {
        let item = MediaItem(id: "series", title: "Series", kind: .series)
        let availability = MediaRequestAvailability(status: .unknown, seasons: [
            .init(number: 1, title: "Season 1", status: .unknown),
            .init(number: 2, title: "Season 2", status: .unknown)
        ])
        let detail = PlozziOSHeroRequestButton(item: item, request: .init(
            cta: .request, isRequesting: false, onRequest: { _ in },
            seasonAvailability: availability, onOpenSeasonRequests: {}
        ))
        for reduced in [false, true] {
            let buttonSize = measure(detail.environment(\.plozzReduceTransparency, reduced), width: 400)
            for availability in [nil, availability] {
                let home = PlozziOSHeroRequestButton(item: item, request: .init(
                    cta: .request, isRequesting: false, onRequest: { _ in },
                    seasonAvailability: availability, onOpenSeasonRequests: {}
                ))
                let homeSize = measure(home.environment(\.plozzReduceTransparency, reduced), width: 400)
                XCTAssertGreaterThanOrEqual(homeSize.height, 48, "The season manager action needs its primary container.")
                XCTAssertEqual(homeSize.height, buttonSize.height, accuracy: 1)
                XCTAssertGreaterThan(homeSize.width, 180)
            }
        }
    }

    func testCircularGlassRetainsItsTouchTargetAtEveryTextSize() {
        for size in [DynamicTypeSize.large, .xxxLarge, .accessibility3, .accessibility5] {
            let button = Button {} label: { Image(systemName: "bookmark") }
                .buttonStyle(PlozziOSHeroActionButtonStyle(kind: .secondary, circular: true))
                .environment(\.dynamicTypeSize, size)
            XCTAssertEqual(measure(button, width: 48), CGSize(width: 48, height: 48))
        }
    }

    func testProminentGlassRetainsMinimumWidthAndAccessibleWrapping() {
        let regular = measure(play(wraps: false, minimumWidth: 180), width: 2_000)
        XCTAssertGreaterThanOrEqual(regular.width, 180)
        XCTAssertGreaterThanOrEqual(regular.height, 48)
        let wrapped = measure(play(wraps: true), width: 145)
        XCTAssertLessThanOrEqual(wrapped.width, 145)
        XCTAssertGreaterThan(wrapped.height, regular.height)
    }

    func testResolvingPlayPlaceholderRetainsItsLayoutAtEveryTextSize() {
        for size in [DynamicTypeSize.large, .xxxLarge, .accessibility3] {
            for width in [CGFloat(145), 276, 720] {
                for resumes in [false, true] {
                    func button(placeholder: Bool) -> some View {
                        Button {} label: {
                            PlayResumeButtonLabel(
                                title: resumes ? "Resume" : "Play",
                                progress: resumes ? 0.4 : nil,
                                remainingText: resumes ? "43m" : nil,
                                seasonEpisodeText: resumes ? "S20, E100" : nil,
                                onLight: true, spacing: 10, capsuleWidth: 60,
                                isPlaceholder: placeholder, crossfadesPlaceholder: true,
                                wrapsText: width == 145
                            )
                        }
                        .buttonStyle(PlozziOSHeroActionButtonStyle(kind: .primary))
                        .environment(\.dynamicTypeSize, size)
                    }
                    let placeholder = measure(button(placeholder: true), width: width)
                    let ready = measure(button(placeholder: false), width: width)
                    XCTAssertEqual(ready.width, placeholder.width, accuracy: 0.5)
                    XCTAssertEqual(ready.height, placeholder.height, accuracy: 0.5)
                    if !resumes && size == .large { XCTAssertLessThan(ready.width, 130) }
                    if width == 145 { XCTAssertLessThanOrEqual(ready.width, width + 0.5) }
                }
            }
        }
    }

    func testGlassRowKeepsOverflowWithinPhoneAndTabletWidths() {
        for width in [CGFloat(276), 331, 386, 720] {
            for typeSize in [DynamicTypeSize.large, .xxxLarge, .accessibility3] {
                let row = ViewThatFits(in: .horizontal) {
                    ForEach((0...4).reversed(), id: \.self) { extras in
                        HeroActionRow {
                            self.play(wraps: false, minimumWidth: 180)
                            ForEach(0..<extras, id: \.self) { _ in
                                Button {} label: { Image(systemName: "bookmark") }
                                    .buttonStyle(PlozziOSHeroActionButtonStyle(kind: .secondary, circular: true))
                            }
                        }
                    }
                    HeroActionRow(stacksVertically: true) { self.play(wraps: true) }
                }
                .environment(\.dynamicTypeSize, typeSize)
                XCTAssertLessThanOrEqual(measure(row, width: width).width, width + 0.5)
            }
        }
    }

    func testReducedGlassAndTransparencyKeepTheExistingFallback() {
        for reduceGlass in [false, true] {
            for kind in [TouchHeroActionButtonStyle.Kind.primary, .secondary] {
                let label = Button("Play", action: {})
                let existing = measure(label.buttonStyle(TouchHeroActionButtonStyle(kind: kind)), width: 300)
                let actual = measure(label
                    .buttonStyle(PlozziOSHeroActionButtonStyle(kind: kind))
                    .environment(\.plozzReducePanelGlass, reduceGlass)
                    .environment(\.plozzReduceTransparency, !reduceGlass), width: 300)
                XCTAssertEqual(actual, existing)
            }
        }
    }

    private func play(wraps: Bool, minimumWidth: CGFloat? = nil) -> some View {
        Button {} label: {
            PlayResumeButtonLabel(
                title: "Resume", progress: 0.4, remainingText: "43m",
                seasonEpisodeText: "S20, E100", onLight: true,
                spacing: 10, capsuleWidth: 60, wrapsText: wraps
            )
        }
        .buttonStyle(PlozziOSHeroActionButtonStyle(kind: .primary, minimumWidth: minimumWidth))
    }

    private func measure(_ view: some View, width: CGFloat) -> CGSize {
        UIHostingController(rootView: view).sizeThatFits(in: CGSize(width: width, height: 2_000))
    }
}
#endif
