#if os(iOS)
import CoreModels
import CoreUI
import SwiftUI

struct PlozziOSCollectionMembersSection: View {
    @Environment(\.plozzCardStyle) private var cardStyle
    @Environment(\.plozzMetrics) private var metrics

    let items: [MediaItem]
    let state: LoadState<Int>
    let inset: CGFloat
    let onSelect: (MediaItem) -> Void
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Contents")
                .font(.title3.weight(.bold))
                .padding(.horizontal, inset)
            switch state {
            case .idle, .loading:
                ProgressView("Loading…")
                    .padding(.horizontal, inset)
            case .empty:
                Text("This collection is empty.")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, inset)
            case let .failed(error):
                VStack(alignment: .leading, spacing: 12) {
                    Text(error.userMessage)
                    Button("Try Again", action: onRetry)
                }
                .padding(.horizontal, inset)
            case .loaded:
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(
                        alignment: .top,
                        spacing: PlozziOSMediaRailLayout.stackSpacing(
                            metrics: metrics, cardStyle: cardStyle
                        )
                    ) {
                        ForEach(items, id: \.stablePresentationID) { item in
                            Button { onSelect(item) } label: {
                                PlozziOSPosterCard(item: item)
                                    .frame(width: metrics.cardSlotWidth(
                                        for: .poster, cardStyle: cardStyle
                                    ))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, inset)
                }
                .scrollClipDisabled()
            }
        }
    }
}
#endif
