import Foundation

/// A portable caption-family choice or an installed font's PostScript name.
/// System descriptors are resolved on the playing device, never serialized.
public enum SubtitleSystemFont: Codable, Equatable, Hashable, Sendable {
    case caption(CaptionFamily)
    case named(String)

    public enum CaptionFamily: String, Codable, CaseIterable, Sendable {
        case `default`, monospacedSerif, proportionalSerif, monospacedSansSerif
        case proportionalSansSerif, casual, cursive, smallCapitals

        public var displayName: LocalizedStringResource {
            switch self {
            case .default: "Default"
            case .monospacedSerif: "Monospaced Serif"
            case .proportionalSerif: "Proportional Serif"
            case .monospacedSansSerif: "Monospaced Sans Serif"
            case .proportionalSansSerif: "Proportional Sans Serif"
            case .casual: "Casual"
            case .cursive: "Cursive"
            case .smallCapitals: "Small Capitals"
            }
        }
    }
}
