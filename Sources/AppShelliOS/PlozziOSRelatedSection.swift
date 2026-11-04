#if os(iOS)
import CoreModels
import CoreUI
import FeatureHomeCore
import SwiftUI

/// The "Related" rail on an iOS/iPadOS detail page: other titles in the viewer's
/// library connected to the one on screen.
///
/// Mirrors the tvOS row — same resolution, same id-verified matching, same
/// placement above the cast — rendered with the phone/tablet poster card so it sits
/// with the rest of the page rather than importing a TV-sized rail.
struct PlozziOSRelatedSection: View {
    @Environment(\.plozzCardStyle) private var cardStyle
    @Environment(\.plozzMetrics) private var metrics
    @Environment(\.plozziOSIsRunningOnMac) private var isRunningOnMac
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(PlozziOSAppModel.self) private var appModel
    @State private var browser: HomeRowBrowseModel?

    let entries: [RelatedEntry]
    var inset: CGFloat
    var onSelect: (MediaItem, MediaArtworkZoomSource) -> Void

    var body: some View {
        if !items.isEmpty {
            PlozziOSMediaSection(
                title: Text("Related"), horizontalInset: inset,
                artworkInset: cardStyle == .framed ? metrics.cardInset : 0,
                onBrowse: isRunningOnMac && items.count > PlozziOSMediaRailLayout.desktopBrowseThreshold ? {
                    browser = Self.makeBrowser(entries: entries, appModel: appModel)
                } : nil
            ) {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(
                        alignment: .top,
                        spacing: PlozziOSMediaRailLayout.stackSpacing(
                            metrics: metrics,
                            cardStyle: cardStyle
                        )
                    ) {
                        ForEach(items, id: \.stablePresentationID) { item in
                            card(item, width: cardWidth)
                        }
                    }
                }
                .contentMargins(
                    .horizontal,
                    PlozziOSMediaRailLayout.artworkAlignedInset(inset, metrics: metrics, cardStyle: cardStyle),
                    for: .scrollContent
                )
                .plozziOSMediaRailClearance()
            }
            .environment(\.plozzCardCaptionView, .related)
            .navigationDestination(item: $browser) { model in
                HomeRowBrowseView(
                    model: model,
                    columns: appModel.settings.density.density.iOSPosterGridColumns(
                        horizontalSizeClass: horizontalSizeClass, isRunningOnMac: isRunningOnMac
                    )
                ) { item in
                    card(item)
                }
                .environment(\.plozzMetrics, PlozziOSMediaLayout.metrics(
                    density: appModel.settings.density.density, dynamicTypeSize: dynamicTypeSize,
                    isRunningOnMac: isRunningOnMac
                ))
                .environment(\.plozzCardCaptionView, .related)
            }
            .onChange(of: appModel.navigationLibrariesScopeKey) { _, _ in
                browser?.invalidate()
                browser = nil
            }
        }
    }

    static func makeBrowser(entries: [RelatedEntry], appModel: PlozziOSAppModel) -> HomeRowBrowseModel {
        let scope = appModel.navigationLibrariesScopeKey
        return HomeRowBrowseModel(
            title: "Related", localizedTitle: "Related", snapshot: entries.map(\.item),
            isCurrent: { appModel.navigationLibrariesScopeKey == scope }
        )
    }

    private func card(_ item: MediaItem, width: CGFloat? = nil) -> some View {
        MediaArtworkZoomButton(id: item.stablePresentationID) { source in
            onSelect(item, source)
        } label: {
            PlozziOSPosterCard(
                item: item, statusCue: continuationItemIDs.contains(item.id) ? "Continues" : nil
            )
            .frame(width: width)
        }
        .buttonStyle(.plain)
    }

    private var items: [MediaItem] { entries.map(\.item) }
    private var cardWidth: CGFloat {
        metrics.cardSlotWidth(for: .poster, cardStyle: cardStyle)
    }

    /// Library ids of the entries that continue the seed's own story, so the cue
    /// follows the *relation* rather than anything about the matched item.
    private var continuationItemIDs: Set<String> {
        Set(entries.compactMap { $0.isContinuation ? $0.item.id : nil })
    }
}
#endif
