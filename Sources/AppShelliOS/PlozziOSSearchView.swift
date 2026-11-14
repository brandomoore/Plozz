#if os(iOS)
import CoreModels
import FeatureSearchCore
import SwiftUI
import CoreUI

struct PlozziOSSearchView: View {
    private var navigationTitles = NavigationTitles()
    @Environment(\.plozzMetrics) private var metrics
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.plozziOSUsesVerticalToolbar) private var usesVerticalToolbar
    @Environment(\.plozziOSIsOverflowDestination) private var isOverflowDestination
    @FocusState private var isSearchFocused: Bool
    @State private var viewModel: SearchViewModel
    private let appModel: PlozziOSAppModel
    private let onShowSettings: () -> Void
    private let keepsNavigationBar: Bool

    init(
        appModel: PlozziOSAppModel,
        onShowSettings: @escaping () -> Void,
        keepsNavigationBar: Bool = false
    ) {
        self.appModel = appModel
        self.onShowSettings = onShowSettings
        self.keepsNavigationBar = keepsNavigationBar
        _viewModel = State(
            initialValue: SearchViewModel(
                accounts: appModel.accountsProviders.homeAccounts,
                identitySources: appModel.identityIndex.identitySourcesProvider,
                disabledLibraryKeys: { [weak appModel] in
                    appModel?.settings.homeVisibility.visibility.disabledKeys
                        ?? []
                },
                seerSearch: { [seer = appModel.seerService] query in
                    guard !OfflineMode.shared.isEnabled else { return [] }
                    return (try? await seer.search(query)) ?? []
                },
                seerRequestAvailability: { [seer = appModel.seerService] item in
                    guard !OfflineMode.shared.isEnabled else { return nil }
                    return await seer.requestAvailability(for: item)
                }
            )
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            PlozziOSSearchHeader(
                query: $viewModel.query,
                isFocused: $isSearchFocused,
                onShowSettings: onShowSettings
            )
            .zIndex(1)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .simultaneousGesture(TapGesture().onEnded { isSearchFocused = false })
        }
        // Compact tabs do not need a second bar above the explicit Search header.
        // Regular-width iPad keeps the bar so the system sidebar toggle remains
        // reachable when the adaptable tab sidebar is collapsed.
        .toolbar(
            horizontalSizeClass == .compact && !keepsNavigationBar && !usesVerticalToolbar ? .hidden : .visible,
            for: .navigationBar
        )
        .toolbar {
            if usesVerticalToolbar || isOverflowDestination {
                PlozziOSSettingsToolbarItem(action: onShowSettings)
            }
        }
        .navigationTitle(isOverflowDestination
            ? navigationTitles(NavigationLibraryLayout.searchKey, default: Text("Search")) : Text(verbatim: ""))
        .toolbarTitleDisplayMode(.inline)
        .environment(\.plozzCardCaptionView, .search)
        .task(id: viewModel.query) {
            await viewModel.search()
        }
        .onReceive(NotificationCenter.default.publisher(for: .mediaItemDidMutate)) { note in
            if let mutation = MediaItemMutation.from(note) {
                viewModel.applyWatchedState(mutation)
            } else {
                Task { await viewModel.search() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .identityIndexDidUpdate)) { _ in
            guard !viewModel.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return
            }
            Task { await viewModel.search() }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .idle:
            ContentUnavailableView(
                "Search your libraries",
                systemImage: "magnifyingglass",
                description: Text("Find movies, TV shows, and episodes across your servers.")
            )
        case .loading:
            ProgressView("Searching…")
        case .empty:
            ContentUnavailableView.search(text: viewModel.query)
        case let .failed(error):
            ContentUnavailableView {
                Label("Search unavailable", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error.userMessage)
            } actions: {
                Button("Try Again") {
                    Task { await viewModel.search() }
                }
            }
        case let .loaded(sections):
            results(sections)
        }
    }

    private func results(_ sections: [SearchSection]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: PlozziOSMediaRailLayout.sectionGap(metrics: metrics)) {
                ForEach(sections) { section in
                    PlozziOSMediaSection(title: Text(section.title)) {
                        LazyVGrid(
                            columns: appModel.settings.density.density.iOSPosterGridColumns(
                                horizontalSizeClass: horizontalSizeClass, isRunningOnMac: metrics.usesDesktopSizing
                            ),
                            spacing: 18
                        ) {
                            ForEach(section.items) { item in
                                PlozziOSSearchResultCard(
                                    item: item,
                                    provider: provider(for: item)
                                )
                            }
                        }
                        .padding(.horizontal, PlozziOSPageLayout.horizontalInset(for: horizontalSizeClass))
                    }
                }
            }
            .padding(.vertical)
        }
        .scrollDismissesKeyboard(.interactively)
        .scrollClipDisabled()
    }

    private func provider(for item: MediaItem) -> (any MediaProvider)? {
        if let accountID = item.sourceAccountID {
            return appModel.accountsProviders.provider(forAccountID: accountID)
        }
        return appModel.accountsProviders.primaryProvider
    }
}

/// Keep a local Settings entry only when native navigation does not expose it.
private struct PlozziOSSearchHeader: View {
    private var navigationTitles = NavigationTitles()
    @Environment(\.themePalette) private var palette
    @Environment(\.plozzReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.hasVisibleSettingsNavigationEntry) private var hasVisibleSettingsNavigationEntry
    @Environment(\.plozziOSUsesVerticalToolbar) private var usesVerticalToolbar
    @Environment(\.plozziOSIsOverflowDestination) private var isOverflowDestination
    @Binding var query: String
    @FocusState.Binding var isFocused: Bool
    let onShowSettings: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                PlozziOSPageHeading(navigationTitles(NavigationLibraryLayout.searchKey, default: Text("Search")))
                if !hasVisibleSettingsNavigationEntry && !usesVerticalToolbar && !isOverflowDestination {
                    PlozziOSSettingsAvatarButton(action: onShowSettings)
                        .accessibilityIdentifier("search-settings-avatar")
                }
            }
            .padding(.bottom, hidesTitle ? 0 : 12)
            .frame(height: hidesTitle ? 0 : nil, alignment: .top)
            .opacity(hidesTitle ? 0 : 1)
            .clipped()
            .allowsHitTesting(!hidesTitle)
            .accessibilityHidden(hidesTitle)

            HStack(spacing: 12) {
                searchField
                if isActive {
                    cancelButton
                        .transition(.opacity)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .animation(reduceMotion ? nil : .smooth(duration: 0.4), value: isActive)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .plozzForeground(.secondary)
            TextField(
                "Movies, shows, and episodes",
                text: $query,
                prompt: Text("Movies, shows, and episodes").foregroundColor(palette.secondaryText)
            )
            .focused($isFocused)
            .textFieldStyle(.plain)
            .foregroundStyle(palette.primaryText)
            .autocorrectionDisabled()
            .submitLabel(.search)
            .accessibilityLabel("Search your libraries")
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .plozzForeground(.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 44)
        .background { fieldBackground }
        .contentShape(Capsule())
        .onTapGesture { isFocused = true }
        .frame(maxWidth: .infinity)
    }

    private var hidesTitle: Bool { isActive || isOverflowDestination }

    private var isActive: Bool {
        isFocused || !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @ViewBuilder
    private var cancelButton: some View {
        let button = Button("Cancel search", systemImage: "xmark") {
            query = ""
            isFocused = false
        }
        .labelStyle(.iconOnly)
        .buttonBorderShape(.circle)
        .controlSize(.large)
        if #available(iOS 26.0, *), !reduceTransparency {
            button.buttonStyle(.glass)
        } else {
            button.buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    private var fieldBackground: some View {
        let flat = Capsule()
            .fill(palette.raised.fill)
            .overlay {
                if let border = palette.raised.border {
                    Capsule().strokeBorder(border, lineWidth: palette.raised.borderWidth)
                }
            }
        if #available(iOS 26.0, *), !reduceTransparency {
            // Keep both surfaces mounted; replacing the field on focus loses
            // its first responder and can interrupt typing.
            ZStack {
                flat.opacity(isActive ? 0 : 1)
                Color.clear
                    .glassEffect(.regular, in: Capsule())
                    .opacity(isActive ? 1 : 0)
            }
        } else {
            flat
        }
    }
}

private struct PlozziOSSearchResultCard: View {
    @Environment(PlozziOSAppModel.self) private var appModel
    let item: MediaItem
    let provider: (any MediaProvider)?

    var body: some View {
        Group {
            if let provider {
                NavigationLink {
                    PlozziOSItemDetailView(
                        appModel: appModel,
                        provider: provider,
                        item: item,
                        seerService: appModel.seerService
                    )
                } label: {
                    card
                }
                .buttonStyle(.plain)
            } else {
                card
            }
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 6) {
            PlozziOSPosterCard(
                item: item
            )
            if let cue = SearchSection.availabilityCue(for: item) {
                Label(cue, systemImage: "rectangle.stack.badge.plus")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tint)
            }
        }
    }
}
#endif
