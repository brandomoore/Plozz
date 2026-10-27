#if canImport(SwiftUI)
import CoreModels
import CoreNetworking
import CoreUI
import SwiftUI

struct CollectionSectionCreationView: View {
    let inventory: HomeSectionCatalogModel
    let visibility: HomeLibraryVisibilityModel
    let libraries: [AggregatedLibrary]
    let accounts: [ResolvedAccount]
    var spoilerSettings: SpoilerSettings = .default
    @State private var section: CollectionSection?

    var body: some View {
        if let section {
            CollectionSectionSettingsView(
                section: section, isNew: true, inventory: inventory,
                visibility: visibility, libraries: libraries, accounts: accounts,
                spoilerSettings: spoilerSettings
            )
        } else {
            HeroCollectionPickerView(
                selections: .constant([]),
                libraries: libraries.filter { visibility.isEnabled($0.key) }, accounts: accounts
            ) { selection in
                section = CollectionSection(source: selection)
            }
        }
    }
}

struct CollectionSectionSettingsView: View {
    let isNew: Bool
    let inventory: HomeSectionCatalogModel
    let visibility: HomeLibraryVisibilityModel
    let libraries: [AggregatedLibrary]
    let accounts: [ResolvedAccount]
    let spoilerSettings: SpoilerSettings
    @State private var draft: CollectionSection
    @State private var preview: LoadState<[MediaItem]> = .idle
    @State private var loadedRequest: PreviewRequest?
    @State private var retry = 0
    @State private var choosingSource = false
    @State private var saveFailed = false
    @Environment(CardStyleSettingsModel.self) private var cards
    @Environment(\.plozzMetrics) private var metrics
    @SettingsPageDismiss private var dismiss

    init(
        section: CollectionSection, isNew: Bool = false,
        inventory: HomeSectionCatalogModel, visibility: HomeLibraryVisibilityModel,
        libraries: [AggregatedLibrary], accounts: [ResolvedAccount],
        spoilerSettings: SpoilerSettings = .default
    ) {
        _draft = State(initialValue: section)
        self.isNew = isNew
        self.inventory = inventory
        self.visibility = visibility
        self.libraries = libraries
        self.accounts = accounts
        self.spoilerSettings = spoilerSettings
    }

    private struct PreviewRequest: Hashable {
        let source: HeroCollectionSelection
        let credentials: [String]
        let disabledLibraries: Set<String>
        let profile: ObjectIdentifier
        let retry: Int
    }

    private var request: PreviewRequest {
        PreviewRequest(
            source: draft.source,
            credentials: accounts.flatMap {
                [$0.account.id, $0.credentialRevision.rawValue.uuidString,
                 $0.provider.session.userID, $0.plexHomeUserID ?? ""]
            },
            disabledLibraries: visibility.visibility.disabledKeys,
            profile: ObjectIdentifier(visibility), retry: retry
        )
    }

    var body: some View {
        HomeEditorPage(title: isNew ? Text("Create row") : Text("Edit row"), showsHeader: true) {
            VStack(alignment: .leading, spacing: 16) {
                Picker("Layout", selection: $draft.cardStyle) {
                    ForEach(CollectionSection.CardStyle.allCases, id: \.self) { style in
                        Text(style.title).tag(style)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("collection-section-card-style")
                Text(verbatim: draft.title).font(.headline)
                previewContent
            }
            .padding(16)
            .settingsGroupSurface(cornerRadius: 16)
            .accessibilityIdentifier("collection-section-preview")
            Button { choosingSource = true } label: {
                let choice = HomeRowChoice(collectionSection: draft)
                HomeEditorRowLabel(
                    title: Text("Content"), subtitle: choice.homeEditorSource(in: accounts),
                    subtitleProvider: choice.homeEditorProvider(in: accounts)
                )
            }
            .buttonStyle(SettingsFormButtonStyle())
            .accessibilityIdentifier("collection-section-source")
            TextField("Row name", text: $draft.name, prompt: Text(verbatim: draft.source.title))
                .accessibilityIdentifier("collection-section-name")
            Button {
                do {
                    guard accounts.contains(where: draft.source.matches) else { throw AppError.notFound }
                    try visibility.saveCollectionSection(draft, catalog: currentCatalog)
                    dismiss()
                } catch {
                    saveFailed = true
                    PlozzLog.app.error("Could not save collection section")
                }
            } label: {
                if isNew { Text("Add to Home") }
                else { Text("Save changes") }
            }
            .plozzActionButton(role: .primary)
            .disabled(!accounts.contains(where: draft.source.matches))
            .accessibilityIdentifier("collection-section-save")
            if !isNew {
                Button("Remove from Home", role: .destructive) {
                    do {
                        try visibility.setHomeSectionVisible(false, id: draft.rowID, catalog: currentCatalog)
                        dismiss()
                    } catch {
                        saveFailed = true
                        PlozzLog.app.error("Could not remove collection section")
                    }
                }
                .plozzActionButton(role: .secondary)
            }
            if saveFailed { InlineErrorMessage(Text("Couldn't update this row. Try again.")) }
        }
        .settingsPageDestination(isPresented: $choosingSource) {
            HeroCollectionPickerView(
                selections: .constant([draft.source]),
                libraries: libraries.filter { visibility.isEnabled($0.key) }, accounts: accounts
            ) { selection in
                draft.source = selection
                choosingSource = false
            }
        }
        .task(id: request) { await loadPreview() }
        .environment(\.plozzCardCaptionView, .home)
        .environment(\.plozzCardCaptionSettings, cards.captions)
        .environment(\.plozzArtworkSettings, cards.artwork)
    }

    private var currentCatalog: HomeSectionCatalog {
        inventory.currentCatalog(libraries: libraries, accounts: accounts, visibility: visibility)
    }

    @ViewBuilder
    private var previewContent: some View {
        let current = loadedRequest == request ? preview : .loading
        switch current {
        case .idle, .loading:
            ProgressView("Loading collection…")
        case .empty:
            Text("No titles in this collection.").plozzForeground(.secondary)
        case let .failed(error):
            InlineErrorMessage(Text(error.userMessage))
            Button("Retry") { retry += 1 }.plozzActionButton(role: .secondary)
        case let .loaded(items):
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(items, id: \.stablePresentationID) { item in
                        if draft.cardStyle == .featured {
                            FeaturedCardArtwork(
                                item: item, size: featuredPreviewSize, spoilerSettings: spoilerSettings
                            )
                        } else {
                            PosterCardView(
                                item: item, style: draft.cardStyle == .poster ? .poster : .landscape,
                                spoilerSettings: spoilerSettings,
                                showsActionsMenu: false, action: {}
                            )
                            .frame(width: metrics.cardSlotWidth(
                                for: draft.cardStyle == .poster ? .poster : .landscape,
                                cardStyle: cards.style
                            ))
                            .disabled(true)
                        }
                    }
                }
                .padding(8)
            }
            .scrollIndicators(.hidden)
        }
    }

    private var featuredPreviewSize: CGSize {
        #if os(tvOS)
        CGSize(width: 300, height: 375)
        #else
        CGSize(width: 260, height: 292.5)
        #endif
    }

    private func loadPreview() async {
        let requested = request
        loadedRequest = requested
        preview = .loading
        do {
            guard let account = accounts.first(where: draft.source.matches) else { throw AppError.notFound }
            let page = try await CollectionPreviewLoader.load(
                selection: requested.source, limit: 20,
                provider: account.provider, visibility: visibility.visibility
            )
            try Task.checkCancellation()
            guard request == requested else { return }
            let items = page.items.filter { $0.kind == .movie || $0.kind == .series }
            preview = items.isEmpty ? .empty : .loaded(items)
        } catch {
            guard !Task.isCancelled, !(error is CancellationError),
                  request == requested, (error as? AppError) != .cancelled else { return }
            preview = .failed((error as? AppError) ?? .invalidResponse)
            PlozzLog.app.error("Could not load collection section preview")
        }
    }
}
#endif
