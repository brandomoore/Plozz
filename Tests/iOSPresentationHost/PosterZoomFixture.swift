import CoreModels
import CoreUI
import FeatureHomeCore
import HeroUI
import SwiftUI
import UIKit
@testable import AppShelliOS

struct PosterZoomFixture: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var scrollOffset: CGFloat = 0
    @State private var selection: MediaArtworkZoomRoute<String>?
    @State private var plainSelection: String?
    @State private var playCount = 0
    @State private var trailers = HeroTrailerController()
    @State private var featured = FeaturedTrailerCoordinator()
    private let arguments = ProcessInfo.processInfo.arguments
    private var item: MediaItem {
        if arguments.contains("--episode-menu") {
            return MediaItem(
                id: "duplicate", title: "Same episode", kind: .episode,
                parentTitle: "Same show", seasonNumber: 2, episodeNumber: 3,
                seriesID: "show", seasonID: "season", sourceAccountID: "server"
            )
        }
        return MediaItem(id: "duplicate", title: "Same movie", kind: .movie)
    }

    private var shape: String {
        arguments.first { $0.hasPrefix("--shape=") }?.replacingOccurrences(of: "--shape=", with: "") ?? "portrait"
    }
    private var density: UIDensity {
        let name = arguments.first { $0.hasPrefix("--density=") }?.replacingOccurrences(of: "--density=", with: "")
        return name.flatMap(UIDensity.init(rawValue:)) ?? .standard
    }
    private var cardStyle: CardStyle { arguments.contains("--framed") ? .framed : .borderless }
    private var style: PosterCardView.Style { shape.contains("landscape") ? .landscape : .poster }
    private var seriesArtwork: Bool { shape.hasPrefix("series") }
    private var metrics: PlozzMetrics {
        .touch(density: density, dynamicTypeSize: arguments.contains("--large-text") ? .accessibility2 : .large)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    Color.clear.frame(height: 180)
                    if arguments.contains("--featured") {
                        FeaturedMediaRow(
                            title: Text("Featured"), items: [item],
                            scope: ObjectIdentifier(trailers), coordinator: featured, controller: trailers,
                            settings: .default, resolver: { _ in nil }, isActive: false,
                            onSelect: { _ in }
                        )
                        .artworkNavigation { _, source in
                            selection = .init(value: "featured", source: source)
                        }
                        .accessibilityIdentifier("zoom-featured-row")
                    }
                    if arguments.contains("--filmography") {
                        MediaRowView(title: Text("Filmography"), items: [item], onSelect: { _ in })
                            .artworkNavigation { _, source in
                                selection = .init(value: "filmography", source: source)
                            }
                            .accessibilityIdentifier("zoom-filmography-row")
                    }
                    ForEach(0..<2) { row in
                        ScrollView(.horizontal) {
                            HStack(alignment: .top, spacing: 16) {
                                Color.clear.frame(width: 20)
                                Group {
                                    if arguments.contains("--direct-play") {
                                        Button { playCount += 1 } label: { poster }
                                    } else {
                                        MediaArtworkZoomLink(id: item.stablePresentationID) {
                                            detail("row-\(row)")
                                        } label: {
                                            poster
                                        }
                                    }
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("zoom-card-\(row)")
                                Color.clear.frame(width: 240, height: 10)
                            }
                        }
                        .scrollIndicators(.hidden)
                    }
                    MediaArtworkZoomButton(id: "programmatic") { source in
                        selection = .init(value: "programmatic", source: source)
                    } label: {
                        poster
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("zoom-programmatic")
                    MediaArtworkZoomValueLink(id: "value", value: "value") {
                        poster
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("zoom-value")
                    NavigationLink("Plain entry") {
                        detail("plain")
                    }
                    Text("Menu without artwork")
                        .mediaItemContextMenu(for: item)
                        .accessibilityIdentifier("zoom-plain-menu")
                    Color.clear.frame(height: 300)
                }
            }
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top
            } action: { _, offset in
                scrollOffset = offset
            }
            .accessibilityIdentifier("zoom-scroll")
            .navigationTitle("Poster zoom")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(item: $selection) { route in
                detail(route.value).mediaArtworkZoomDestination(route.source)
            }
            .navigationDestination(for: MediaArtworkZoomRoute<String>.self) { route in
                detail(route.value).mediaArtworkZoomDestination(route.source)
            }
            .navigationDestination(item: $plainSelection) { detail($0) }
            .mediaItemNavigator { plainSelection = "plain-\($0.kind.rawValue)" }
            .mediaItemArtworkNavigator { target, source in
                selection = .init(value: "menu-\(target.kind.rawValue)", source: source)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            VStack {
                Text(verbatim: reduceMotion ? "reduced" : "full")
                    .accessibilityIdentifier("zoom-motion-preference")
                Text(verbatim: "\(scrollOffset)")
                    .accessibilityIdentifier("zoom-scroll-offset")
                Text(verbatim: "\(playCount)")
                    .accessibilityIdentifier("zoom-play-count")
            }
            .allowsHitTesting(false)
        }
        .environment(\.themePalette, .dark)
        .mediaItemActionHandler(MenuActions())
        .environment(\.plozzMetrics, metrics)
        .environment(\.plozzCardStyle, cardStyle)
        .environment(\.plozzCardCaptionSettings, CardCaptionSettings(preference: arguments.contains("--no-captions") ? .hide : .show))
        .environment(\.plozzContinueWatchingPlaybackDetails, shape == "series-progress" ? .progressOnly : .detailed)
        .environment(\.dynamicTypeSize, arguments.contains("--large-text") ? .accessibility2 : .large)
        .preferredColorScheme(.dark)
    }

    private var poster: some View {
        PlozziOSPosterCard(
            item: item, style: style, showsSeriesArtwork: seriesArtwork,
            showsResumeChip: seriesArtwork
        )
        .frame(width: metrics.cardSlotWidth(for: style, cardStyle: cardStyle, showsSeriesArtwork: seriesArtwork))
    }

    private func detail(_ name: String) -> some View {
        ScrollView {
            VStack(spacing: 30) {
                Text(verbatim: name).font(.largeTitle).accessibilityIdentifier("zoom-detail")
                Color.teal.frame(height: 160)
                MediaArtworkZoomLink(id: "nested") {
                    ScrollView {
                        Text("Nested detail").accessibilityIdentifier("zoom-nested-detail")
                        Color.orange.frame(height: 900)
                    }
                    .navigationTitle("Nested")
                } label: {
                    poster
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("zoom-nested")
                Color.teal.frame(height: 900)
            }
        }
        .navigationTitle("Details")
        .navigationBarTitleDisplayMode(.inline)
    }

    private final class MenuActions: MediaItemActionHandling {
        func actions(for item: MediaItem, context: MediaItemActionContext) -> [MediaItemAction] {
            item.kind == .episode ? [.goToSeason, .goToEpisode] : [.goToMovie]
        }
        func perform(_ action: MediaItemAction, on item: MediaItem, context: MediaItemActionContext) {}
    }
}
