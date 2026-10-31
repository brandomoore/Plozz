#if os(iOS)
import CoreModels
import FeatureSearchCore
import SwiftUI
import CoreUI

struct PlozziOSSearchView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.plozziOSUsesVerticalToolbar) private var usesVerticalToolbar
    @Environment(\.plozziOSIsOverflowDestination) private var isOverflowDestination
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
                    (try? await seer.search(query)) ?? []
                },
                seerRequestAvailability: { [seer = appModel.seerService] item in
                    await seer.requestAvailability(for: item)
                }
            )
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            PlozziOSSearchHeader(
                query: $viewModel.query,
                onShowSettings: onShowSettings
            )
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        .navigationTitle(horizontalSizeClass == .compact && !isOverflowDestination ? Text(verbatim: "") : Text("Search"))
        .toolbarTitleDisplayMode(isOverflowDestination ? .inline : .large)
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
            LazyVStack(alignment: .leading, spacing: PlozziOSMediaRailLayout.sectionSpacing) {
                ForEach(sections) { section in
                    PlozziOSMediaSection(title: Text(section.title)) {
                        LazyVGrid(
                            columns: appModel.settings.density.density.iOSPosterGridColumns(
                                horizontalSizeClass: horizontalSizeClass
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
    @Environment(\.themePalette) private var palette
    @Environment(\.hasVisibleSettingsNavigationEntry) private var hasVisibleSettingsNavigationEntry
    @Environment(\.plozziOSUsesVerticalToolbar) private var usesVerticalToolbar
    @Environment(\.plozziOSIsOverflowDestination) private var isOverflowDestination
    @Binding var query: String
    let onShowSettings: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .plozzForeground(.secondary)
                TextField(
                    "Movies, shows, and episodes",
                    text: $query,
                    prompt: Text("Movies, shows, and episodes").foregroundColor(palette.secondaryText)
                )
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
            .plozzSurface(.raised, cornerRadius: PlozzTheme.Metrics.Radius.card)
            .frame(maxWidth: .infinity)

            if !hasVisibleSettingsNavigationEntry && !usesVerticalToolbar && !isOverflowDestination {
                PlozziOSSettingsAvatarButton(action: onShowSettings)
                    .accessibilityIdentifier("search-settings-avatar")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
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
