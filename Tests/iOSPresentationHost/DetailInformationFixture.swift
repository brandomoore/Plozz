import CoreModels
import CoreUI
import SwiftUI

struct DetailInformationFixture: View {
    @State private var selectedPerson = ""
    @State private var backdropScope = NSObject()

    private struct Example: Decodable {
        let item: MediaItem
        let availability: ExternalTitleAvailability?
        let source: MediaSourceRef?
        let version: MediaVersion?
    }

    private static let example: Example? = {
        guard let path = ProcessInfo.processInfo.environment["PLOZZ_DETAIL_EXAMPLE_PATH"] else { return nil }
        do {
            return try JSONDecoder().decode(Example.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        } catch {
            preconditionFailure("Unable to load requested detail example: \(error)")
        }
    }()

    static let longTitle = String(repeating: "A very long original title ", count: 40)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    private var singleValue: Bool {
        ProcessInfo.processInfo.arguments.contains("--detail-single-long-value")
    }
    private var layoutCase: String? {
        let cases = ["sparse", "rich", "personal", "episode", "discover", "guidance", "upcoming", "ratings-only", "three-ratings", "family-only", "lupin", "slow-horses"]
            + (0...5).map { "ratings-\($0)-guide" }
        return cases.first {
            ProcessInfo.processInfo.arguments.contains("--detail-layout-\($0)")
        }
    }

    private var cast: [MediaPerson] {
        (1...40).map { MediaPerson(id: "actor-\($0)", name: "Person \($0)", kind: "Actor") }
    }

    private var item: MediaItem {
        if let example = Self.example { return example.item }
        if let layoutCase {
            if layoutCase == "personal" {
                return MediaItem(id: "personal", title: "Summer holiday", kind: .video)
            }
            var item = MediaItem(
                id: "layout", title: "Resident Evil", kind: .movie,
                overview: "Medical courier Bryan unwittingly finds himself fighting for survival as one fateful, horrifying night collapses around him in chaos.",
                productionYear: 2026,
                officialRating: "R", genres: ["Horror", "Science Fiction", "Adventure"],
                people: [
                    .init(id: "director", name: "Zach Cregger", kind: "Director"),
                    .init(id: "writer-one", name: "Shay Hatten", kind: "Writer"),
                    .init(id: "writer-two", name: "Zach Cregger", kind: "Writer")
                ],
                studios: ["Constantin Film", "Subconscious", "Vertigo Entertainment", "PlayStation Productions"],
                runtime: 5_700,
                ratings: [.init(source: .tmdb, value: 7.3, scale: .outOfTen)]
            )
            if layoutCase == "rich" {
                item.title = "A documentary series"
                item.kind = .series
                item.overview = String(repeating: "Two collectors travel across the country looking for unusual objects and the stories behind them. ", count: 12)
                item.originalTitle = String(repeating: "An original title with a long subtitle ", count: 8)
                item.ratings = [
                    .init(source: .imdb, value: 7.9, scale: .outOfTen),
                    .init(source: .tmdb, value: 8.1, scale: .outOfTen),
                    .init(source: .rottenTomatoes, value: 96, scale: .percent),
                    .init(source: .rottenTomatoesAudience, value: 88, scale: .percent)
                ]
                item.people += (1...20).map {
                    .init(id: "director-\($0)", name: "Director \($0)", kind: "Director")
                }
                item.tags = ["Independent film", "Travel", "Documentary", "Collecting", "History"]
            }
            if layoutCase == "episode" {
                item.title = "The journey begins"
                item.kind = .episode
                item.seasonNumber = 1
                item.episodeNumber = 2
                item.runtime = 2_640
                item.ratings = []
                item.studios = []
            }
            if layoutCase == "guidance" {
                item.title = "The Last of Us"
                item.kind = .series
                item.officialRating = "TV-MA"
                item.ratings = [
                    .init(source: .imdb, value: 8.4, scale: .outOfTen),
                    .init(source: .tmdb, value: 8.4, scale: .outOfTen),
                    .init(source: .rottenTomatoes, value: 94, scale: .percent),
                    .init(source: .rottenTomatoesAudience, value: 62, scale: .percent)
                ]
                item.familyGuidance = .init(
                    recommendedAge: 16, qualityRating: 4,
                    overview: "Survival drama with strong violence and language."
                )
            }
            let matrixCount = (0...5).first { layoutCase == "ratings-\($0)-guide" }
            if layoutCase == "lupin" || layoutCase == "slow-horses" || matrixCount != nil {
                item.kind = .series
                item.officialRating = "TV-MA"
                item.originalTitle = nil
                item.genres = ["Drama", "Crime", "Action", "Mystery"]
                if layoutCase == "lupin" {
                    item.title = "Lupin"
                    item.overview = "Inspired by the adventures of Arsène Lupin, gentleman thief Assane Diop sets out to avenge his father for an injustice inflicted by a wealthy family."
                    item.productionYear = 2021
                    item.runtime = nil
                    item.ratings = [.init(source: .tmdb, value: 7.7, scale: .outOfTen)]
                    item.people = [
                        .init(id: "d1", name: "Hugo Gélin", kind: "Director"),
                        .init(id: "d2", name: "Ludovic Bernard", kind: "Director"),
                        .init(id: "d3", name: "Daniel Grou", kind: "Director"),
                        .init(id: "w1", name: "François Uzan", kind: "Writer"),
                        .init(id: "w2", name: "George Kay", kind: "Writer"),
                        .init(id: "w3", name: "Tony Saint", kind: "Writer")
                    ]
                    item.studios = ["Gaumont", "Carrousel Studios"]
                } else {
                    item.title = "Slow Horses"
                    item.overview = "A dysfunctional team of MI5 agents navigate the espionage world's smoke and mirrors to defend the UK from sinister forces."
                    item.productionYear = 2022
                    item.runtime = 3_000
                    item.ratings = [
                        .init(source: .rottenTomatoes, value: 98, scale: .percent),
                        .init(source: .rottenTomatoesAudience, value: 88, scale: .percent),
                        .init(source: .imdb, value: 8.3, scale: .outOfTen),
                        .init(source: .tmdb, value: 8.1, scale: .outOfTen)
                    ]
                    item.familyGuidance = .init(
                        recommendedAge: 16, qualityRating: nil,
                        overview: "Smart espionage thriller has language, violence, drinking."
                    )
                    item.people = [
                        .init(id: "d1", name: "Saul Metzstein", kind: "Director"),
                        .init(id: "d2", name: "Adam Randall", kind: "Director"),
                        .init(id: "d3", name: "James Hawes", kind: "Director"),
                        .init(id: "w1", name: "Will Smith", kind: "Writer"),
                        .init(id: "w2", name: "Mark Denton", kind: "Writer"),
                        .init(id: "w3", name: "Jonny Stockwood", kind: "Writer")
                    ]
                    item.studios = ["See-Saw Films"]
                    if let matrixCount {
                        item.ratings = Array((item.ratings + [
                            .init(source: .metacritic, value: 73, scale: .outOfHundred)
                        ]).prefix(matrixCount))
                    }
                }
            }
            if layoutCase == "upcoming" {
                item.title = "The Dog Stars"
                item.runtime = nil
                item.officialRating = nil
            }
            if layoutCase == "ratings-only" || layoutCase == "three-ratings" || layoutCase == "family-only" {
                var sparse = MediaItem(id: "minimal", title: "Minimal title", kind: .movie)
                if layoutCase == "ratings-only" {
                    sparse.ratings = item.ratings
                } else if layoutCase == "three-ratings" {
                    sparse.ratings = [
                        .init(source: .rottenTomatoes, value: 98, scale: .percent),
                        .init(source: .imdb, value: 8.3, scale: .outOfTen),
                        .init(source: .tmdb, value: 8.1, scale: .outOfTen)
                    ]
                } else {
                    sparse.familyGuidance = .init(recommendedAge: 12, qualityRating: nil)
                }
                return sparse
            }
            return item
        }
        if singleValue {
            return MediaItem(id: "long", title: "Title", originalTitle: Self.longTitle, kind: .movie)
        }
        return MediaItem(
            id: "series", title: "Series", kind: .series,
            people: (1...60).map { MediaPerson(id: "director-\($0)", name: "Director \($0)", kind: "Director") }
        )
    }

    private var isUnowned: Bool {
        guard let layoutCase else { return false }
        return ["discover", "upcoming", "ratings-only", "three-ratings", "family-only"].contains(layoutCase)
    }

    private var availability: ExternalTitleAvailability? {
        if let example = Self.example { return example.availability }
        guard layoutCase == "upcoming" else { return nil }
        var events: [TitleReleaseEvent] = [
            .init(kind: .theatrical, date: Date(timeIntervalSince1970: 1_787_875_200), regionCode: "US"),
            .init(kind: .digital, date: Date(timeIntervalSince1970: 1_793_059_200), regionCode: "US"),
            .init(kind: .physical, date: Date(timeIntervalSince1970: 1_796_083_200), regionCode: "US")
        ]
        if ProcessInfo.processInfo.arguments.contains("--detail-many-release-events") {
            events += (1...9).map {
                .init(kind: .theatrical, date: Date(timeIntervalSince1970: 1_787_875_200 + Double($0) * 86_400),
                      regionCode: "US")
            }
        }
        return ExternalTitleAvailability(
            regionCode: "US",
            releaseEvents: events,
            watchOffers: ["Prime Video", "Apple TV", "Fandango at Home"].enumerated().map {
                .init(providerID: $0.offset, providerName: $0.element, kind: .rent, regionCode: "US")
            }
        )
    }

    private var selectedSource: MediaSourceRef? {
        if let example = Self.example { return example.source }
        guard layoutCase != nil, !isUnowned else { return nil }
        return MediaSourceRef(
            accountID: "fixture", itemID: item.id, providerKind: .jellyfin,
            serverName: "Living room server", accountName: "Household", locality: .local
        )
    }

    private var selectedVersion: MediaVersion? {
        if let example = Self.example { return example.version }
        guard layoutCase != nil, !isUnowned else { return nil }
        return MediaVersion(
            id: "file",
            fileName: ProcessInfo.processInfo.arguments.contains("--detail-long-filename")
                ? String(repeating: "A complete media filename ", count: 40) + ".mkv"
                : layoutCase == "personal" ? "Summer holiday.mov"
                : "\(item.title) (\(item.productionYear ?? 2026)) - [WEBDL-2160p][DV HDR10Plus][EAC3 5.1][h265].mkv",
            width: 3840, height: 2160, bitrate: 25_300_000,
            sizeBytes: 17_800_000_000, videoCodec: "hevc",
            videoRange: "DOVI", audioCodec: "eac3", audioChannels: 6
        )
    }

    var body: some View {
        ScrollViewReader { scroll in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if Self.example == nil && !singleValue && layoutCase == nil {
                        Text(selectedPerson)
                            .accessibilityIdentifier("selected-cast-person")
                        CastRowView(people: cast, leadingInset: 24)
                            .environment(\.mediaPersonNavigator, { person in selectedPerson = person.name })
                    }
                    DetailInformationSections(
                        item: item, horizontalInset: horizontalInset,
                        selectedSource: selectedSource,
                        selectedVersion: selectedVersion,
                        externalAvailability: availability,
                        spoilerSettings: .init(hideRatingsUntilWatched:
                            ProcessInfo.processInfo.arguments.contains("--detail-layout-hide-ratings"))
                    )
                }
                .id("detail-fixture-top")
            }
            .task {
                if layoutCase != nil || Self.example != nil {
                    do {
                        try await Task.sleep(for: .milliseconds(600))
                        if ProcessInfo.processInfo.arguments.contains("--detail-layout-bottom") {
                            scroll.scrollTo("playback", anchor: .bottom)
                        } else if ProcessInfo.processInfo.arguments.contains("--detail-layout-ratings-top") {
                            scroll.scrollTo("ratings", anchor: .top)
                        } else {
                            scroll.scrollTo("detail-fixture-top", anchor: .top)
                        }
                        print("DETAIL_LAYOUT ready")
                    } catch is CancellationError {
                    } catch {
                        preconditionFailure("Detail fixture scroll failed: \(error)")
                    }
                }
            }
        }
        .artworkGradientBackground(scope: ObjectIdentifier(backdropScope), isVisible: true)
        .environment(\.gradientBackgroundsEnabled,
                     !ProcessInfo.processInfo.arguments.contains("--detail-layout-flat"))
        .environment(\.plozzReduceTransparency,
                     ProcessInfo.processInfo.arguments.contains("--detail-layout-reduced-transparency"))
        .environment(\.plozzCardFocusStyle, .system)
        .environment(\.themePalette, palette)
        .dynamicTypeSize(ProcessInfo.processInfo.arguments.contains("--detail-layout-large-type") ? .accessibility3 : .large)
        .preferredColorScheme(palette.isLight ? .light : .dark)
    }

    private var palette: ThemePalette {
        ProcessInfo.processInfo.arguments.contains("--detail-layout-light") ? .light : .dark
    }

    private var horizontalInset: CGFloat {
        #if os(tvOS)
        80
        #else
        24
        #endif
    }
}
