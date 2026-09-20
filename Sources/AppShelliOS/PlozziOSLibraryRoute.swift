#if os(iOS)
import SwiftUI
import CoreModels
import FeatureHomeCore

/// A pushed library grid, addressed by value rather than by an eagerly-built view.
///
/// `NavigationLink { PlozziOSLibraryGridView(viewModel: LibraryBrowseViewModel(…)) }`
/// rebuilds its destination — and a brand-new view model — every time the
/// *source* body re-evaluates, even while that destination is already pushed.
/// Opening a movie makes the detail page search the other configured servers for
/// the same title; when those responses land they touch observed state that Home
/// reads, Home re-evaluates, and the grid sitting under the detail page is
/// remounted. Its `.task` then re-runs `loadFirstPage()`, which sets
/// `state = .loading` and clears `loaded`, so returning from the detail page
/// showed a reloading grid scrolled back to the top. Measured on device: exactly
/// one reload per movie opened.
///
/// A value-typed route hands ownership of the destination to the navigation
/// stack, which builds it once for the life of the push. The route deliberately
/// carries only `Hashable` identity — the provider is resolved inside the
/// destination builder, since providers are reference types whose identity would
/// otherwise re-trigger the same rebuild.
struct PlozziOSLibraryRoute: Hashable, Identifiable {
    var title: String   // l10n:content — library name from the server
    var containerID: String
    var containerKind: MediaItemKind
    var accountID: String?
    var synthesizedName: MediaLibrary.SynthesizedName?
    var collectionSourceTitle: String?
    var browseScope: LibraryBrowseScope

    /// Stable across the value's lifetime so it can also drive a
    /// `navigationDestination(item:)` push (the screenshot router's path). The
    /// Scope distinguishes a collection-list library from collection membership,
    /// even if a server happens to reuse the same container id for both.
    var id: String { "\(accountID ?? "")#\(browseScope.rawValue)#\(containerID)" }

    init(library: MediaLibrary, accountID: String?) {
        self.title = library.title
        self.containerID = library.id
        self.containerKind = library.kind
        self.accountID = accountID
        self.synthesizedName = library.synthesizedName
        self.collectionSourceTitle = library.collectionSourceTitle
        self.browseScope = .library
    }

    init(collection: CollectionBrowseRoute) {
        title = collection.title
        containerID = collection.collectionID
        containerKind = .collection
        accountID = collection.accountID
        synthesizedName = nil
        collectionSourceTitle = nil
        browseScope = .collectionMembers
    }
}

/// The library grid a ``PlozziOSLibraryRoute`` resolves to.
///
/// Extracted from the destination closure so the value-typed push (from a
/// `NavigationLink`) and the programmatic push (the screenshot router's
/// `navigationDestination(item:)`) build the identical page rather than two
/// copies that could drift.
struct PlozziOSLibraryDestinationView: View {
    @Environment(\.locale) private var locale
    let appModel: PlozziOSAppModel
    let route: PlozziOSLibraryRoute

    private var provider: (any MediaProvider)? {
        if let accountID = route.accountID {
            return appModel.accountsProviders.provider(forAccountID: accountID)
        }
        return appModel.accountsProviders.primaryProvider
    }

    private var title: String { // l10n:content - provider name or locale-scoped resource bridged to the grid's String API
        let library = MediaLibrary(
            id: route.containerID,
            title: route.title,
            kind: route.containerKind,
            synthesizedName: route.synthesizedName,
            collectionSourceTitle: route.collectionSourceTitle
        )
        guard var resource = library.localizedTitle else { return route.title }
        resource.locale = locale
        return String(localized: resource) // l10n:content - recomputed from the observed locale, never cached
    }

    var body: some View {
        if let provider {
            PlozziOSLibraryGridView(
                viewModel: LibraryBrowseViewModel(
                    provider: provider,
                    containerID: route.containerID,
                    containerKind: route.containerKind,
                    sourceAccountID: route.accountID,
                    browseScope: route.browseScope
                ),
                title: title,
                provider: provider,
                settings: appModel.settings,
                scanStatus: appModel.shareScanStatus
            )
        } else {
            ContentUnavailableView(
                "Server unavailable",
                systemImage: "exclamationmark.triangle",
                description: Text("This library's server is no longer connected.")
            )
        }
    }
}

extension View {
    /// Installs the library-grid destination for a navigation stack.
    func plozziOSLibraryDestination(appModel: PlozziOSAppModel) -> some View {
        navigationDestination(for: PlozziOSLibraryRoute.self) { route in
            PlozziOSLibraryDestinationView(appModel: appModel, route: route)
        }
    }
}
#endif
