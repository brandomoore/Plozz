import CoreModels
import CoreUI
import SwiftUI

struct DetailInformationFixture: View {
    @State private var selectedPerson = ""

    static let longTitle = String(repeating: "A very long original title ", count: 40)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    private var singleValue: Bool {
        ProcessInfo.processInfo.arguments.contains("--detail-single-long-value")
    }
    private var layoutCase: String? {
        ["sparse", "rich", "personal", "episode", "discover"].first {
            ProcessInfo.processInfo.arguments.contains("--detail-layout-\($0)")
        }
    }

    private var cast: [MediaPerson] {
        (1...40).map { MediaPerson(id: "actor-\($0)", name: "Person \($0)", kind: "Actor") }
    }

    private var item: MediaItem {
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

    var body: some View {
        ScrollViewReader { scroll in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if !singleValue && layoutCase == nil {
                        Text(selectedPerson)
                            .accessibilityIdentifier("selected-cast-person")
                        CastRowView(people: cast, leadingInset: 24)
                            .environment(\.mediaPersonNavigator, { person in selectedPerson = person.name })
                    }
                    DetailInformationSections(
                        item: item, horizontalInset: horizontalInset,
                        selectedSource: layoutCase == nil || layoutCase == "discover" ? nil : MediaSourceRef(
                            accountID: "fixture", itemID: item.id, providerKind: .jellyfin,
                            serverName: "Living room server", accountName: "Household", locality: .local
                        ),
                        selectedVersion: layoutCase == nil || layoutCase == "discover" ? nil : MediaVersion(
                            id: "file",
                            fileName: layoutCase == "personal" ? "Summer holiday.mov"
                                : "Resident Evil (2026) - [WEBDL-2160p][DV HDR10Plus][EAC3 5.1][h265].mkv",
                            width: 3840, height: 2160, bitrate: 25_300_000,
                            sizeBytes: 17_800_000_000, videoCodec: "hevc",
                            videoRange: "DOVI", audioCodec: "eac3", audioChannels: 6
                        )
                    )
                }
                .id("detail-fixture-top")
            }
            .task {
                if layoutCase != nil {
                    do {
                        try await Task.sleep(for: .milliseconds(600))
                        if ProcessInfo.processInfo.arguments.contains("--detail-layout-bottom") {
                            scroll.scrollTo("playback", anchor: .bottom)
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
