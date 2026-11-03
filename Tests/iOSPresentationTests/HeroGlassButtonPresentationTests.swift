#if os(iOS)
import CoreModels
import CoreUI
import SwiftUI
import UIKit
import XCTest
@testable import AppShelliOS

@MainActor
final class HeroGlassButtonPresentationTests: XCTestCase {
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
