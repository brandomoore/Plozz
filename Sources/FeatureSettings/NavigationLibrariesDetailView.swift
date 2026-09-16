#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI
#if os(iOS)
import UIKit
#endif

/// Shared navigation arrangement. Hiding a shortcut never disables its content.
public struct NavigationLibrariesDetailView: View {
    let scope: ProfileLibrariesScope
    let navigation: NavigationStyleSettingsModel
    let includesIndividualLibraries: Bool
    let excludedKeys: Set<String>

    @State private var isReordering = false

    public init(
        scope: ProfileLibrariesScope,
        navigation: NavigationStyleSettingsModel,
        includesIndividualLibraries: Bool = true,
        excludedKeys: Set<String> = []
    ) {
        self.scope = scope
        self.navigation = navigation
        self.includesIndividualLibraries = includesIndividualLibraries
        self.excludedKeys = excludedKeys
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: sectionSpacing) {
            content(for: discoveredLibraries)
            switch scope.discoveredLibraries {
            case .idle, .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, alignment: .center)
            case .empty:
                Text(Self.noLibraries)
                    .font(.callout)
                    .plozzForeground(.secondary)
            case .failed:
                Text(Self.unavailable)
                    .font(.callout)
                    .plozzForeground(.secondary)
            case .loaded:
                EmptyView()
            }
        }
        .task { await scope.reloadLibraries() }
    }

    private var discoveredLibraries: [AggregatedLibrary] {
        guard case let .loaded(libraries) = scope.discoveredLibraries else { return [] }
        return libraries
    }

    private var sectionSpacing: CGFloat {
        #if os(iOS)
        PlozzTheme.Spacing.medium
        #else
        SettingsMetrics.sectionSpacing
        #endif
    }

    @ViewBuilder
    private func content(for all: [AggregatedLibrary]) -> some View {
        let visible = all.filter { scope.homeVisibility.isEnabled($0.key) }
        #if os(iOS)
        let keys = NavigationDestinationDefaults.iOS
        #else
        let keys = NavigationRailPlan.customizableKeys(
            visibleLibraries: includesIndividualLibraries ? visible : [], style: navigation.style
        )
        #endif
        let available = keys.filter { !excludedKeys.contains($0) }
        let titles = Self.rowsByKey(visible: visible)
        let sections = navigation.librarySections(available: available)
        #if os(iOS)
        let overflow = UIDevice.current.userInterfaceIdiom == .phone
            ? NavigationDestinationDefaults.iPhoneOverflowKeys(visible: sections.enabled) : []
        let requiredEnabled = sections.enabled.count == 1 ? Set(sections.enabled) : navigation.requiredNavigationKeys
        #else
        let overflow: Set<String> = []
        let requiredEnabled = navigation.requiredNavigationKeys
        #endif

        VStack(alignment: .leading, spacing: sectionSpacing) {
            LiftableReorderList(
                sections: sections,
                disabledSectionTitle: Self.hiddenDivider,
                disabledPlaceholder: Self.hiddenPlaceholder,
                isLifting: $isReordering,
                requiredEnabled: requiredEnabled,
                row: { key in
                    var row = titles[key] ?? LiftableReorderList.Row(title: Text(verbatim: key))
                    if overflow.contains(key) { row.detail = Text("In More") }
                    return row
                },
                onChange: { navigation.applyLibrarySections($0, available: available) }
            )

            Text(Self.footnote)
                .font(.caption)
                .plozzForeground(.secondary)

            Button(role: .destructive) {
                navigation.resetLibraryLayout()
            } label: {
                Label {
                    Text(Self.resetTitle)
                } icon: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .frame(maxWidth: .infinity)
            }
            #if os(iOS)
            .buttonStyle(.borderless)
            #else
            .buttonStyle(SettingsFocusButtonStyle())
            #endif
            .disabled(isReordering)
        }
    }

    /// One row descriptor per arrangeable key: library name, provider brand mark,
    /// and server name so same-named libraries on different servers are distinct.
    private static func rowsByKey(
        visible: [AggregatedLibrary]
    ) -> [String: LiftableReorderList<String>.Row] {
        var rows: [String: LiftableReorderList<String>.Row] = [
            NavigationLibraryLayout.homeKey: .init(title: Text("Home"), symbolName: "house.fill"),
            NavigationLibraryLayout.searchKey: .init(title: Text("Search"), symbolName: "magnifyingglass"),
            NavigationLibraryLayout.watchlistKey: .init(title: Text("Watchlist"), symbolName: "bookmark.fill"),
            NavigationLibraryLayout.musicKey: .init(title: Text("Music"), symbolName: "music.note"),
            NavigationLibraryLayout.downloadsKey: .init(title: Text("Downloads"), symbolName: "arrow.down.circle"),
            NavigationLibraryLayout.settingsKey: .init(title: Text("Settings"), symbolName: "gearshape.fill"),
            NavigationLibraryLayout.allLibrariesKey: LiftableReorderList<String>.Row(
                title: Text(AllLibrariesBrowse.title),
                symbolName: "square.stack.3d.up.fill"
            )
        ]
        rows[NavigationLibraryLayout.liveTVKey] = .init(title: Text("Live TV"), symbolName: "antenna.radiowaves.left.and.right")
        for aggregated in NavigationRailPlan.browsableLibraries(visible) {
            rows[aggregated.key] = LiftableReorderList<String>.Row(
                title: aggregated.library.displayName,
                providerKind: aggregated.providerKind,
                mediaShareTransport: aggregated.transportKind,
                detail: Text(verbatim: aggregated.serverName)
            )
        }
        return rows
    }

    // MARK: - Copy

    private static let hiddenDivider = LocalizedStringResource(
        "navigationArrangement.hiddenDivider",
        defaultValue: "Hidden",
        comment: "Divider before shortcuts hidden from navigation."
    )
    private static let hiddenPlaceholder = LocalizedStringResource(
        "navigationArrangement.hiddenPlaceholder",
        defaultValue: "Hidden items appear here. Move them back up or choose Show to restore them.",
        comment: "Empty-state drop target under the Hidden divider."
    )
    #if os(iOS)
    private static let footnote = LocalizedStringResource(
        "navigationArrangement.footnote.iOS",
        defaultValue: "Drag to reorder. Hold to hide or show.",
        comment: "Instructions for arranging iPhone and iPad navigation tabs."
    )
    #else
    private static let footnote = LocalizedStringResource(
        "navigationArrangement.footnote",
        defaultValue: "Press and hold an item to hide, show, or move it. Hiding a shortcut doesn't remove its content. Settings always stays visible.",
        comment: "Instructions and the always-visible Settings safety rule for navigation customization."
    )
    #endif
    private static let resetTitle = LocalizedStringResource(
        "navigationArrangement.reset",
        defaultValue: "Reset Navigation",
        comment: "Button that restores the default navigation arrangement."
    )
    private static let noLibraries = LocalizedStringResource(
        "navigationArrangement.none",
        defaultValue: "Add a server to arrange its library shortcuts here too.",
        comment: "Shown when the household has no libraries to arrange."
    )
    private static let unavailable = LocalizedStringResource(
        "navigationArrangement.unavailable",
        defaultValue: "Couldn't load your library shortcuts. Their saved arrangement is unchanged.",
        comment: "Shown when library discovery failed while arranging the navigation."
    )
}
#endif
