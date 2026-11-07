import XCTest
import CoreModels
import CoreUI
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
@testable import FeatureHome

/// Pure-logic coverage for the env-gated imperative UIKit hero foreground's value
/// layer (``HeroForegroundModel`` / ``HeroForegroundModelBuilder``). These lock the
/// slide → visuals mapping — metadata joining, per-pill label/glyph resolution,
/// selection clamping, dots presence, spoiler masking and overview gating — with no
/// view or simulator, so the persistent renderer can stay a thin apply-in-place
/// layer over a trusted model.
final class HeroForegroundModelTests: XCTestCase {
    private typealias Builder = HeroForegroundModelBuilder
    private typealias PillInput = HeroForegroundModelBuilder.PillInput

    func testContentRatingVisibilityIsIndependentOfReviewScoresAndAgeRecommendations() {
        var item = movie(officialRating: "FR/Tous publics avec avertissement")
        item.ratings = [.init(source: .imdb, value: 8, scale: .outOfTen)]
        item.familyGuidance = .init(recommendedAge: 14, qualityRating: nil)
        let model = Builder.model(
            item: item, overviewVisible: true, showsContentRatings: false,
            maskedTitle: nil, pillInputs: [], selectedIndex: 0, heroFocused: false,
            slideCount: 1, slideIndex: 0
        )
        XCTAssertNil(model.ratingBadgeText)
        XCTAssertEqual(model.ratings, item.ratings)
        XCTAssertEqual(model.familyGuidanceAge, 14)
        XCTAssertEqual(item.officialRating, "FR/Tous publics avec avertissement")
    }

    func testUnreleasedMovieStatusUsesSharedLocalizedCopyAndCalendar() throws {
        let cta = HeroCTA.awaitingRelease
        let input = PillInput(
            kind: .downloadStatus, prominent: true,
            requestTitle: cta.requestStatusTitle, requestSystemImage: cta.requestStatusSystemImage
        )
        let pill = Builder.pill(for: input)
        var title = try XCTUnwrap(pill.localizedTitle)
        title.locale = Locale(identifier: "en")
        XCTAssertEqual(String(localized: title), "Requested · Unreleased")
        XCTAssertEqual(pill.systemImage, "calendar")
        XCTAssertNil(pill.text)
        XCTAssertNil(pill.progress)
        var downloading = input
        downloading.downloadProgress = 0.42
        XCTAssertEqual(Builder.pill(for: downloading).text, "42%")
        XCTAssertEqual(Builder.pill(for: downloading).systemImage, "arrow.down.circle")
    }

    func testHeroShowsAgeAndTwoReviewsByDefaultAndHonorsHiding() {
        var item = movie()
        item.familyGuidance = .init(recommendedAge: 14, qualityRating: 5)
        item.ratings = [
            .init(source: .imdb, value: 8, scale: .outOfTen),
            .init(source: .rottenTomatoes, value: 94, scale: .percent),
            .init(source: .rottenTomatoesAudience, value: 88, scale: .percent)
        ]
        func model(visible: Bool, preferences: DetailPageSettings = .default) -> HeroForegroundModel {
            Builder.model(
                item: item, overviewVisible: true, ratingsVisible: visible,
                ratingPreferences: preferences, maskedTitle: nil, pillInputs: [],
                selectedIndex: 0, heroFocused: false, slideCount: 1, slideIndex: 0
            )
        }
        let shown = model(visible: true)
        XCTAssertEqual(shown.familyGuidanceAge, 14)
        XCTAssertEqual(shown.ratings.map(\.source), [.rottenTomatoesAudience, .rottenTomatoes])
        XCTAssertNil(model(visible: false).familyGuidanceAge)
        XCTAssertTrue(model(visible: false).ratings.isEmpty)
        let custom = model(visible: true, preferences: .init(
            showsHeaderFamilyGuidance: false, maxHeaderRatings: 3
        ))
        XCTAssertNil(custom.familyGuidanceAge)
        XCTAssertEqual(custom.ratings.count, 3)
        item.familyGuidance = .init(recommendedAge: nil, qualityRating: 5)
        XCTAssertNil(model(visible: true).familyGuidanceAge, "A quality score is never an age.")
        item.familyGuidance = .init(recommendedAge: 14, qualityRating: nil)
        item.ratings = []
        XCTAssertEqual(model(visible: true).familyGuidanceAge, 14, "Age-only headers remain visible.")
    }

    func testDetailHeroCacheRefreshesWhenAgeAndReviewsArrive() {
        let cache = HeroPresentationCache()
        var item = movie()
        XCTAssertNil(cache.presentation(for: item).familyGuidanceAge)
        item.familyGuidance = .init(recommendedAge: 14, qualityRating: nil)
        item.ratings = [.init(source: .imdb, value: 8, scale: .outOfTen)]
        XCTAssertEqual(cache.presentation(for: item).familyGuidanceAge, 14)
        XCTAssertEqual(cache.presentation(for: item).ratings, item.ratings)
        item.familyGuidance = .init(recommendedAge: 16, qualityRating: nil)
        XCTAssertEqual(cache.presentation(for: item).familyGuidanceAge, 16)
    }

    func testFocusedEpisodeKeepsTheShowsAgeRecommendation() {
        let root = HeroPresentation(
            item: MediaItem(id: "show", title: "Show", kind: .series,
                            familyGuidance: .init(recommendedAge: 14, qualityRating: nil)),
            artworkStyle: .landscape, surface: .detail
        )
        let episode = HeroPresentation(
            item: MediaItem(id: "episode", title: "Episode", kind: .episode,
                            familyGuidance: .init(recommendedAge: 5, qualityRating: nil)),
            artworkStyle: .landscape, surface: .detail
        )
        XCTAssertEqual(HeroContentPolicy.familyGuidanceAge(focused: episode, root: root), 14)
    }

    private func movie(
        id: String = "m1",
        title: String = "The Example",
        overview: String? = "An example overview.",
        year: Int? = 2021,
        officialRating: String? = "TV-14",
        genres: [String] = ["Action", "Drama"],
        runtime: TimeInterval? = nil,
        resumePosition: TimeInterval? = nil,
        logoURL: URL? = URL(string: "https://example.com/logo.png")
    ) -> MediaItem {
        MediaItem(
            id: id,
            title: title,
            kind: .movie,
            overview: overview,
            productionYear: year,
            officialRating: officialRating,
            genres: genres,
            runtime: runtime,
            resumePosition: resumePosition,
            logoURL: logoURL
        )
    }

    // MARK: - metadataText

    func testMetadataTextJoinsYearAndGenresWithHeroSeparator() {
        let text = Builder.metadataText(for: movie(year: 2021, genres: ["Action", "Drama"]))
        XCTAssertEqual(text, "2021  ·  Action  ·  Drama")
    }

    func testMetadataTextIsNilWhenNoComponents() {
        let bare = movie(year: nil, genres: [], runtime: nil)
        XCTAssertNil(Builder.metadataText(for: bare))
    }

    func testMetadataTextCapsGenresAtThree() {
        let item = movie(year: nil, genres: ["A", "B", "C", "D", "E"])
        XCTAssertEqual(Builder.metadataText(for: item), "A  ·  B  ·  C")
    }

    // MARK: - seasonEpisodeButtonText

    func testStartWatchingPillNamesTheFirstEpisode() {
        let pill = Builder.pill(for: .init(
            kind: .play, isStarting: true, seasonEpisodeText: "S1 E1"
        ))
        XCTAssertNotNil(pill.localizedTitle)
        XCTAssertEqual(pill.text, " · S1 E1")
    }

#if canImport(UIKit)
    @MainActor
    func testUnreleasedSeasonRequestFitsNativeTVPillAndDetailActionRow() throws {
        let presentation = SeasonRequestPresentation(availability: .init(status: .processing, seasons: [
            .init(number: 1, title: "Season 1", status: .processing,
                  premiereDate: MediaItem.calendarDayReleaseDate(from: "2099-10-20"))
        ]))
        let inputs: [PillInput] = [
            .init(kind: .request, requestTitle: presentation.title, requestSystemImage: presentation.systemImage),
            .init(kind: .moreInfo),
            .init(kind: .watchlist)
        ]
        let container = UIView()
        var x: CGFloat = 0
        for input in inputs {
            let pill = HeroForegroundPillView(frame: .zero)
            pill.configure(Builder.pill(for: input), selected: input.kind == .request, locale: Locale(identifier: "en"))
            let size = pill.preferredSize()
            pill.frame = CGRect(origin: CGPoint(x: x, y: 12), size: size)
            container.addSubview(pill)
            pill.layoutIfNeeded()
            for label in pill.subviews.compactMap({ $0 as? UILabel }) where !label.isHidden {
                XCTAssertGreaterThanOrEqual(label.bounds.width, ceil(label.intrinsicContentSize.width))
                XCTAssertGreaterThanOrEqual(label.bounds.height, label.font.lineHeight)
            }
            x += size.width + 24
        }
        XCTAssertLessThan(x, 1_280)
        container.frame = CGRect(x: 0, y: 0, width: x, height: 130)
        container.backgroundColor = .black
        let image = UIGraphicsImageRenderer(bounds: container.bounds).image { context in
            container.layer.render(in: context.cgContext)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "tv-native-unreleased-request-info-watchlist"
        attachment.lifetime = .keepAlways
        add(attachment)

        let detailRow = HStack(spacing: 24) {
            SeasonRequestMenu(
                availability: .init(status: .processing),
                requestAllTitle: "Request All Seasons", onRequest: { _ in }
            ) { Label(presentation.title, systemImage: presentation.systemImage) }
                .menuStyle(.button)
                .modifier(HeroActionButtonStyle(prominent: false))
            Button {} label: { Label("Trailer", systemImage: "film.fill") }
                .modifier(HeroActionButtonStyle(prominent: false))
            Button {} label: { Image(systemName: "bookmark") }
                .modifier(HeroActionButtonStyle(prominent: false, circular: true))
        }
        .environment(\.locale, Locale(identifier: "en"))
        let host = UIHostingController(rootView: detailRow)
        let ideal = host.sizeThatFits(in: CGSize(width: 2_000, height: 500))
        XCTAssertLessThan(ideal.width, 1_280, "The full label must fit beside Trailer and Watchlist without compression.")
        let fitted = host.sizeThatFits(in: CGSize(width: 1_280, height: 500))
        XCTAssertEqual(fitted.height, ideal.height, accuracy: 1)
    }

    @MainActor
    func testStartWatchingPillResolvesCopyAtTheUIKitBoundary() {
        let pill = Builder.pill(for: .init(
            kind: .play, isStarting: true, seasonEpisodeText: "S1 E1"
        ))
        let view = HeroForegroundPillView(frame: .zero)
        view.configure(pill, selected: false, locale: Locale(identifier: "en"))
        XCTAssertEqual(
            view.subviews.compactMap { $0 as? UILabel }.first?.text,
            "Start watching · S1 E1"
        )
    }
#endif

    func testInProgressFirstEpisodeKeepsTheResumePill() {
        let pill = Builder.pill(for: .init(
            kind: .play, resumeProgress: 0.3, isResume: true, isStarting: true,
            resumeRemainingText: "35m", seasonEpisodeText: "S1 E1"
        ))
        XCTAssertEqual(pill.text, "S1 E1 • 35m")
        XCTAssertEqual(pill.progress, 0.3)
    }

    private func episode(
        id: String = "e1",
        title: String = "Pilot",
        parentTitle: String? = "Example Show",
        season: Int? = 12,
        number: Int? = 2
    ) -> MediaItem {
        MediaItem(
            id: id,
            title: title,
            kind: .episode,
            parentTitle: parentTitle,
            seasonNumber: season,
            episodeNumber: number
        )
    }

    func testSeasonEpisodeButtonTextFormatsEpisode() {
        XCTAssertEqual(Builder.seasonEpisodeButtonText(for: episode(season: 12, number: 2)), "S12 E2")
    }

    func testSeasonEpisodeButtonTextNilForMovie() {
        XCTAssertNil(Builder.seasonEpisodeButtonText(for: movie()))
    }

    func testSeasonEpisodeButtonTextNilWhenNumbersMissing() {
        XCTAssertNil(Builder.seasonEpisodeButtonText(for: episode(season: nil, number: 2)))
        XCTAssertNil(Builder.seasonEpisodeButtonText(for: episode(season: 1, number: nil)))
    }

    func testBuiltEpisodePlayPillCarriesSeasonEpisode() {
        let item = episode(season: 3, number: 7)
        let model = Builder.model(
            item: item,
            overviewVisible: true,
            maskedTitle: nil,
            pillInputs: [
                .init(kind: .play, seasonEpisodeText: Builder.seasonEpisodeButtonText(for: item))
            ],
            selectedIndex: 0,
            heroFocused: false,
            slideCount: 1,
            slideIndex: 0
        )
        XCTAssertEqual(model.pills.first?.text, "Play S3 E7")
    }

    func testEpisodeTextFallbackUsesSeriesTitle() {
        let item = episode(title: "Episode 1", parentTitle: "The Series", season: 2, number: 1)
        XCTAssertEqual(Builder.titleText(for: item, maskedTitle: nil), "The Series")
    }

    func testEpisodeTextFallbackUsesEpisodeTitleWhenSeriesTitleIsUnavailable() {
        let item = episode(title: "Episode 1", parentTitle: "  ")
        XCTAssertEqual(Builder.titleText(for: item, maskedTitle: nil), "Episode 1")
    }

    func testEpisodeTextFallbackKeepsSeriesTitleWhenEpisodeIsSpoilerMasked() {
        let item = episode(title: "Episode 1", parentTitle: "The Series")
        XCTAssertEqual(Builder.titleText(for: item, maskedTitle: "Episode 1"), "The Series")
    }

    func testEpisodeTextFallbackUsesSpoilerMaskWhenSeriesTitleIsUnavailable() {
        let item = episode(title: "Spoiler Title", parentTitle: nil)
        XCTAssertEqual(Builder.titleText(for: item, maskedTitle: "Episode 1"), "Episode 1")
    }

    // MARK: - pill(for:)

    func testPlayPillUsesPlayLabelWhenNotResumable() {
        let pill = Builder.pill(for: PillInput(kind: .play, resumeProgress: nil, isResume: false))
        XCTAssertEqual(pill.text, "Play")
        XCTAssertEqual(pill.systemImage, "play.fill")
        XCTAssertNil(pill.progress)
    }

    func testPlayPillResumeFormUsesRemainingTextAndProgress() {
        // Resume form (matches PlayResumeButtonLabel): the trailing text is the
        // remaining-time string — NOT the word "Resume" — and the inline progress
        // bar carries the resume fraction.
        let pill = Builder.pill(for: PillInput(
            kind: .play, resumeProgress: 0.42, isResume: true, resumeRemainingText: "20m"
        ))
        XCTAssertEqual(pill.text, "20m")
        XCTAssertEqual(pill.systemImage, "play.fill")
        XCTAssertEqual(pill.progress, 0.42)
    }

    func testPlayPillFallsBackToResumeWordWithoutRemainingText() {
        // Resumable but no remaining-time string: fall back to the plain titled pill
        // with no inline bar (mirrors PlayResumeButtonLabel's non-resume-form path).
        let pill = Builder.pill(for: PillInput(
            kind: .play, resumeProgress: 0.42, isResume: true, resumeRemainingText: nil
        ))
        XCTAssertEqual(pill.text, "Resume")
        XCTAssertNil(pill.progress)
    }

    // MARK: - season/episode in the Play pill

    func testSeasonEpisodeButtonTextUsesSpaceSeparatedForm() {
        XCTAssertEqual(Builder.seasonEpisodeButtonText(for: episode(season: 1, number: 22)), "S1 E22")
        XCTAssertEqual(Builder.seasonEpisodeButtonText(for: episode(season: 21, number: 8)), "S21 E8")
        XCTAssertNil(Builder.seasonEpisodeButtonText(for: movie()))
        XCTAssertNil(Builder.seasonEpisodeButtonText(for: episode(season: nil, number: 8)))
    }

    func testPlainPlayPillAppendsSeasonEpisode() {
        let pill = Builder.pill(for: PillInput(
            kind: .play, resumeProgress: nil, isResume: false, seasonEpisodeText: "S21 E8"
        ))
        XCTAssertEqual(pill.text, "Play S21 E8")
        XCTAssertNil(pill.progress)
    }

    func testResumePlayPillPrefixesSeasonEpisodeOntoRemaining() {
        let pill = Builder.pill(for: PillInput(
            kind: .play, resumeProgress: 0.42, isResume: true,
            resumeRemainingText: "43m", seasonEpisodeText: "S5 E12"
        ))
        XCTAssertEqual(pill.text, "S5 E12 • 43m")
        XCTAssertEqual(pill.progress, 0.42)
    }

    func testPlayPillOmitsSeasonEpisodeForMovies() {
        // No seasonEpisodeText (movie): plain "Play" and bare remaining, unchanged.
        XCTAssertEqual(Builder.pill(for: PillInput(kind: .play)).text, "Play")
        XCTAssertEqual(Builder.pill(for: PillInput(
            kind: .play, resumeProgress: 0.5, isResume: true, resumeRemainingText: "43m"
        )).text, "43m")
    }

    func testRequestPill() {
        let pill = Builder.pill(for: PillInput(kind: .request))
        XCTAssertEqual(pill.text, "Request")
        XCTAssertEqual(pill.systemImage, "plus.circle")
    }

    func testSeasonRequestPillKeepsCountedCopyAndStatusIcon() {
        for selected in [[7], [2, 7, 14], Array(1...20)] {
            let availability = MediaRequestAvailability(
                status: .unknown,
                seasons: (1...20).map {
                    MediaSeasonRequestState(number: $0, title: "Season \($0)", status: .unknown)
                }
            ).markingRequested(selected)
            let presentation = SeasonRequestPresentation(availability: availability)
            let pill = Builder.pill(for: PillInput(
                kind: .request,
                requestTitle: presentation.title,
                requestSystemImage: presentation.systemImage
            ))
            XCTAssertEqual(pill.kind, .request, "Status must remain an actionable season picker")
            XCTAssertEqual(pill.localizedTitle, presentation.title)
            XCTAssertEqual(pill.systemImage, presentation.systemImage)
            XCTAssertNil(pill.progress, "A requested subset is not a whole-series download")
        }
    }

#if canImport(UIKit)
    @MainActor
    func testSeasonStatusResolvesAtTheUIKitBoundary() {
        let title: LocalizedStringResource = "S\(7) Requested"
        let pill = Builder.pill(for: PillInput(
            kind: .request,
            requestTitle: title,
            requestSystemImage: "clock"
        ))
        let view = HeroForegroundPillView(frame: .zero)
        view.configure(pill, selected: false, locale: Locale(identifier: "en"))
        XCTAssertEqual(view.subviews.compactMap { $0 as? UILabel }.first?.text, "S7 Requested")
    }
#endif

    func testDownloadStatusPillShowsPercentWhenDownloading() {
        let pill = Builder.pill(for: PillInput(kind: .downloadStatus, downloadProgress: 0.826))
        XCTAssertEqual(pill.text, "83%")
        XCTAssertEqual(pill.progress, 0.826)
    }

    func testDownloadStatusPillShowsRequestedWhenNoProgress() {
        let pill = Builder.pill(for: PillInput(kind: .downloadStatus, downloadProgress: nil))
        XCTAssertEqual(pill.text, "Requested")
        XCTAssertNil(pill.progress)
    }

    func testMoreInfoPillIsIconOnly() {
        let pill = Builder.pill(for: PillInput(kind: .moreInfo))
        XCTAssertNil(pill.text)
        XCTAssertEqual(pill.systemImage, "info.circle")
    }

    func testWatchlistPillReflectsFavouriteState() {
        XCTAssertEqual(Builder.pill(for: PillInput(kind: .watchlist, isFavorite: true)).systemImage, "bookmark.fill")
        XCTAssertEqual(Builder.pill(for: PillInput(kind: .watchlist, isFavorite: false)).systemImage, "bookmark")
    }

    func testNextPillIsChevron() {
        XCTAssertEqual(Builder.pill(for: PillInput(kind: .next)).systemImage, "chevron.forward")
    }

    // MARK: - model(...)

    func testModelMapsPillsInOrderAndClampsSelection() {
        let model = Builder.model(
            item: movie(),
            overviewVisible: true,
            maskedTitle: nil,
            pillInputs: [PillInput(kind: .play), PillInput(kind: .moreInfo)],
            selectedIndex: 9,
            heroFocused: true,
            slideCount: 3,
            slideIndex: 0
        )
        XCTAssertEqual(model.pills.map(\.kind), [.play, .moreInfo])
        XCTAssertEqual(model.selectedIndex, 1, "out-of-range selection clamps to the last pill")
        XCTAssertTrue(model.heroFocused)
    }

    func testModelClampsNegativeSelectionToZero() {
        let model = Builder.model(
            item: movie(),
            overviewVisible: true,
            maskedTitle: nil,
            pillInputs: [PillInput(kind: .play), PillInput(kind: .moreInfo)],
            selectedIndex: -5,
            heroFocused: false,
            slideCount: 1,
            slideIndex: 0
        )
        XCTAssertEqual(model.selectedIndex, 0)
    }

    func testModelSelectionIsZeroWhenNoPills() {
        let model = Builder.model(
            item: movie(),
            overviewVisible: true,
            maskedTitle: nil,
            pillInputs: [],
            selectedIndex: 3,
            heroFocused: true,
            slideCount: 1,
            slideIndex: 0
        )
        XCTAssertEqual(model.selectedIndex, 0)
        XCTAssertTrue(model.pills.isEmpty)
    }

    func testModelHasNoDotsForSingleSlide() {
        let model = Builder.model(
            item: movie(),
            overviewVisible: true,
            maskedTitle: nil,
            pillInputs: [],
            selectedIndex: 0,
            heroFocused: false,
            slideCount: 1,
            slideIndex: 0
        )
        XCTAssertNil(model.dots)
    }

    func testModelHasDotsForMultipleSlides() {
        let model = Builder.model(
            item: movie(),
            overviewVisible: true,
            maskedTitle: nil,
            pillInputs: [],
            selectedIndex: 0,
            heroFocused: false,
            slideCount: 5,
            slideIndex: 2
        )
        XCTAssertEqual(model.dots, HeroForegroundModel.Dots(count: 5, index: 2))
    }

    func testModelHidesOverviewWhenNotVisible() {
        let model = Builder.model(
            item: movie(overview: "Secret plot."),
            overviewVisible: false,
            maskedTitle: nil,
            pillInputs: [],
            selectedIndex: 0,
            heroFocused: false,
            slideCount: 1,
            slideIndex: 0
        )
        XCTAssertNil(model.overview)
    }

    func testModelShowsOverviewWhenVisible() {
        let model = Builder.model(
            item: movie(overview: "Visible plot."),
            overviewVisible: true,
            maskedTitle: nil,
            pillInputs: [],
            selectedIndex: 0,
            heroFocused: false,
            slideCount: 1,
            slideIndex: 0
        )
        XCTAssertEqual(model.overview, "Visible plot.")
    }

    func testModelPrefersMaskedTitleAndKeepsLogo() {
        let model = Builder.model(
            item: movie(title: "Real Title", logoURL: URL(string: "https://example.com/logo.png")),
            overviewVisible: false,
            maskedTitle: "Hidden Show",
            pillInputs: [],
            selectedIndex: 0,
            heroFocused: false,
            slideCount: 1,
            slideIndex: 0
        )
        XCTAssertEqual(model.title, "Hidden Show")
        XCTAssertEqual(model.logoURL, URL(string: "https://example.com/logo.png"))
    }

    func testModelCarriesRatingBadgeText() {
        let model = Builder.model(
            item: movie(officialRating: "TV-MA"),
            overviewVisible: true,
            maskedTitle: nil,
            pillInputs: [],
            selectedIndex: 0,
            heroFocused: false,
            slideCount: 1,
            slideIndex: 0
        )
        XCTAssertEqual(model.ratingBadgeText, "TV-MA")
    }

    func testModelRatingBadgeIsNilWhenUnrated() {
        let model = Builder.model(
            item: movie(officialRating: nil),
            overviewVisible: true,
            maskedTitle: nil,
            pillInputs: [],
            selectedIndex: 0,
            heroFocused: false,
            slideCount: 1,
            slideIndex: 0
        )
        XCTAssertNil(model.ratingBadgeText)
    }

    func testSeriesCarriesYearAndUsesNRWhenProviderOmitsRating() {
        let item = MediaItem(
            id: "s1",
            title: "Example Series",
            kind: .series,
            productionYear: 2024,
            officialRating: nil
        )
        XCTAssertEqual(Builder.metadataText(for: item), "2024")
        XCTAssertNil(Builder.ratingBadgeText(for: item))
    }

    // MARK: - Equatable (same value = cheap no-op skip in the coordinator)

    func testEqualInputsProduceEqualModels() {
        func make() -> HeroForegroundModel {
            Builder.model(
                item: movie(),
                overviewVisible: true,
                maskedTitle: nil,
                pillInputs: [PillInput(kind: .play, resumeProgress: 0.5, isResume: true), PillInput(kind: .moreInfo)],
                selectedIndex: 0,
                heroFocused: true,
                slideCount: 3,
                slideIndex: 1
            )
        }
        XCTAssertEqual(make(), make())
    }

    func testSelectionChangeProducesUnequalModels() {
        func make(selected: Int) -> HeroForegroundModel {
            Builder.model(
                item: movie(),
                overviewVisible: true,
                maskedTitle: nil,
                pillInputs: [PillInput(kind: .play), PillInput(kind: .moreInfo)],
                selectedIndex: selected,
                heroFocused: true,
                slideCount: 2,
                slideIndex: 0
            )
        }
        XCTAssertNotEqual(make(selected: 0), make(selected: 1))
    }
}
