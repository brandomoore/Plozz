#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI
import FeatureProfiles

/// Shared providers for Settings sub-views.
///
/// Bundled into a single value so each detail page can pull what it needs
/// without `SettingsView`'s init exploding to 30+ parameters.
struct SettingsContext {
    let spoilers: SpoilerSettingsModel
    let playback: PlaybackSettingsModel
    let theme: ThemeSettingsModel
    let homeVisibility: HomeLibraryVisibilityModel
    let discoveredLibraries: LoadState<[AggregatedLibrary]>
    let refreshingLibraryAccountIDs: Set<String>
    /// Accounts whose most-recent library fetch failed (server offline /
    /// unreachable), so the My Libraries screen can distinguish "couldn't reach
    /// this server" from a genuinely empty one.
    let unreachableLibraryAccountIDs: Set<String>
    var libraryFailures: [String: AppError] = [:]
    let reloadLibraries: () async -> Void
    let accounts: [Account]
    let activeAccountID: String?
    let profiles: [Profile]
    let activeProfile: Profile
    let automaticSignIn: AutomaticSignInSettings
    let isAccountIncludedInActiveProfile: (String) -> Bool
    let onSetAccountIncluded: (String, Bool) -> Void
    let onSwitchProfile: () -> Void
    let onSaveProfile: (ProfileDraft) -> Void
    /// Creates a NEW profile and hands it to the app-level setup step. Distinct
    /// from `onSaveProfile`, which also edits existing ones.
    let onCreateProfile: (ProfileDraft) -> Void
    /// Live cosmetics-only persistence for editing an existing profile.
    let onUpdateProfileCosmetics: (ProfileDraft) -> Void
    let onDeleteProfile: (String) -> Void
    /// Pushes a route onto the Settings NavigationStack that owns this page.
    ///
    /// A pushed page must NOT declare its own `navigationDestination` for the
    /// same stack: SwiftUI allows one per level, and a second one attached from
    /// inside an already-pushed view invalidates without settling — the page
    /// re-runs its body ~180 times a second and the screen stops responding.
    /// Sub-pages therefore push through the stack's own route type.
    let pushRoute: (SettingsRoute) -> Void
    let onAddAccount: () -> Void
    /// Whether the household has a Parental PIN, which is what decides if a Kids
    /// Profile is enforced or merely simplified. See ``ParentalPIN``.
    var hasParentalPIN: Bool = false
    /// Whether the Parental PIN has been entered, unsealing this Kids Profile's
    /// restricted settings for now.
    var isParentalUnlocked: Bool = false
    /// Verifies a candidate Parental PIN.
    var matchesParentalPIN: (String) -> Bool = { _ in false }
    /// Records a successful Parental PIN entry.
    var onParentalUnlock: () -> Void = {}
    /// Sets or clears the household's Parental PIN.
    var onSetParentalPIN: (ParentalPIN?) -> Void = { _ in }
    /// Signs in another user on an already-added server.
    let onAddUser: (MediaServer) -> Void
    let onRemoveAccount: (Account) -> Void
    /// Remove a server from EVERY device on this iCloud account (household tombstone).
    let onRemoveAccountEverywhere: (Account) -> Void
    /// Whether a "Remove Everywhere" choice is meaningful here: cross-device sync is on
    /// AND the account has at least one other device to remove it from. When false the
    /// remove UI shows a single plain "Remove".
    let offersRemoveEverywhere: Bool
    /// Force a fresh scan + enrichment of a media share now (its account id).
    let onRescanShare: (String) -> Void
    let onSignOutAll: () -> Void
    let plexHomeUsersFetcher: (String) async -> [PlexHomeUser]
    let onSelectPlexHomeUser: (String, PlexHomeUser?) -> Void
    /// Sets (or clears, with `nil`) a profile's PIN gate. Takes an
    /// already-derived `ProfileLock` so the raw PIN never leaves the entry view.
    ///
    /// Keyed by profile id rather than acting on the active one: locks are
    /// managed for the whole household from Everyone › Profiles, the way Netflix
    /// does it, so a grown-up can lock their own profile from a child's device
    /// without switching into it first.
    let onSetProfileLock: (String, ProfileLock?) -> Void
    let validatePlexPIN: (String, String) async -> PlexPINValidationResult
    /// Marks a profile as restricted (or lifts it).
    let onSetKidsProfile: (String, Bool) -> Void
    /// Whether a profile's PIN has already been proved this run, so a locked
    /// profile's settings stay sealed until someone enters it.
    let isProfileUnlocked: (String) -> Bool
    /// Records that a profile's PIN was just proved.
    let onProfileUnlocked: (String) -> Void
}

/// Typed routes for the Settings drill-down NavigationStack. Defined at file
/// scope (not nested in `SettingsView`) so detail pages can push their own
/// destinations onto the same stack — `ServersAndLibrariesDetailView` uses
/// this to drill from a server summary row into `ServerDetailView`, and a
/// future per-account flow can do the same without re-plumbing closures.
public enum SettingsRoute: Hashable {
    case language
    case screensNavigation
    case allScreens
    case about
    case artwork
    case navigationLayout
    case profile
    case liveTV
    /// Per-profile settings page (Everyone › Profiles › <name>).
    case profileSettings(profileID: String)
    /// The Parental PIN prompt that unseals a Kids Profile's restricted
    /// settings. A pushed page, not a modal — modals asked for from inside the
    /// Settings tab are unreliable (see the Edit button note in `SettingsView`).
    case grownUps
    /// The profile's own name, avatar and colour. Kept OUT of Parental
    /// Controls: it can't escalate anything, and a Kids Profile should still be
    /// able to choose how it looks.
    case profileAppearance(profileID: String)
    /// Choosing or changing one profile's own lock PIN.
    case profileLockSetup(profileID: String)
    /// Creating the household's Parental PIN.
    case parentalPINSetup
    /// The household's Parental PIN settings (Everyone › Parental PIN).
    case parentalPIN
    case topShelf
    case servers
    case myLibraries
    case appearance
    case customizeHome
    case customizeLibraries
    case detailPage
    case nightShift
    case playback
    case subtitles
    case subtitleStyle(liveTV: Bool)
    case spoilers
    case integrations
    case metadata
    case metadataDiagnostics
    case seerr
    case syncSetup
    case syncTroubleshooting
    case seerUserPicker(profileID: String)
    case releaseNotes
    case attributions
    case help
    case recentActivity
    case plexUser(accountID: String)
    /// Jellyfin/Emby "Watching as" — the server's sign-ins, plus adding one.
    case serverUser(serverKey: String)
    case server(key: String)
}

enum SettingsRouteAccess: Equatable {
    case allowed, parentalPIN, adultProfile
}

extension SettingsRoute {
    var usesFullScreenDetail: Bool {
        switch self {
        case .subtitleStyle, .profileAppearance, .profileLockSetup, .parentalPINSetup:
            return true
        default:
            return false
        }
    }

    func access(activeProfileID: String, isKids: Bool, isParentalSealed: Bool) -> SettingsRouteAccess {
        guard isKids else { return .allowed }
        switch self {
        case .profile, .servers, .server, .parentalPIN, .topShelf,
             .metadata, .metadataDiagnostics, .seerr, .seerUserPicker,
             .syncSetup, .syncTroubleshooting:
            return .adultProfile
        case .myLibraries, .plexUser, .serverUser, .parentalPINSetup:
            return isParentalSealed ? .parentalPIN : .allowed
        case let .profileSettings(profileID), let .profileLockSetup(profileID):
            guard profileID == activeProfileID else { return .adultProfile }
            return isParentalSealed ? .parentalPIN : .allowed
        case let .profileAppearance(profileID):
            return profileID == activeProfileID ? .allowed : .adultProfile
        default:
            return .allowed
        }
    }
}

/// Settings navigation state that survives a top-bar/sidebar/rail shell swap.
///
/// MainTabView owns this model's identity but never reads its path. The Settings
/// workspace observes depth without invalidating the app's large root tab body.
@MainActor
@Observable
public final class SettingsNavigationModel {
    #if os(tvOS)
    let pages = SettingsPageNavigation<SettingsRoute>()
    var path: [SettingsRoute] {
        get { pages.routes }
        set { pages.routes = newValue }
    }
    #else
    var path: [SettingsRoute] = []
    #endif
    var section: SettingsRoute = .playback
    var isCategoryOpen: Bool {
        #if os(tvOS)
        !pages.pages.isEmpty
        #else
        !path.isEmpty
        #endif
    }
    var focusInDetail = false
    var restoringSidebar = true
    var enteringDetail = false
    var sidebarFocusRequest = 0
    var detailFocusRequest = 0
    /// Live row mirrored in Appearance's detail pane. Stored beside the path so
    /// replacing the surrounding tab/sidebar shell restores not only Appearance,
    /// but the exact feature row the viewer was editing inside it.
    var appearanceRowID: String?

    public init() {}

    func openArtwork() {
        appearanceRowID = "artwork"
        select(.appearance)
        path = [.appearance, .artwork]
        enterDetail()
    }

    func openMetadataProviders() {
        reveal(.metadata)
    }

    private func reveal(_ route: SettingsRoute) {
        select(route)
        enterDetail()
    }

    func select(_ route: SettingsRoute) {
        guard section != route else { return }
        resetPages()
        section = route
    }

    func enterDetail(sourceID: UUID? = nil) {
        restoringSidebar = false
        enteringDetail = true
        detailFocusRequest += 1
        if !isCategoryOpen {
            #if os(tvOS)
            pages.push(section, sourceID: sourceID)
            #else
            path = [section]
            #endif
        }
    }

    func returnToSidebar() {
        resetPages()
        restoreCategoryFocus()
    }

    func restoreCategoryFocus() {
        #if os(tvOS)
        let categoryAlreadyFocused = !focusInDetail && !enteringDetail && !restoringSidebar
        #endif
        enteringDetail = false
        focusInDetail = false
        #if os(tvOS)
        if pages.returnSourceID != nil {
            // A fading parent can regain native focus before the transition finishes.
            restoringSidebar = !categoryAlreadyFocused
            return
        }
        #endif
        restoringSidebar = true
        sidebarFocusRequest += 1
    }

    func resetForProfile() {
        resetPages()
        section = .playback
        appearanceRowID = nil
        returnToSidebar()
    }

    private func resetPages() {
        #if os(tvOS)
        pages.reset()
        #else
        path.removeAll()
        #endif
    }
}

extension View {
    @ViewBuilder
    func settingsWorkspaceEntry(_ isEntry: Bool = true, route: SettingsRoute? = nil) -> some View {
        #if os(tvOS)
        modifier(SettingsWorkspaceEntryFocus(isEntry: isEntry, route: route))
        #else
        self
        #endif
    }
}

#if os(tvOS)
private struct SettingsWorkspaceEntryFocus: ViewModifier {
    let isEntry: Bool
    let route: SettingsRoute?
    @Environment(SettingsNavigationModel.self) private var navigation: SettingsNavigationModel?
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content
            .focused($focused)
            .task(id: navigation?.detailFocusRequest) {
                guard isEntry, let navigation, navigation.enteringDetail,
                      navigation.path.last == route else { return }
                focused = false
                await Task.yield()
                guard !Task.isCancelled, navigation.enteringDetail,
                      navigation.path.last == route else { return }
                focused = true
            }
    }
}
#endif

extension EdgeInsets {
    /// The default uniform `SettingsPanel` inset — fine for text / non-row content.
    static var settingsPanelDefault: EdgeInsets {
        EdgeInsets(top: SettingsFormMetrics.pageInset, leading: SettingsFormMetrics.pageInset,
                   bottom: SettingsFormMetrics.pageInset, trailing: SettingsFormMetrics.pageInset)
    }

    /// `SettingsPanel` inset tuned so list-row controls inside focus
    /// **concentrically** with the panel: 28pt horizontal / 16pt vertical, i.e.
    /// the focus card's outward bleed (16pt H / 4pt V in `SettingsFocusButtonStyle`)
    /// plus a uniform 12pt gap on every side. Use for a panel whose content is a
    /// stack of toggle / checkable / selector rows (which also pass
    /// `flushLeading: false`).
    static var settingsPanelRowContent: EdgeInsets {
        EdgeInsets(top: PlozzTheme.Spacing.medium, leading: SettingsFormMetrics.pageInset,
                   bottom: PlozzTheme.Spacing.medium, trailing: SettingsFormMetrics.pageInset)
    }
}

/// A titled section rendered as a translucent panel. Reused by every Settings
/// detail page so the visual treatment is consistent.
struct SettingsPanel<Content: View>: View {
    @Environment(\.themePalette) private var palette
    let title: LocalizedStringResource?
    var subtitle: LocalizedStringResource?
    var footer: LocalizedStringResource?
    var contentPadding: EdgeInsets
    var showsSurface: Bool
    @ViewBuilder let content: Content

    init(
        title: LocalizedStringResource? = nil,
        subtitle: LocalizedStringResource? = nil,
        footer: LocalizedStringResource? = nil,
        contentPadding: EdgeInsets = .settingsPanelDefault,
        showsSurface: Bool = true,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.footer = footer
        self.contentPadding = contentPadding
        self.showsSurface = showsSurface
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if title != nil || subtitle != nil {
                VStack(alignment: .leading, spacing: 6) {
                    if let title {
                        Text(title)
                            .font(.subheadline.weight(.semibold))
                            .textCase(.uppercase)
                            .tracking(1.0)
                            .plozzForeground(.secondary)
                    }
                    if let subtitle {
                        Text(subtitle)
                            #if os(tvOS)
                            .font(SettingsRowMetrics.helperFont)
                            #else
                            .font(.footnote)
                            #endif
                            .plozzForeground(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            content
            if let footer {
                Text(footer)
                    #if os(tvOS)
                    .font(SettingsRowMetrics.helperFont)
                    #else
                    .font(.footnote)
                    #endif
                    .plozzForeground(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(contentPadding)
        .modifier(ConditionalRaisedSurface(active: showsSurface, cornerRadius: PlozzTheme.Metrics.mediumCardCornerRadius))
    }
}

/// Applies the shared `.raised` elevation surface only when a Settings panel
/// wants its own container, so plain inline panels stay transparent.
private struct ConditionalRaisedSurface: ViewModifier {
    let active: Bool
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        if active {
            content.settingsGroupSurface(cornerRadius: cornerRadius)
        } else {
            content
        }
    }
}

/// A `SettingsPanel` that can itself take focus, for panels whose content is
/// **read-only** (or whose only control is disabled) and would otherwise be
/// unreachable on tvOS — a non-focusable view never receives focus, so the
/// parent `ScrollView` can't scroll it into view and the user gets stuck.
///
/// Rather than the About panel's stark inverted-card contrast flip, focus here
/// is shown the way round artwork (avatars, cast portraits, profile tiles) shows
/// it: a soft, **theme-tinted outline** blooming around the whole element (plus a
/// gentle lift), so contrast never inverts and the panel's resting look is
/// identical to every other `SettingsPanel`.
struct FocusableSettingsPanel<Content: View>: View {
    let title: LocalizedStringResource?
    var footer: LocalizedStringResource?
    /// Optional remote-select handler. When set, clicking the focused panel with
    /// the Siri remote invokes it — used only by the About panel to drive the
    /// hidden Developer Mode unlock gesture (seven selects on the Version row).
    var onActivate: (() -> Void)?
    @ViewBuilder let content: Content

    init(
        title: LocalizedStringResource? = nil,
        footer: LocalizedStringResource? = nil,
        onActivate: (() -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.footer = footer
        self.onActivate = onActivate
        self.content = content()
    }

    var body: some View {
        SettingsPanel(title: title, footer: footer, showsSurface: false) { content }
            .plozzFocusableCard(cornerRadius: PlozzTheme.Metrics.mediumCardCornerRadius)
            .plozzAdaptiveCardSurface()
            .accessibilityElement(children: .combine)
            .onTapGesture { onActivate?() }
    }
}

/// Shared provider chip + icon used across Settings detail pages.
struct ProviderBadge: View {
    let provider: ProviderKind
    var size: CGFloat = 14

    var body: some View {
        HStack(spacing: 4) {
            ProviderIcon(provider: provider, size: size)
            Text(provider.displayName)
        }
        .fixedSize()
    }
}

struct ProviderIcon: View {
    let provider: ProviderKind
    var size: CGFloat = 14
    var mediaShareTransport: MediaShareTransportKind? = nil
    var siteURL: URL? = nil

    var body: some View {
        // Delegates to the shared CoreUI mark so provider logos, brand tints,
        // the media-share drive glyph, and its transport badge have one
        // implementation across the app.
        #if os(tvOS)
        if provider == .iptv {
            ProviderSiteIcon(url: siteURL, size: size) {
                ProviderBrandMark(provider: provider, size: size)
            }
        } else {
            ProviderBrandMark(provider: provider, size: size, mediaShareTransport: mediaShareTransport)
        }
        #else
        ProviderBrandMark(provider: provider, size: size, mediaShareTransport: mediaShareTransport)
        #endif
    }

    static func tint(_ provider: ProviderKind) -> Color {
        ProviderBrandMark.brandTint(provider)
    }
}

/// Small avatar circle for an account — image-first, falls back to an
/// initial-letter placeholder. Used by Profile and Servers detail pages.
struct AccountAvatar: View {
    let name: String
    let imageURL: URL?
    var size: CGFloat = 40

    @Environment(\.settingsRowIsFocused) private var isFocused
    @Environment(\.settingsRowFocusForeground) private var focusForeground
    @Environment(\.themePalette) private var palette

    var body: some View {
        Group {
            if let imageURL {
                AsyncImage(url: imageURL) { phase in
                    switch phase {
                    case let .success(image):
                        image
                            .resizable()
                            .scaledToFill()
                    case .empty, .failure:
                        placeholder
                    @unknown default:
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(
            Circle().strokeBorder(Color.primary.opacity(0.14), lineWidth: 1)
        )
    }

    private var placeholder: some View {
        ZStack {
            Circle().fill(
                isFocused
                    ? focusForeground.opacity(0.16)
                    : palette.primaryText.opacity(0.10)
            )
            Text(String(name.prefix(1)).uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(
                    isFocused ? focusForeground : palette.secondaryText
                )
        }
    }
}

/// Builds the Jellyfin/Emby avatar URL fallback when `avatarURL` is nil.
func resolvedAvatarURL(for account: Account) -> URL? {
    if let avatarURL = account.avatarURL { return avatarURL }
    guard account.server.provider.usesMediaBrowserAPI,
          var components = URLComponents(url: account.server.baseURL, resolvingAgainstBaseURL: false) else {
        return nil
    }
    let basePath = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
    components.path = basePath + "/Users/\(account.userID)/Images/Primary"
    return components.url
}
#endif
