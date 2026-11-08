#if canImport(SwiftUI)
import SwiftUI
import CoreModels
#if os(tvOS)
import CoreNetworking
import UIKit
#endif

// MARK: - Environment plumbing
//
// The context menu is wired through the SwiftUI environment rather than threaded
// as closures through every `MediaRowView` / `PosterCardView` call site. The app
// installs one handler at the root (`.mediaItemActionHandler(_:)`); list screens
// that know an ordering (a season's episodes) additionally supply context with
// `.mediaItemActionContext(_:)`. Cards read both and render a native menu.

private struct MediaItemActionHandlerKey: EnvironmentKey {
    static let defaultValue: (any MediaItemActionHandling)? = nil
}

private struct MediaItemActionContextKey: EnvironmentKey {
    static let defaultValue: MediaItemActionContext = .none
}

private struct MediaItemNavigatorKey: EnvironmentKey {
    static let defaultValue: MediaItemNavigator? = nil
}

private struct MediaPersonNavigatorKey: EnvironmentKey {
    static let defaultValue: ((MediaPerson) -> Void)? = nil
}

private struct MediaPersonSourceNavigatorKey: EnvironmentKey {
    static let defaultValue: ((MediaPerson, String?) -> Void)? = nil
}

public extension EnvironmentValues {
    /// The app-supplied handler that builds and performs context-menu actions.
    /// `nil` (the default) disables the menu — e.g. in previews and tests.
    var mediaItemActionHandler: (any MediaItemActionHandling)? {
        get { self[MediaItemActionHandlerKey.self] }
        set { self[MediaItemActionHandlerKey.self] = newValue }
    }

    /// Surrounding-list context for the current subtree (e.g. a season's
    /// episodes in order), enabling list-aware actions like "watched up to here".
    var mediaItemActionContext: MediaItemActionContext {
        get { self[MediaItemActionContextKey.self] }
        set { self[MediaItemActionContextKey.self] = newValue }
    }

    /// The view-layer router used by navigation context-menu actions (e.g. "Go
    /// to Season") to push a destination. Each navigation stack installs one that
    /// appends to its own path. `nil` disables navigation actions.
    var mediaItemNavigator: MediaItemNavigator? {
        get { self[MediaItemNavigatorKey.self] }
        set { self[MediaItemNavigatorKey.self] = newValue }
    }

    /// The view-layer router used to open a person. Installed per navigation
    /// stack, exactly like ``mediaItemNavigator``. `nil` leaves cast tiles inert,
    /// which is what every surface without a stack of its own wants.
    var mediaPersonNavigator: ((MediaPerson) -> Void)? {
        get { self[MediaPersonNavigatorKey.self] }
        set { self[MediaPersonNavigatorKey.self] = newValue }
    }

    /// The same router, told WHICH server listed this person.
    ///
    /// A person id only means something to the server that issued it, and
    /// `MediaPerson` does not carry its origin — so a page that opens one has to
    /// say where it came from, or the person's own server cannot be asked for
    /// their credits at all. tvOS solves this by having each page install a
    /// navigator closed over its own account; this is the same idea expressed as
    /// one router that takes the account, so a single destination can serve every
    /// surface that pushes a person.
    var mediaPersonSourceNavigator: ((MediaPerson, String?) -> Void)? {
        get { self[MediaPersonSourceNavigatorKey.self] }
        set { self[MediaPersonSourceNavigatorKey.self] = newValue }
    }
}

public extension View {
    /// Installs the context-menu action handler for every card in this subtree.
    func mediaItemActionHandler(_ handler: (any MediaItemActionHandling)?) -> some View {
        environment(\.mediaItemActionHandler, handler)
    }

    /// Supplies ordered-list context so cards in this subtree can offer
    /// list-aware actions (e.g. "mark watched up to here" for a season's rail).
    func mediaItemActionContext(_ context: MediaItemActionContext) -> some View {
        environment(\.mediaItemActionContext, context)
    }

    /// Installs the router that navigation context-menu actions (e.g. "Go to
    /// Season") use to push a destination for this subtree's navigation stack.
    /// With `preservingInherited`, a nil callback retains the ancestor's router.
    func mediaItemNavigator(
        _ navigate: ((MediaItem) -> Void)?,
        preservingInherited: Bool = false
    ) -> some View {
        modifier(MediaItemNavigatorScope(navigate: navigate, preservingInherited: preservingInherited))
    }

    /// Installs the router that cast tiles in this subtree use to open a person.
    func mediaPersonNavigator(_ navigate: ((MediaPerson) -> Void)?) -> some View {
        environment(\.mediaPersonNavigator, navigate)
    }

    /// See ``EnvironmentValues/mediaPersonSourceNavigator``.
    func mediaPersonSourceNavigator(
        _ navigate: ((MediaPerson, String?) -> Void)?
    ) -> some View {
        environment(\.mediaPersonSourceNavigator, navigate)
    }

    /// Attaches the native tvOS press-and-hold menu for `item`, populated from
    /// the environment's action handler. A no-op when no handler is installed or
    /// the item has no available actions.
    /// Set `nativeControl` only when the content owns a `NativeTVPoster` button.
    func mediaItemContextMenu(for item: MediaItem, nativeControl: Bool = false) -> some View {
        modifier(MediaItemContextMenu(item: item, nativeControl: nativeControl))
    }

    /// Waits for the native menu to dismiss before using this card's navigation origin.
    func mediaItemMenuNavigation(target: Binding<MediaItem?>) -> some View {
        modifier(MediaItemMenuNavigation(target: target))
    }
}

private struct MediaItemMenuNavigation: ViewModifier {
    @Binding var target: MediaItem?
    @Environment(\.mediaItemNavigator) private var navigator
    #if os(iOS)
    @Environment(\.mediaArtworkZoomSource) private var artworkSource
    @Environment(\.mediaItemArtworkNavigator) private var artworkNavigator
    #endif

    func body(content: Content) -> some View {
        content.task(id: target) {
            guard let destination = target else { return }
            do {
                try await Task.sleep(for: .milliseconds(450))
            } catch {
                return
            }
            guard !Task.isCancelled, target == destination else { return }
            target = nil
            #if os(iOS)
            switch destination.kind {
            case .movie, .series, .season, .episode:
                if let artworkSource, let artworkNavigator {
                    artworkNavigator(destination, artworkSource)
                    return
                }
            default:
                break
            }
            #endif
            navigator?(destination)
        }
    }
}

private struct MediaItemNavigatorScope: ViewModifier {
    let navigate: ((MediaItem) -> Void)?
    let preservingInherited: Bool
    @Environment(\.mediaItemNavigator) private var inheritedNavigator
    @State private var relay = MediaItemNavigationRelay()

    func body(content: Content) -> some View {
        content.environment(
            \.mediaItemNavigator,
            relay.update(navigate) ?? (preservingInherited ? inheritedNavigator : nil)
        )
    }
}

/// Identity-stable routing whose latest callback can change without rebuilding
/// every card's menu. Availability still propagates through the optional value.
public struct MediaItemNavigator: Equatable {
    fileprivate let relay: MediaItemNavigationRelay

    @MainActor public init(_ navigate: @escaping (MediaItem) -> Void) {
        relay = MediaItemNavigationRelay()
        _ = relay.update(navigate)
    }

    fileprivate init(relay: MediaItemNavigationRelay) {
        self.relay = relay
    }

    @MainActor public func callAsFunction(_ item: MediaItem) {
        relay.perform(item)
    }

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.relay === rhs.relay }
}

@MainActor
fileprivate final class MediaItemNavigationRelay {
    private var navigate: ((MediaItem) -> Void)?

    func perform(_ item: MediaItem) {
        navigate?(item)
    }

    // Refresh the route's captured inputs without invalidating every card menu.
    func update(_ navigate: ((MediaItem) -> Void)?) -> MediaItemNavigator? {
        self.navigate = navigate
        return navigate == nil ? nil : MediaItemNavigator(relay: self)
    }
}

// MARK: - The menu

/// Short Select chooses the season; press-and-hold opens its watch-state menu.
public struct SeasonWatchStateMenu<MenuLabel: View>: View {
    private let season: MediaItem
    private let action: () -> Void
    private let label: MenuLabel
    @Environment(\.mediaItemActionHandler) private var handler

    public init(
        for season: MediaItem,
        action: @escaping () -> Void,
        @ViewBuilder label: () -> MenuLabel
    ) {
        self.season = season
        self.action = action
        self.label = label()
    }

    public var body: some View {
        let handler = handler
        let actions = MediaItemActionCatalog.seasonWatchActions(
            for: season,
            availableActions: handler?.actions(for: season, context: .none) ?? []
        )
        if actions.isEmpty {
            Button(action: action) { label }
        } else {
            Menu {
                ForEach(actions) { menuAction in
                    Button {
                        handler?.perform(menuAction, on: season, context: .none)
                    } label: {
                        if menuAction == .markWatched {
                            Label("Mark Season Watched", systemImage: menuAction.systemImage)
                        } else {
                            Label("Mark Season Unwatched", systemImage: menuAction.systemImage)
                        }
                    }
                }
            } label: {
                label
            } primaryAction: {
                action()
            }
            #if os(tvOS)
            .menuStyle(.button)
            #endif
        }
    }
}

/// Renders the native tvOS context menu (long-press on the focused card) for a
/// `MediaItem`, driven entirely by the injected `MediaItemActionHandling`.
public struct MediaItemContextMenu: ViewModifier {
    private let item: MediaItem
    private let nativeControl: Bool
    @Environment(\.mediaItemActionHandler) private var handler
    @Environment(\.mediaItemActionContext) private var context
    @Environment(\.mediaItemNavigator) private var navigator
    /// Navigation must wait for the native context menu's rollback animation.
    /// tvOS keeps a snapshot of the lifted card alive for roughly 300 ms after an
    /// action is chosen; replacing the screen during that window orphans the poster
    /// over the destination until the system times it out. Queueing the target lets
    /// the menu dismiss first, then the task below pushes after a small safety margin.
    @State private var pendingNavigationTarget: MediaItem?

    public init(item: MediaItem, nativeControl: Bool = false) {
        self.item = item
        self.nativeControl = nativeControl
    }

    public func body(content: Content) -> some View {
        let actions = availableActions()
        if !actions.isEmpty {
            #if os(tvOS)
            if nativeControl {
                content
                    .environment(\.nativeMediaItemMenu, NativeMediaItemMenu(
                        item: item, actions: actions, context: context,
                        handlerIdentity: handler.map(ObjectIdentifier.init),
                        navigator: navigator, perform: perform
                    ))
                    .mediaItemMenuNavigation(target: $pendingNavigationTarget)
            } else {
                swiftUIMenu(content: content, actions: actions)
            }
            #else
            swiftUIMenu(content: content, actions: actions)
            #endif
        } else {
            content
        }
    }

    private func swiftUIMenu(content: Content, actions: [MediaItemAction]) -> some View {
        let setApart = actions.filter(\.isSetApartInMenu)
        let main = actions.filter { !$0.isSetApartInMenu }
        return content.contextMenu {
            menuButtons(for: main)
            #if os(iOS)
            if let url = item.metadataProvenance.wetrakrWatchlistURL {
                WetrakrWatchlistLink(url: url)
            }
            #endif
            // Platforms that draw menu separators keep these actions apart.
            if !setApart.isEmpty {
                Section { menuButtons(for: setApart) }
            }
        }
        .mediaItemMenuNavigation(target: $pendingNavigationTarget)
    }

    @ViewBuilder
    private func menuButtons(for actions: [MediaItemAction]) -> some View {
        ForEach(actions) { action in
            Button(role: action.isDestructive ? .destructive : nil) {
                perform(action)
            } label: {
                Label(action.title, systemImage: action.systemImage)
            }
            .accessibilityLabel(Text(action.title))
            .accessibilityValue(
                action.accessibilityState.map(Text.init) ?? Text(verbatim: "")
            )
        }
    }

    /// The actions to render, dropping navigation actions when no router is
    /// installed (so they never appear as dead buttons).
    private func availableActions() -> [MediaItemAction] {
        let actions = handler?.actions(for: item, context: context) ?? []
        return actions.filter { !$0.isNavigation || navigator != nil }
    }

    private func perform(_ action: MediaItemAction) {
        if action.isNavigation {
            navigate(action)
        } else {
            handler?.perform(action, on: item, context: context)
        }
    }

    /// Routes a navigation action through the environment's router. Navigation
    /// builds a lightweight destination item from what the card already knows;
    /// the destination screen re-fetches full detail by id.
    private func navigate(_ action: MediaItemAction) {
        pendingNavigationTarget = item.navigationTarget(for: action)
    }
}

#if os(tvOS)
struct NativeMediaItemMenu {
    let item: MediaItem
    let actions: [MediaItemAction]
    var context: MediaItemActionContext = .none
    var handlerIdentity: ObjectIdentifier?
    var navigator: MediaItemNavigator?
    let perform: (MediaItemAction) -> Void
}

private struct NativeMediaItemMenuKey: EnvironmentKey {
    static var defaultValue: NativeMediaItemMenu? { nil }
}

extension EnvironmentValues {
    var nativeMediaItemMenu: NativeMediaItemMenu? {
        get { self[NativeMediaItemMenuKey.self] }
        set { self[NativeMediaItemMenuKey.self] = newValue }
    }
}

@MainActor
final class NativeMediaItemMenuCoordinator: NSObject, UIContextMenuInteractionDelegate {
    private var configuration: NativeMediaItemMenu?
    private var locale: Locale?
    private var generation = 0
    private weak var button: UIButton?
    private(set) var menu: UIMenu?
    private(set) var interaction: UIContextMenuInteraction?
    private var isPresented = false

    func update(_ configuration: NativeMediaItemMenu?, locale: Locale, button: UIButton, interactionView: UIView) {
        let siblingsMatch = (self.configuration?.context.orderedSiblings ?? []).elementsEqual(
            configuration?.context.orderedSiblings ?? []
        ) { $0.id == $1.id && $0.sourceAccountID == $1.sourceAccountID }
        let scopeChanged = self.button !== button
            || (interaction != nil && interaction?.view !== interactionView)
            || self.configuration?.item.id != configuration?.item.id
            || self.configuration?.item.sourceAccountID != configuration?.item.sourceAccountID
            || !siblingsMatch
            || self.configuration?.context.precedingContainerIDs != configuration?.context.precedingContainerIDs
            || self.configuration?.handlerIdentity != configuration?.handlerIdentity
            || self.configuration?.navigator != configuration?.navigator
        let changed = scopeChanged || self.configuration?.actions != configuration?.actions || self.locale != locale
        if let interaction, self.button !== button || interaction.view !== interactionView {
            interaction.dismissMenu()
            interaction.view?.removeInteraction(interaction)
            self.interaction = nil
            isPresented = false
        }
        self.button = button
        self.configuration = configuration
        self.locale = locale
        guard changed else { return }
        generation += 1
        guard let configuration else {
            interaction?.dismissMenu()
            if let interaction { interaction.view?.removeInteraction(interaction) }
            interaction = nil
            menu = nil
            isPresented = false
            return
        }
        if interaction == nil {
            let interaction = UIContextMenuInteraction(delegate: self)
            interactionView.addInteraction(interaction)
            self.interaction = interaction
        }
        let generation = generation
        func makeAction(_ action: MediaItemAction) -> UIAction {
            UIAction(
                title: NativePosterText.localized(action.title).resolve(locale: locale),
                image: UIImage(systemName: action.systemImage),
                attributes: action.isDestructive ? .destructive : []
            ) { [weak self] _ in
                guard let self else { return }
                guard self.generation == generation else {
                    PlozzLog.app.debug("Ignoring an obsolete media menu action after its context changed")
                    return
                }
                self.configuration?.perform(action)
            }
        }
        var children: [UIMenuElement] = configuration.actions.filter { !$0.isSetApartInMenu }.map(makeAction)
        let separated = configuration.actions.filter(\.isSetApartInMenu)
        if !separated.isEmpty {
            children.append(UIMenu(options: .displayInline, children: separated.map(makeAction)))
        }
        let menu = UIMenu(children: children)
        self.menu = menu
        if isPresented {
            if scopeChanged {
                interaction?.dismissMenu()
            } else {
                interaction?.updateVisibleMenu { _ in menu }
            }
        }
    }

    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let menu, let button, button.isEnabled, button.window != nil else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in menu }
    }

    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction, configuration: UIContextMenuConfiguration,
        highlightPreviewForItemWithIdentifier identifier: any NSCopying
    ) -> UITargetedPreview? {
        artworkPreview()
    }

    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction, configuration: UIContextMenuConfiguration,
        dismissalPreviewForItemWithIdentifier identifier: any NSCopying
    ) -> UITargetedPreview? {
        artworkPreview()
    }

    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction, willDisplayMenuFor configuration: UIContextMenuConfiguration,
        animator: (any UIContextMenuInteractionAnimating)?
    ) {
        isPresented = true
    }

    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction, willEndFor configuration: UIContextMenuConfiguration,
        animator: (any UIContextMenuInteractionAnimating)?
    ) {
        isPresented = false
    }

    private func artworkPreview() -> UITargetedPreview? {
        guard let button, button.window != nil else { return nil }
        let artwork = (button as? NativePosterButton)?.artworkView ?? button
        let parameters = UIPreviewParameters()
        parameters.backgroundColor = .clear
        return UITargetedPreview(view: artwork, parameters: parameters)
    }
}
#endif

extension MediaItem {
    /// The destination a navigation action leads to, or `nil` when this item
    /// can't reach one. Shared so a hero's "…" menu and a card's long-press menu
    /// route identically.
    public func navigationTarget(for action: MediaItemAction) -> MediaItem? {
        switch action {
        case .goToSeason:
            return seasonNavigationTarget
        case .goToMovie, .goToEpisode:
            // The item itself is the destination; the page re-fetches full
            // detail by id.
            return self
        case .browseFiles:
            guard let fileBrowserContainerID, !fileBrowserContainerID.isEmpty else { return nil }
            return MediaItem(
                id: fileBrowserContainerID,
                title: title,
                kind: .folder,
                allowsTitleBasedMetadataMatching: false,
                sourceAccountID: sourceAccountID
            )
        case .markWatched, .markUnwatched, .markWatchedUpToHere,
             .addToWatchlist, .removeFromWatchlist, .refreshMetadata,
             .startDownload, .pauseDownload, .resumeDownload, .removeDownload,
             .removeFromContinueWatching:
            return nil
        }
    }

    /// What "add to watchlist" means for this row.
    ///
    /// An episode is not watchlistable — you cannot save "episode 4" for later in
    /// any sense a viewer means — so the subject of the gesture is the show it
    /// belongs to. Without this the button simply vanished wherever a hero fronted
    /// an episode, which is most of Continue Watching and every series page that
    /// has resolved its next episode.
    ///
    /// Falls back to the item itself when the show cannot be identified, so the
    /// button is never wired to something arbitrary.
    public var watchlistSubject: MediaItem {
        guard kind == .episode || kind == .season else { return self }
        guard let seriesID else { return self }
        return MediaItem(
            id: seriesID,
            title: parentTitle ?? title,
            kind: .series,
            sourceAccountID: sourceAccountID
        )
    }

    /// The destination for "Go to Season". Preferred: the full **series** detail
    /// page (rich hero, badges, season tabs, episode rail) with this episode's
    /// season pre-selected, carried in `seasonID`. Falls back to a bare season
    /// page only when the series id is unknown. The destination screen reloads
    /// full data by `id`, so only `id`, `kind`, the season hint and the owning
    /// account need to be accurate here.
    var seasonNavigationTarget: MediaItem? {
        if let seriesID {
            return MediaItem(
                id: seriesID,
                title: parentTitle ?? "Series",
                kind: .series,
                seasonID: seasonID,
                sourceAccountID: sourceAccountID
            )
        }
        guard let seasonID else { return nil }
        let title = seasonNumber.map { "Season \($0)" } ?? "Season"
        return MediaItem(
            id: seasonID,
            title: title,
            kind: .season,
            parentTitle: parentTitle,
            seasonNumber: seasonNumber,
            sourceAccountID: sourceAccountID
        )
    }
}

#endif
