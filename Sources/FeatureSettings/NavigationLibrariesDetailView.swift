#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI

/// Shared navigation arrangement. Hiding a shortcut never disables its content.
public struct NavigationLibrariesDetailView: View {
    let scope: ProfileLibrariesScope
    let navigation: NavigationStyleSettingsModel
    let includesIndividualLibraries: Bool
    let excludedKeys: Set<String>

    @State private var isReordering = false
    @State private var renamedKey: String?
    @State private var renamedTitle = Text(verbatim: "")
    @State private var showsNameEditor = false

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
        .settingsPageDestination(isPresented: $showsNameEditor) {
            [renamedKey, renamedTitle, navigation, visibility = scope.homeVisibility] in
            if let renamedKey {
                NavigationNameEditor(
                    key: renamedKey,
                    defaultTitle: renamedTitle,
                    navigation: navigation, visibility: visibility
                )
                .id(ObjectIdentifier(visibility))
            }
        }
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
        let keys = NavigationDestinationDefaults.iOS(
            visibleLibraries: includesIndividualLibraries ? visible : []
        )
        let automaticallyHiddenDestinations = NavigationDestinationDefaults.iOSAutomaticallyHiddenKeys(available: keys)
        #else
        let keys = NavigationRailPlan.customizableKeys(
            visibleLibraries: includesIndividualLibraries ? visible : [], style: navigation.style
        )
        let automaticallyHiddenDestinations: Set<String> = []
        #endif
        let available = navigation.availableNavigationKeys(keys).filter { !excludedKeys.contains($0) }
        let titles = Self.rowsByKey(visible: visible)
        let sections = navigation.librarySections(
            available: available, automaticallyHiddenKeys: automaticallyHiddenDestinations
        )
        #if os(iOS)
        let requiredEnabled = sections.enabled.count == 1 ? Set(sections.enabled) : navigation.requiredNavigationKeys
        #else
        let requiredEnabled = navigation.style == .tabBar && sections.enabled.count == 1
            ? Set(sections.enabled) : navigation.requiredNavigationKeys
        #endif

        VStack(alignment: .leading, spacing: sectionSpacing) {
            LiftableReorderList(
                sections: sections,
                disabledSectionTitle: Self.hiddenDivider,
                disabledPlaceholder: Self.hiddenPlaceholder,
                isLifting: $isReordering,
                requiredEnabled: requiredEnabled,
                onMove: { navigation.recordNavigationMove(of: $0) },
                onRename: {
                    renamedKey = $0
                    renamedTitle = titles[$0]?.title ?? Text(verbatim: $0)
                    showsNameEditor = true
                },
                row: { key in
                    var row = titles[key] ?? LiftableReorderList.Row(title: Text(verbatim: key))
                    if let name = navigation.libraryLayout.customName(
                        for: key, homeVisibility: scope.homeVisibility.visibility
                    ) {
                        row.title = Text(verbatim: name)
                    }
                    return row
                },
                onChange: {
                    navigation.applyLibrarySections(
                        $0, available: available, automaticallyHiddenKeys: automaticallyHiddenDestinations
                    )
                }
            )

            Text(footnote)
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
            .buttonStyle(SettingsFormButtonStyle())
            #endif
            .disabled(isReordering)
        }
    }

    /// Content glyphs match navigation; provider and server share the subtitle.
    static func rowsByKey(
        visible: [AggregatedLibrary]
    ) -> [String: LiftableReorderList<String>.Row] {
        var rows: [String: LiftableReorderList<String>.Row] = [
            NavigationLibraryLayout.homeKey: .init(title: Text("Home"), symbolName: "house.fill"),
            NavigationLibraryLayout.searchKey: .init(title: Text("Search"), symbolName: "magnifyingglass"),
            NavigationLibraryLayout.watchlistKey: .init(title: Text("Watchlist"), symbolName: "bookmark.fill"),
            NavigationLibraryLayout.discoverKey: .init(title: Text("Discover"), symbolName: "sparkles"),
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
                symbolName: aggregated.library.navigationSymbolName,
                providerKind: aggregated.providerKind,
                mediaShareTransport: aggregated.transportKind,
                subtitle: Text(verbatim: aggregated.serverName),
                providerMarkInSubtitle: true
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
    private var footnote: LocalizedStringResource { Self.mobileFootnote }
    private static let mobileFootnote = LocalizedStringResource(
        "navigationArrangement.footnote.iOS",
        defaultValue: "Drag to reorder. Hold to rename, hide, or show.",
        comment: "Instructions for arranging iPhone and iPad navigation tabs."
    )
    #else
    private var footnote: LocalizedStringResource {
        navigation.style == .tabBar ? Self.topBarFootnote : Self.sidebarFootnote
    }
    private static let topBarFootnote = LocalizedStringResource(
        "navigationArrangement.footnote.horizontal",
        defaultValue: "Press and hold to rename, hide, show, or move. Settings stays fixed until moved. Settings is also in the profile picker.",
        comment: "Instructions for arranging the scrolling horizontal navigation."
    )
    private static let sidebarFootnote = LocalizedStringResource(
        "navigationArrangement.footnote",
        defaultValue: "Press and hold an item to rename, hide, show, or move it. Unused pages hide automatically unless you show them. Settings always stays visible.",
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

struct NavigationNameEditor: View {
    let key: String
    let defaultTitle: Text
    let navigation: NavigationStyleSettingsModel
    let visibility: HomeLibraryVisibilityModel
    @State private var name: String
    @FocusState private var isNameFocused: Bool

    init(key: String, defaultTitle: Text, navigation: NavigationStyleSettingsModel, visibility: HomeLibraryVisibilityModel) {
        self.key = key
        self.defaultTitle = defaultTitle
        self.navigation = navigation
        self.visibility = visibility
        _name = State(initialValue: navigation.libraryLayout.customName(for: key, homeVisibility: visibility.visibility) ?? "")
    }

    var body: some View {
        HomeEditorPage(title: defaultTitle, showsHeader: true) {
            SettingsSectionGroup {
                #if os(tvOS)
                HomeEditorAutosavingNameInput(
                    "Name", name: name, prompt: defaultTitle, identifier: "navigation-name-input"
                ) { value in
                    navigation.renameDestination(key, to: value, homeVisibility: visibility)
                }
                #else
                SettingsInputRow("Name") {
                    TextField("Name", text: $name, prompt: defaultTitle)
                        .focused($isNameFocused)
                        .submitLabel(.done)
                        #if os(iOS)
                        .onSubmit { isNameFocused = false }
                        #else
                        .onSubmit(save)
                        #endif
                        .accessibilityIdentifier("navigation-name-input")
                }
                #endif
            }
            #if !os(iOS) && !os(tvOS)
            Button(action: save) {
                Text("Save changes").plozzPageActionLabel()
            }
            .plozzPageActionButton()
            .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines)
                == (navigation.libraryLayout.customName(for: key, homeVisibility: visibility.visibility) ?? ""))
            .accessibilityIdentifier("navigation-name-save")
            #endif
        }
        #if os(iOS)
        .modifier(HomeEditorSaveAction(
            isEnabled: name.trimmingCharacters(in: .whitespacesAndNewlines)
                != (navigation.libraryLayout.customName(for: key, homeVisibility: visibility.visibility) ?? ""),
            identifier: "navigation-name-save", action: save
        ))
        #endif
    }

    private func save() {
        navigation.renameDestination(key, to: name, homeVisibility: visibility)
        name = navigation.libraryLayout.customName(for: key, homeVisibility: visibility.visibility) ?? ""
        isNameFocused = false
    }
}
#endif
