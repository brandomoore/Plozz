#if os(iOS)
import CoreModels
import CoreUI
import SwiftUI

struct PlozziOSExtrasSection: View {
    @Environment(\.plozzCardStyle) private var cardStyle
    @Environment(\.plozzMetrics) private var metrics

    let state: LoadState<[MediaExtra]>
    let inset: CGFloat
    let onSelect: (MediaExtra) -> Void
    let onRetry: () -> Void

    @State private var showsLoadingPlaceholders = false

    var body: some View {
        content
            .environment(\.plozzCardCaptionView, .extras)
            .task(id: state.diagnosticName) {
                showsLoadingPlaceholders = false
                guard state.isLoading else { return }
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled, state.isLoading else { return }
                showsLoadingPlaceholders = true
            }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .loaded(let extras) where !extras.isEmpty:
            PlozziOSExtrasRail(
                extras: extras,
                inset: inset,
                cardWidth: cardWidth,
                onSelect: onSelect
            )
        case .loading where showsLoadingPlaceholders:
            PlozziOSExtrasLoadingRail(inset: inset, cardWidth: cardWidth)
        case .failed(let error):
            PlozziOSExtrasFailure(
                message: error.userMessage,
                inset: inset,
                onRetry: onRetry
            )
        default:
            EmptyView()
        }
    }

    private var cardWidth: CGFloat {
        metrics.cardSlotWidth(for: .landscape, cardStyle: cardStyle)
    }
}

private struct PlozziOSExtrasRail: View {
    @Environment(\.plozzCardStyle) private var cardStyle
    @Environment(\.plozzMetrics) private var metrics

    let extras: [MediaExtra]
    let inset: CGFloat
    let cardWidth: CGFloat
    let onSelect: (MediaExtra) -> Void

    var body: some View {
        PlozziOSMediaSection(
            title: Text("Extras"), horizontalInset: inset,
            artworkInset: cardStyle == .framed ? metrics.cardInset : 0
        ) {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(
                    alignment: .top,
                    spacing: PlozziOSMediaRailLayout.stackSpacing(
                        metrics: metrics,
                        cardStyle: cardStyle
                    )
                ) {
                    ForEach(extras) { extra in
                        Button {
                            onSelect(extra)
                        } label: {
                            PlozziOSPosterCard(
                                item: extra.item,
                                style: .landscape,
                                artworkPolicy: .extra,
                                showsResumeChip: extra.supportsResume
                            )
                            .frame(width: cardWidth)
                        }
                        .buttonStyle(.plain)
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
    }
}

private struct PlozziOSExtrasLoadingRail: View {
    @Environment(\.plozzCardStyle) private var cardStyle
    @Environment(\.plozzMetrics) private var metrics

    let inset: CGFloat
    let cardWidth: CGFloat

    var body: some View {
        PlozziOSMediaSection(
            title: Text("Extras"), horizontalInset: inset,
            artworkInset: cardStyle == .framed ? metrics.cardInset : 0
        ) {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(
                    alignment: .top,
                    spacing: PlozziOSMediaRailLayout.stackSpacing(
                        metrics: metrics,
                        cardStyle: cardStyle
                    )
                ) {
                    ForEach(0..<3, id: \.self) { _ in
                        PlozziOSPosterCard(item: nil, style: .landscape)
                            .frame(width: cardWidth)
                    }
                }
            }
            .contentMargins(
                .horizontal,
                PlozziOSMediaRailLayout.artworkAlignedInset(inset, metrics: metrics, cardStyle: cardStyle),
                for: .scrollContent
            )
            .plozziOSMediaRailClearance()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

private struct PlozziOSExtrasFailure: View {
    let message: LocalizedStringResource
    let inset: CGFloat
    let onRetry: () -> Void

    var body: some View {
        PlozziOSMediaSection(title: Text("Extras"), horizontalInset: inset) {
            VStack(alignment: .leading, spacing: 8) {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button("Try Again", action: onRetry)
                    .buttonStyle(.bordered)
            }
            .padding(.horizontal, inset)
        }
    }
}
#endif
