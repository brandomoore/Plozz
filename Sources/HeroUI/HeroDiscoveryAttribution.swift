#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI

/// Credits the feeds that contributed the displayed title, not the enabled feeds.
public struct HeroDiscoveryAttribution: View {
    @Environment(\.locale) private var locale
    private let sources: [HeroDiscoverySource]
    private let links: [String: URL]

    public init(sources: [HeroDiscoverySource], links: [String: URL] = [:]) {
        self.sources = HeroDiscoverySource.normalized(sources)
        self.links = HeroDiscoverySource.validatedURLs(links)
    }

    public var body: some View {
        if !sources.isEmpty {
            #if os(iOS)
            if sources.contains(where: { links[$0.rawValue] != nil }) {
                Menu {
                    ForEach(sources) { source in
                        if let destination = links[source.rawValue] {
                            Link(destination: destination) {
                                Text("View on \(source.displayName)")
                            }
                        }
                    }
                } label: {
                    attributionLabel
                }
                .buttonStyle(.plain)
                .accessibilityHint("Open the original discovery source.")
            } else {
                attributionLabel
                    .allowsHitTesting(false)
            }
            #else
            attributionLabel
                .allowsHitTesting(false)
            #endif
        }
    }

    private var attributionLabel: some View {
        let names = sources.map(\.displayName)
            .formatted(.list(type: .and).locale(locale))
        return Text(
            "From \(Text(verbatim: names))",
            comment: "Hero discovery credit. The variable is a list of catalog brand names, such as TMDB."
        )
        .font(.caption.weight(.medium))
        .foregroundStyle(.white)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            .black.opacity(0.68),
            in: RoundedRectangle(cornerRadius: PlozzTheme.Metrics.cornerRadius)
        )
        .accessibilityIdentifier("hero-discovery-attribution")
    }
}
#endif
