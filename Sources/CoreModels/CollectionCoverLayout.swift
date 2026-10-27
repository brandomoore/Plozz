import Foundation

/// One shape for a group of collection covers, never for the movies inside it.
public enum CollectionCoverLayout: String, Codable, CaseIterable, Sendable {
    case auto, poster, landscape

    public static let `default`: Self = .auto
    public static let sampleLimit = 9

    public var title: LocalizedStringResource {
        switch self {
        case .auto:
            LocalizedStringResource(
                "collectionCoverLayout.auto", defaultValue: "Auto",
                comment: "Collection cover layout option that chooses one card shape from the collection cover image shapes."
            )
        case .poster: "Posters"
        case .landscape: "Landscape"
        }
    }

    public static func isCollectionGroup(_ items: [MediaItem]) -> Bool {
        !items.isEmpty && items.allSatisfy { $0.kind == .collection }
    }

    public func style(for items: [MediaItem]) -> LibrarySection.Style {
        switch self {
        case .poster: return .poster
        case .landscape: return .landscape
        case .auto:
            let ratios = items.prefix(Self.sampleLimit).compactMap(\.primaryImageAspectRatio)
                .filter { $0.isFinite && $0 > 0 }
            // Unknown covers do not vote; mixed ties retain the portrait default.
            return ratios.filter { $0 >= 1.33 }.count > ratios.count / 2 ? .landscape : .poster
        }
    }
}

public extension LibrarySection {
    func resolvingCollectionCovers(_ layout: CollectionCoverLayout = .default) -> Self {
        guard CollectionCoverLayout.isCollectionGroup(items) else { return self }
        var result = self
        result.style = layout.style(for: items)
        return result
    }
}
