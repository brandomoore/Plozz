#if canImport(SwiftUI)
import SwiftUI
import CoreModels

/// Shared brand mark for a media provider: the real bundled Jellyfin, Plex, and
/// Emby logo assets — the SAME logos Settings uses — instead
/// of an SF Symbol stand-in. Template-rendered with a focus-aware provider color:
/// darker on a white focus card and lighter on a black one, preserving brand
/// identity while maintaining contrast.
///
/// Lives in CoreUI so every surface (Settings, onboarding chooser, the server
/// picker) draws provider logos one identical way instead of each re-deriving
/// the asset name, brand tint, and focus behavior.
public struct ProviderBrandMark: View {
    private let provider: ProviderKind
    private let size: CGFloat
    private let showsBackground: Bool
    private let mediaShareTransport: MediaShareTransportKind?
    private let siteURL: URL?
    @Environment(\.settingsRowIsFocused) private var rowFocused
    @Environment(\.colorScheme) private var colorScheme

    public init(
        provider: ProviderKind,
        size: CGFloat = 14,
        showsBackground: Bool = true,
        mediaShareTransport: MediaShareTransportKind? = nil,
        siteURL: URL? = nil
    ) {
        self.provider = provider
        self.size = size
        self.showsBackground = showsBackground
        self.mediaShareTransport = mediaShareTransport
        self.siteURL = siteURL
    }

    private var tint: Color {
        guard rowFocused else { return Self.brandTint(provider) }
        return Self.focusedBrandTint(provider, colorScheme: colorScheme)
    }

    private var badgeBackground: Color {
        let backgroundTint = provider == .silo
            ? Color(red: 0xCD / 255.0, green: 0xB7 / 255.0, blue: 0x95 / 255.0)
            : tint
        return backgroundTint.opacity(0.18)
    }

    private var assetName: String {
        switch provider {
        case .jellyfin: "JellyfinLogo"
        case .plex: "PlexLogo"
        case .emby: "EmbyLogo"
        case .silo: "SiloLogo"
        case .subsonic: "NavidromeLogo"
        case .mediaShare, .iptv: ""
        }
    }

    /// Optical sizing for narrow marks changes only the artwork, not the badge
    /// or surrounding layout. Silo's original proportions and colors are retained.
    private var assetPadding: CGFloat {
        let base = size * (showsBackground ? 0.24 : 0.12)
        let boost: CGFloat = switch provider {
        case .plex: size * 0.07
        case .silo: (size - 2 * base) * 0.075
        default: 0
        }
        return max(0, base - boost)
    }

    /// A media share has no bundled brand logo (it isn't a product), so it draws
    /// an SF Symbol instead of a `*Logo` asset. `nil` for the real providers.
    private var systemSymbolName: String? {
        switch provider {
        case .mediaShare: "externaldrive.connected.to.line.below.fill"
        case .iptv: "antenna.radiowaves.left.and.right"
        case .jellyfin, .plex, .emby, .silo, .subsonic: nil
        }
    }

    /// The transport badge string (SMB / WebDAV / …), only for a media share that
    /// was given a transport. All file shares share ONE drive glyph and are told
    /// apart by this label; dedicated media servers never show one.
    private var badgeLabel: String? {
        guard provider == .mediaShare else { return nil }
        return mediaShareTransport?.badgeLabel
    }

    public var body: some View {
        #if canImport(UIKit)
        if provider == .iptv, let siteURL {
            ProviderSiteIcon(url: siteURL, size: size) { brandMark }
        } else {
            brandMark
        }
        #else
        brandMark
        #endif
    }

    private var brandMark: some View {
        ZStack {
            if showsBackground {
                Circle().fill(badgeBackground)
            }
            if let systemSymbolName {
                glyph(systemSymbolName)
            } else {
                Image(assetName, bundle: .module)
                    .renderingMode(provider == .silo ? .original : .template)
                    .resizable()
                    .scaledToFit()
                    .padding(assetPadding)
                    .foregroundStyle(tint)
            }
        }
        .frame(width: size, height: size)
    }

    @ViewBuilder
    private func glyph(_ symbol: String) -> some View {
        if let badgeLabel {
            VStack(spacing: size * 0.035) {
                Image(systemName: "externaldrive.fill")
                    .resizable()
                    .scaledToFit()
                    .frame(width: size * 0.64, height: size * 0.38)
                badgeText(badgeLabel)
                    .frame(height: size * 0.25)
            }
            .foregroundStyle(tint)
            // Center visible ink rather than the label's unused descender space.
            .offset(y: size * 0.025)
            .frame(width: size, height: size)
        } else {
            Image(systemName: symbol)
                .resizable()
                .scaledToFit()
                .padding(size * (showsBackground ? 0.33 : 0.23))
                .foregroundStyle(tint)
        }
    }

    @ViewBuilder
    private func badgeText(_ label: String) -> some View {   // l10n:content — transport/provider badge identifier
        Text(label)
            .font(.system(size: size * 0.22, weight: .black, design: .rounded))
            .lineLimit(1)
            .minimumScaleFactor(0.3)
            .multilineTextAlignment(.center)
            .frame(width: size * 0.82)
    }

    /// Brand accent color used to tint each provider's logo + chip.
    public static func brandTint(_ provider: ProviderKind) -> Color {
        switch provider {
        case .jellyfin:
            return Color(red: 0.53, green: 0.38, blue: 0.95)
        case .emby:
            return Color(red: 0x52 / 255, green: 0xB5 / 255, blue: 0x4B / 255)
        case .plex:
            return Color(red: 0xE5 / 255, green: 0xA0 / 255, blue: 0x0D / 255)
        case .silo:
            return Color(red: 0, green: 0x34 / 255, blue: 0xFB / 255)
        case .subsonic:
            return Color(red: 0.18, green: 0.53, blue: 0.84)
        case .mediaShare:
            // Neutral teal — reads as "storage/network", clearly not a Plex/
            // Jellyfin brand color, matching its second-class standing.
            return Color(red: 0x2A / 255, green: 0xA8 / 255, blue: 0x9E / 255)
        case .iptv:
            return Color(red: 0xF0 / 255, green: 0x63 / 255, blue: 0x74 / 255)
        }
    }

    private static func focusedBrandTint(_ provider: ProviderKind, colorScheme: ColorScheme) -> Color {
        if colorScheme == .dark {
            // Dark appearance uses a white focus card, so each brand needs a
            // deeper shade rather than collapsing to generic black.
            switch provider {
            case .jellyfin:
                return Color(red: 0.38, green: 0.25, blue: 0.78)
            case .emby:
                return Color(red: 0x2D / 255, green: 0x7D / 255, blue: 0x32 / 255)
            case .plex:
                return Color(red: 0.60, green: 0.39, blue: 0.00)
            case .silo:
                return brandTint(.silo)
            case .subsonic:
                return Color(red: 0.10, green: 0.35, blue: 0.65)
            case .mediaShare:
                return Color(red: 0.08, green: 0.46, blue: 0.43)
            case .iptv:
                return Color(red: 0xB8 / 255, green: 0x31 / 255, blue: 0x47 / 255)
            }
        }

        // Light appearance uses a black focus card; brighter variants preserve
        // the same identities against the darker surface.
        switch provider {
        case .jellyfin:
            return Color(red: 0.65, green: 0.52, blue: 0.98)
        case .emby:
            return Color(red: 0x64 / 255, green: 0xD2 / 255, blue: 0x5C / 255)
        case .plex:
            return Color(red: 0.96, green: 0.73, blue: 0.18)
        case .silo:
            return Color(red: 0.4, green: 0.6, blue: 1)
        case .subsonic:
            return Color(red: 0.4, green: 0.7, blue: 1)
        case .mediaShare:
            return Color(red: 0.36, green: 0.82, blue: 0.77)
        case .iptv:
            return Color(red: 0xFF / 255, green: 0x8F / 255, blue: 0x9F / 255)
        }
    }
}
#endif
