import CoreModels
import CoreUI
import FeatureLiveTVCore
import SwiftUI

/// The storage-opening stage uses the same geometry as the retained guide.
public struct LiveTVLoadingSkeleton: View {
    @Environment(\.themePalette) private var palette
    @Environment(\.plozzNavigationContentInset) private var navigationInset
    @Environment(\.dynamicTypeSize) private var typeSize

    public init() {}

    public var body: some View {
        GeometryReader { geometry in
            let layout = PrototypePreviewLayout(
                size: geometry.size, safeAreaInsets: geometry.safeAreaInsets,
                navigationInset: navigationInset, largeText: typeSize.isAccessibilitySize
            )
            ZStack {
                palette.backgroundBase.ignoresSafeArea()
                PrototypeGuidePlacement(frame: layout.contentFrame, canvasWidth: geometry.size.width) {
                    VStack(spacing: layout.sectionGap) {
                        #if os(iOS)
                        PrototypeLoadingToolbar().frame(height: 44)
                        #endif
                        PrototypePreviewHeroSkeleton(layout: layout)
                            .frame(height: layout.heroHeight, alignment: .bottomLeading)
                            #if DEBUG
                            .modifier(PrototypeHeroLayoutObservation(phase: "storage"))
                            #endif
                        HStack(alignment: .top, spacing: PrototypeLayout.sectionGap) {
                            if layout.sidebarWidth > 0 {
                                PrototypeLoadingSidebar().frame(width: layout.sidebarWidth)
                            }
                            VStack(spacing: PrototypeLayout.toolbarGuideGap) {
                                #if os(tvOS)
                                if layout.sidebarWidth == 0 {
                                    PrototypeLoadingToolbar().frame(height: PrototypeLayout.controlHeight + 2 * PrototypeLayout.controlInset)
                                }
                                #endif
                                PrototypeGuideSkeleton()
                            }
                            .frame(width: layout.guideWidth + layout.guideLeadingExtension + layout.guideTrailingExtension)
                            .padding(.leading, -layout.guideLeadingExtension)
                            .padding(.trailing, -layout.guideTrailingExtension)
                            .padding(.bottom, -layout.guideBottomExtension)
                        }
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading your channels")
    }
}

struct PrototypePreviewHeroSkeleton: View {
    let layout: PrototypePreviewLayout

    var body: some View {
        Group {
            if layout.compact {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: PrototypeLayout.gap) {
                        PrototypeSkeletonArtwork(size: layout.heroArtworkSize)
                        VStack(alignment: .leading, spacing: PrototypeLayout.smallGap) {
                            PrototypeSkeletonText(font: .caption.weight(.medium), fraction: 0.7)
                            PrototypeSkeletonWatchButton()
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    PrototypeSkeletonText(font: .headline, fraction: 0.72)
                    PrototypeSkeletonText(font: .caption, fraction: 0.8)
                    PrototypeSkeletonText(font: .caption, fraction: 0.95)
                    PrototypeSkeletonText(font: .caption, fraction: 0.62)
                }
            } else if layout.short {
                HStack(spacing: PrototypeLayout.gap) {
                    PrototypeSkeletonArtwork(size: layout.heroArtworkSize)
                    PrototypeSkeletonHeroDetails()
                        .frame(maxWidth: layout.metadataWidth, maxHeight: layout.heroArtworkSize.height, alignment: .leading)
                    #if os(iOS)
                    PrototypeSkeletonWatchButton().fixedSize()
                    #endif
                    Spacer(minLength: 0)
                }
                .frame(height: layout.heroHeight)
            } else {
                VStack(alignment: .leading, spacing: PrototypeLayout.smallGap) {
                    HStack(alignment: .top, spacing: PrototypeLayout.sectionGap) {
                        PrototypeSkeletonArtwork(size: layout.heroArtworkSize)
                        PrototypeSkeletonHeroDetails()
                            .frame(maxWidth: .infinity, maxHeight: layout.heroArtworkSize.height, alignment: .topLeading)
                    }
                    .frame(height: layout.heroArtworkSize.height)
                    #if os(iOS)
                    PrototypeSkeletonWatchButton()
                    #endif
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
        .modifier(PrototypeSkeletonAnimation())
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct PrototypeSkeletonArtwork: View {
    let size: CGSize
    @Environment(\.themePalette) private var palette

    var body: some View {
        RoundedRectangle(cornerRadius: PrototypeLayout.logoRadius, style: .continuous)
            .fill(palette.fill)
            .frame(width: size.width, height: size.height)
    }
}

private struct PrototypeSkeletonHeroDetails: View {
    var body: some View {
        VStack(alignment: .leading, spacing: PrototypeLayout.smallGap) {
            PrototypeSkeletonText(font: .caption.weight(.medium), fraction: 0.3)
            PrototypeSkeletonText(font: .title3.weight(.semibold), fraction: 0.65)
            PrototypeSkeletonText(font: .caption.monospacedDigit(), fraction: 0.45)
            PrototypeSkeletonText(font: .caption, fraction: 0.88)
            PrototypeSkeletonText(font: .caption, fraction: 0.72)
        }
    }
}

private struct PrototypeSkeletonWatchButton: View {
    @Environment(\.themePalette) private var palette

    var body: some View {
        Button {} label: {
            Label("Watch channel", systemImage: "play.fill")
        }
        .font(.subheadline.weight(.semibold))
        .plozzGlassPillButton()
        .hidden()
        .overlay { Capsule().fill(palette.fill) }
        .disabled(true)
        .allowsHitTesting(false)
    }
}

struct PrototypeSkeletonText: View {
    let font: Font
    var fraction: CGFloat = 0.65
    @Environment(\.themePalette) private var palette

    var body: some View {
        Text(verbatim: " ")
            .font(font)
            .frame(maxWidth: .infinity, alignment: .leading)
            .hidden()
            .overlay(alignment: .leading) {
                GeometryReader { geometry in
                    Capsule()
                        .fill(palette.fill)
                        .frame(width: geometry.size.width * fraction, height: max(4, geometry.size.height * 0.52))
                        .frame(height: geometry.size.height)
                }
            }
    }
}

struct PrototypeLoadingSidebar: View {
    @ScaledMetric(relativeTo: .subheadline) private var fontSize = PrototypeLayout.guideFontSize

    var body: some View {
        VStack(alignment: .leading, spacing: PrototypeLayout.gap) {
            PrototypeSkeletonText(font: .system(size: fontSize), fraction: 0.58)
                .frame(minHeight: PrototypeLayout.controlHeight)
                .padding(.horizontal, PrototypeLayout.gap)
                .padding(PrototypeLayout.controlInset)
                .background { PrototypeControlSurface() }
            PrototypeSkeletonText(font: .system(size: fontSize), fraction: 0.7)
                .padding(PrototypeLayout.gap)
                .frame(minHeight: PrototypeLayout.controlHeight)
            VStack(spacing: PrototypeLayout.smallGap) {
                ForEach(0..<4, id: \.self) { row in
                    PrototypeSkeletonText(font: .system(size: fontSize), fraction: row.isMultiple(of: 2) ? 0.72 : 0.5)
                        .frame(minHeight: PrototypeLayout.controlHeight)
                        .padding(.horizontal, PrototypeLayout.gap)
                }
            }
            .padding(.vertical, PrototypeLayout.smallGap)
            Spacer(minLength: 0)
        }
        .modifier(PrototypeSkeletonAnimation())
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct PrototypeLoadingToolbar: View {
    var body: some View {
        HStack(spacing: PrototypeLayout.gap) {
            PrototypeSkeletonText(font: .subheadline, fraction: 0.8).frame(width: 110)
            PrototypeSkeletonText(font: .subheadline, fraction: 0.7).frame(width: 140)
            Spacer(minLength: 0)
        }
        .modifier(PrototypeSkeletonAnimation())
    }
}

private struct PrototypeSkeletonAnimation: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        content.shimmering(active: isEnabled && scenePhase == .active)
    }
}

struct PrototypeGuideSkeleton: View {
    private let now = Date()

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: PrototypeLayout.rulerGap) {
                PrototypeTimeRuler(
                    start: Date(timeIntervalSince1970: floor(now.timeIntervalSince1970 / 1800) * 1800),
                    now: now, width: geometry.size.width, timelineOffset: 0,
                    section: .channels, showsNowMarker: false, isLoading: true
                )
                PrototypeGuideSkeletonRows(width: geometry.size.width)
            }
        }
        .padding([.leading, .top], PrototypeLayout.guideInset)
        .padding(.trailing, PrototypeLayout.guideTrailingInset)
        .background { PrototypeGuideSurface() }
        .clipShape(PrototypeLayout.guideShape)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct PrototypeGuideSkeletonRows: View {
    let width: CGFloat
    @ScaledMetric(relativeTo: .subheadline) private var scaledHeight = PrototypeLayout.rowHeight
    @Environment(\.themePalette) private var palette

    var body: some View {
        GeometryReader { geometry in
            let height = PrototypeLayout.rowHeight(for: width, scaledHeight: scaledHeight)
            let count = max(1, Int(ceil(geometry.size.height / (height + PrototypeLayout.rowGap))))
            let slots = Int(PrototypeLayout.viewportSeconds(for: width) / 1800)
            let slotWidth = PrototypeLayout.timelineWidth(for: width) / CGFloat(slots)
            VStack(spacing: PrototypeLayout.rowGap) {
                ForEach(0..<count, id: \.self) { _ in
                    HStack(spacing: PrototypeLayout.columnGap) {
                        RoundedRectangle(cornerRadius: PrototypeLayout.rowRadius, style: .continuous)
                            .fill(palette.fill)
                            .frame(width: PrototypeLayout.stationWidth(for: width))
                        HStack(spacing: PrototypeLayout.cellGap) {
                            ForEach(0..<slots, id: \.self) { index in
                                VStack(alignment: .leading, spacing: PrototypeLayout.smallGap) {
                                    PrototypeSkeletonText(font: .subheadline, fraction: index == 1 ? 0.6 : 0.8)
                                    PrototypeSkeletonText(font: .caption, fraction: 0.45)
                                }
                                .padding(.horizontal, PrototypeLayout.rowInset)
                                .frame(width: max(1, slotWidth - PrototypeLayout.cellGap))
                                .frame(maxHeight: .infinity, alignment: .leading)
                                .background(palette.fillSubtle, in: RoundedRectangle(
                                    cornerRadius: PrototypeLayout.programRadius, style: .continuous))
                            }
                        }
                    }
                    .frame(height: height)
                }
            }
            #if os(tvOS)
            .padding(.top, PrototypeLayout.smallGap)
            #else
            .padding(.top, PrototypeLayout.sectionLabelGap)
            #endif
            .frame(width: width, alignment: .topLeading)
        }
        .clipped()
        .modifier(PrototypeSkeletonAnimation())
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading your channels")
        .accessibilityIdentifier("live-tv-guide-skeleton")
    }

}
