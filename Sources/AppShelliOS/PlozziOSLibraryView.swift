#if os(iOS)
import CoreModels
import CoreUI
import FeatureHomeCore
import Observation
import SwiftUI

@MainActor
@Observable
final class PlozziOSLibrariesModel {
    private(set) var state: LoadState<[MediaLibrary]> = .idle

    func load(provider: (any MediaProvider)?) async {
        guard let provider else {
            state = .empty
            return
        }
        state = .loading
        do {
            let libraries = try await provider.libraries()
                .filter { !$0.isMusic }
            state = libraries.isEmpty ? .empty : .loaded(libraries)
        } catch is CancellationError {
            return
        } catch let error as AppError {
            state = .failed(error)
        } catch {
            state = .failed(.unknown(error.localizedDescription))
        }
    }
}

struct PlozziOSLibrariesView: View {
    @State private var model = PlozziOSLibrariesModel()

    let appModel: PlozziOSAppModel
    let onAddServer: () -> Void

    var body: some View {
        Group {
            switch model.state {
            case .idle, .loading:
                ProgressView("Loading libraries…")
            case .empty:
                ContentUnavailableView {
                    Label("No video libraries", systemImage: "rectangle.stack")
                } description: {
                    Text("This server did not return any movie or TV libraries.")
                }
            case let .loaded(libraries):
                PlozziOSLibraryList(
                    libraries: libraries,
                    provider: appModel.accountsProviders.primaryProvider,
                    settings: appModel.settings
                )
            case let .failed(error):
                ContentUnavailableView {
                    Label("Unable to load libraries", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error.userMessage)
                } actions: {
                    Button("Try Again") {
                        Task {
                            await model.load(
                                provider: appModel.accountsProviders.primaryProvider
                            )
                        }
                    }
                }
            }
        }
        .navigationTitle("Home")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Add Server", systemImage: "plus", action: onAddServer)
            }
        }
        .task(id: appModel.accounts.map(\.credentialRevision)) {
            await model.load(provider: appModel.accountsProviders.primaryProvider)
        }
    }
}

private struct PlozziOSLibraryList: View {
    let libraries: [MediaLibrary]
    let provider: (any MediaProvider)?
    let settings: PlozziOSSettingsModel

    var body: some View {
        ScrollView {
            LazyVGrid(
                columns: [
                    GridItem(.adaptive(minimum: 170, maximum: 260), spacing: 16)
                ],
                spacing: 16
            ) {
                ForEach(libraries) { library in
                    if provider != nil {
                        // Value-based so the pushed grid survives a re-render of
                        // this list; see PlozziOSLibraryRoute.
                        NavigationLink(
                            value: PlozziOSLibraryRoute(
                                library: library,
                                accountID: library.sourceAccountID
                            )
                        ) {
                            PlozziOSLibraryCard(library: library)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding()
        }
    }
}

private struct PlozziOSLibraryCard: View {
    @Environment(\.plozzCardStyle) private var cardStyle
    @Environment(\.plozzMetrics) private var metrics
    @Environment(\.themePalette) private var palette
    let library: MediaLibrary

    @ViewBuilder
    var body: some View {
        if cardStyle == .framed {
            content
                .plozzFramedMediaCard(
                    innerCornerRadius: PlozzTheme.Metrics.mediumMediaCornerRadius
                )
                .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
        } else {
            content
        }
    }

    private var content: some View {
        VStack(
            alignment: .leading,
            spacing: metrics.landscapeCaptionTopSpacing
        ) {
            AsyncImage(url: library.imageURL) { image in
                image
                    .resizable()
                    .scaledToFill()
            } placeholder: {
                Rectangle()
                    .fill(palette.fill)
                    .overlay {
                        Image(systemName: library.kind == .series ? "tv" : "film")
                            .font(.largeTitle)
                            .plozzForeground(.secondary)
                    }
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(16 / 10, contentMode: .fit)
            .clipShape(
                RoundedRectangle(
                    cornerRadius: PlozzTheme.Metrics.mediumMediaCornerRadius,
                    style: .continuous
                )
            )
            .plozzMediaEdge(
                cornerRadius: PlozzTheme.Metrics.mediumMediaCornerRadius
            )

            library.displayName
                .font(.headline)
                .lineLimit(2)
                .padding(.horizontal, metrics.landscapeCaptionInset)
                .padding(
                    .bottom,
                    cardStyle == .framed ? metrics.landscapeCaptionInset : 0
                )
        }
        .contentShape(Rectangle())
    }
}

struct PlozziOSLibraryGridView: View {
    @Environment(PlozziOSAppModel.self) private var appModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.plozzMetrics) private var metrics
    /// Per-profile card presentation. Decides how far a grid card insets its
    /// artwork, which is what the banner's edges have to match.
    @Environment(\.plozzCardStyle) private var cardStyle
    @State private var viewModel: LibraryBrowseViewModel
    @State private var selectedRecommendedItem: MediaItem?
    private let title: String   // l10n:content — library name from the server
    private let provider: any MediaProvider
    private let settings: PlozziOSSettingsModel
    /// App-wide media-share scan/enrich status, feeding the banner above the grid.
    /// Passed rather than read from the environment so the pushed destination
    /// carries it explicitly, like every other dependency on this route.
    private let scanStatus: ShareScanStatusModel?

    init(
        viewModel: LibraryBrowseViewModel,
        title: String,   // l10n:content — library name from the server
        provider: any MediaProvider,
        settings: PlozziOSSettingsModel,
        scanStatus: ShareScanStatusModel? = nil
    ) {
        _viewModel = State(initialValue: viewModel)
        self.title = title
        self.provider = provider
        self.settings = settings
        self.scanStatus = scanStatus
    }

    var body: some View {
        let generation = viewModel.contentGeneration
        Group {
            if viewModel.contentMode == .recommended {
                recommendedContent
            } else {
                browseContent(generation: generation)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $selectedRecommendedItem) { item in
            PlozziOSItemDetailView(
                appModel: appModel,
                provider: provider,
                item: item,
                originSourceAccountID: item.sourceAccountID
            )
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if (viewModel.availableContentModes.count > 1 || !viewModel.availableSortFields.isEmpty),
               viewModel.contentMode == .recommended
                    ? viewModel.recommendationState.value == nil
                    : (viewModel.state.value == nil || viewModel.state.value == 0) {
                browseControls
                    .background(.bar)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if viewModel.contentMode == .recommended, let error = viewModel.recommendationError,
               viewModel.recommendationState.value != nil {
                HStack {
                    Text(error.userMessage).plozzForeground(.secondary)
                    Button("Try Again") { Task { await viewModel.loadRecommendations() } }
                }
                .padding()
                .background(.regularMaterial)
            }
            if viewModel.contentMode != .recommended, let error = viewModel.pageError {
                HStack {
                    Text(error.userMessage)
                        .plozzForeground(.secondary)
                    Button("Try Again") {
                        Task { await viewModel.retryFailedPages() }
                    }
                }
                .padding()
                .background(.regularMaterial)
            }
        }
        .toolbar {
            if viewModel.alphabet.isVisible {
                ToolbarItem(placement: .primaryAction) {
                    LibraryAlphabetMenu(entries: viewModel.letterEntries, isLoading: viewModel.alphabet.isLoading,
                                        isJumping: viewModel.alphabet.jumpingTo != nil,
                                        onSelect: { letter, id in viewModel.beginLetterJump(letter, menuPresentationID: id) },
                                        onDismiss: viewModel.alphabet.menuDidDismiss,
                                        onCancel: viewModel.cancelLetterJump,
                                        onRetry: viewModel.retryLetterIndex)
                }
            }
            if let library = viewModel.fileBrowserLibrary {
                ToolbarItem(placement: .primaryAction) {
                    NavigationLink(
                        value: PlozziOSLibraryRoute(
                            library: library,
                            accountID: library.sourceAccountID ?? provider.session.server.id
                        )
                    ) {
                        Label("Browse Files", systemImage: "folder")
                    }
                }
            }
        }
        .task { await viewModel.loadFirstPageIfNeeded() }
        .background {
            LibraryAlphabetFeedback(letter: viewModel.alphabet.jumpingTo, message: viewModel.alphabet.message)
        }
        .onDisappear { viewModel.cancelPendingQuery() }
        .plozziOSLibraryDestination(appModel: appModel)
        .background {
            if viewModel.isMediaShare {
                ShareCatalogRefreshObserver(
                    shareID: viewModel.sourceServerID,
                    status: scanStatus
                ) {
                    await viewModel.refreshAfterCatalogChange()
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .mediaItemDidMutate)) { note in
            if let mutation = MediaItemMutation.from(note) {
                viewModel.applyWatchedState(mutation)
            }
        }
    }

    @ViewBuilder
    private var recommendedContent: some View {
        switch viewModel.recommendationState {
        case .idle, .loading:
            ProgressView("Loading recommendations…")
        case .empty:
            ContentUnavailableView("No recommendations in this library", systemImage: "sparkles")
        case .loaded(let sections):
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    browseControls
                    ForEach(sections) { section in
                        MediaRowView(
                            title: Text(verbatim: section.title),
                            items: section.items,
                            style: section.style == .poster ? .poster : .landscape,
                            showsSeriesArtwork: section.id == "continueWatching"
                                && settings.homeVisibility.continueWatchingShowsSeriesArtwork,
                            showsResumeChip: section.id == "continueWatching",
                            onSelect: { selectedRecommendedItem = $0 }
                        )
                    }
                }
                .padding(.vertical, 12)
            }
        case .failed(let error):
            ContentUnavailableView {
                Label("Unable to load recommendations", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error.userMessage)
            } actions: {
                Button("Try Again") { Task { await viewModel.loadRecommendations() } }
            }
        }
    }

    @ViewBuilder
    private func browseContent(generation: Int) -> some View {
            switch viewModel.state {
            case .idle, .loading:
                if let progress = viewModel.queryProgress {
                    LibraryQueryPreparationView(progress: progress) { Task { await viewModel.cancelIndex() } }
                } else { ProgressView("Loading \(title)…") }
            case .empty:
                ContentUnavailableView {
                    Label {
                        Text(viewModel.emptyMessage)
                    } icon: {
                        Image(systemName: "rectangle.stack")
                    }
                }
            case let .loaded(total):
                if total == 0 {
                    ContentUnavailableView {
                        Label {
                            Text(viewModel.emptyMessage)
                        } icon: {
                            Image(systemName: "rectangle.stack")
                        }
                    }
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            browseControls
                            scanBanner
                            LazyVGrid(
                                columns: settings.density.density.iOSPosterGridColumns(
                                    horizontalSizeClass: horizontalSizeClass
                                ),
                                spacing: 18
                            ) {
                                ForEach(0..<total, id: \.self) { index in
                                    PlozziOSLibraryItemCell(
                                        slot: viewModel.slot(at: index),
                                        index: index,
                                        generation: generation,
                                        provider: provider,
                                        playlistOrigin: { viewModel.playlistOrigin(at: index) },
                                        onAppear: { await viewModel.itemAppeared(at: index, generation: generation) },
                                        onDisappear: { viewModel.itemDisappeared(at: index, generation: generation) }
                                    )
                                    .id(index)
                                }
                            }
                            .padding()
                        }
                        .onChange(of: viewModel.alphabet.destination) { _, destination in
                            if let destination { proxy.scrollTo(destination.index, anchor: .top) }
                        }
                    }
                    .id(viewModel.contentMode)
                }
            case let .failed(error):
                ContentUnavailableView {
                    Label("Unable to load \(title)", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(viewModel.queryMessage ?? error.userMessage)
                } actions: {
                    Button("Try Again") {
                        Task { await viewModel.loadFirstPage() }
                    }
                }
            }
        }

    @ViewBuilder
    private var browseControls: some View {
        if viewModel.availableContentModes.count > 1 || !viewModel.availableSortFields.isEmpty {
            HStack {
                if viewModel.availableContentModes.count > 1 {
                    PlozziOSLibraryContentModeControl(viewModel: viewModel)
                }
                Spacer(minLength: 12)
                if viewModel.showsFilterMenu {
                    LibraryFilterMenu(
                        filters: viewModel.filters, capabilities: viewModel.queryCapabilities, facets: viewModel.queryFacets,
                        isLoading: viewModel.facetsLoading, hasError: viewModel.facetsError != nil,
                        onChange: { value in Task { await viewModel.setFilters(value) } },
                        onLoadFacets: { await viewModel.loadQueryFacetsIfNeeded() },
                        onRetry: { Task { await viewModel.loadQueryFacetsIfNeeded(retry: true) } }
                    )
                    .labelStyle(.iconOnly)
                    .frame(minWidth: 44, minHeight: 44)
                }
                if !viewModel.availableSortFields.isEmpty {
                    sortControl
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }

    /// Live scan/enrich progress for the media share backing THIS library, above
    /// the grid so it explains a wall that's short or still growing. Renders
    /// nothing for a server-backed library or an idle share, and does its own
    /// status lookup so progress ticks never reach the grid.
    ///
    /// Horizontally it lines up with the poster ARTWORK below it, not the grid's
    /// column edges: a card insets its artwork inside its own surface, so matching
    /// only the grid padding leaves the banner overhanging every poster by that
    /// inset. Matches the tvOS treatment exactly.
    @ViewBuilder
    private var scanBanner: some View {
        if viewModel.isMediaShare {
            ShareScanProgressBanner(
                status: scanStatus,
                shareID: viewModel.sourceServerID
            )
            .padding(.horizontal, Self.gridInset + posterArtworkInset)
            .padding(.top, Self.gridInset)
        }
    }

    /// How far a grid card insets its artwork inside its own footprint.
    private var posterArtworkInset: CGFloat {
        cardStyle == .framed ? metrics.cardInset : metrics.borderlessCardSideMargin
    }

    /// The grid's own `.padding()` — matched so the banner starts from the same
    /// edge before the artwork inset is added.
    private static let gridInset: CGFloat = 16

    private var sortControl: some View {
        Menu {
            Picker("Sort By", selection: sortFieldBinding) {
                ForEach(viewModel.availableSortFields, id: \.self) { field in
                    Text(field.displayName).tag(field)
                }
            }
            Picker("Order", selection: sortDirectionBinding) {
                ForEach(SortDirection.allCases, id: \.self) { direction in
                    Text(direction.displayName).tag(direction)
                }
            }
        } label: {
            Label(
                "Sort: \(viewModel.sort.field.displayName)",
                systemImage: "arrow.up.arrow.down"
            )
            .labelStyle(.iconOnly)
            .frame(minWidth: 44, minHeight: 44)
        }
    }

    private var sortFieldBinding: Binding<SortField> {
        Binding(
            get: { viewModel.sort.field },
            set: { field in
                Task {
                    await viewModel.setSort(
                        CoreModels.SortDescriptor(
                            field: field,
                            direction: field.defaultDirection
                        )
                    )
                }
            }
        )
    }

    private var sortDirectionBinding: Binding<SortDirection> {
        Binding(
            get: { viewModel.sort.direction },
            set: { direction in
                Task {
                    await viewModel.setSort(
                        CoreModels.SortDescriptor(
                            field: viewModel.sort.field,
                            direction: direction
                        )
                    )
                }
            }
        )
    }
}

private struct PlozziOSLibraryContentModeControl: View {
    let viewModel: LibraryBrowseViewModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        Group {
            if horizontalSizeClass == .compact {
                modePicker.pickerStyle(.menu)
            } else {
                modePicker.pickerStyle(.segmented)
            }
        }
        .accessibilityIdentifier("library-content-mode")
    }

    private var modePicker: some View {
        Picker("Show", selection: Binding(
            get: { viewModel.contentMode },
            set: { mode in Task { await viewModel.setContentMode(mode) } }
        )) {
            ForEach(viewModel.availableContentModes, id: \.self) { mode in
                Text(mode.displayName).tag(mode)
            }
        }
    }
}

private struct PlozziOSLibraryItemCell: View {
    @Environment(PlozziOSAppModel.self) private var appModel
    let slot: LibrarySlot?
    let index: Int
    let generation: Int
    let provider: any MediaProvider
    let playlistOrigin: () -> VideoPlaylistPlaybackOrigin?
    let onAppear: () async -> Void
    let onDisappear: () -> Void

    var body: some View {
        Group {
            if let item = slot?.item {
                if let route = CollectionBrowseRoute(
                    item: item, fallbackAccountID: provider.session.server.id
                ) {
                    NavigationLink(value: PlozziOSLibraryRoute(collection: route)) {
                        card
                    }
                    .buttonStyle(.plain)
                } else if let library = MediaFolderNavigation.library(
                    for: item,
                    providerKind: provider.kind
                ) {
                    NavigationLink(
                        value: PlozziOSLibraryRoute(
                            library: library,
                            accountID: library.sourceAccountID ?? provider.session.server.id
                        )
                    ) {
                        card
                    }
                    .buttonStyle(.plain)
                } else {
                    NavigationLink {
                        PlozziOSItemDetailView(
                            appModel: appModel,
                            provider: provider,
                            item: item,
                            originSourceAccountID: item.sourceAccountID,
                            playlistOrigin: playlistOrigin()
                        )
                    } label: {
                        card
                    }
                    .buttonStyle(.plain)
                }
            } else {
                card
            }
        }
        .task(id: generation) { await onAppear() }
        .onDisappear(perform: onDisappear)
    }

    private var card: some View {
        Group {
            if let item = slot?.item, item.kind == .folder {
                MediaFolderCardLabel(item: item)
            } else {
                PlozziOSPosterCard(
                    item: slot?.item,
                    reservesSubtitleSpace: true
                )
            }
        }
    }
}
#endif
