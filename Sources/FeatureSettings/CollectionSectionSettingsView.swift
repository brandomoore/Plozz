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
    @State private var section = CollectionSection(sources: [])

    var body: some View {
        CollectionSectionSettingsView(
                section: section, isNew: true, inventory: inventory,
                visibility: visibility, libraries: libraries, accounts: accounts,
                spoilerSettings: spoilerSettings
        )
    }
}

struct CollectionSectionSettingsView: View {
    let isNew: Bool
    let original: CollectionSection
    let inventory: HomeSectionCatalogModel
    let visibility: HomeLibraryVisibilityModel
    let libraries: [AggregatedLibrary]
    let accounts: [ResolvedAccount]
    let spoilerSettings: SpoilerSettings
    @State private var draft: CollectionSection
    @State private var preview: LoadState<[MediaItem]> = .idle
    @State private var previewFailure: AppError?
    @State private var loadedRequest: PreviewRequest?
    @State private var retry = 0
    @State private var choosingSource = false
    @State private var saveFailed = false
    @State private var preferencesSaveFailed = false
    @FocusState private var isNameFocused: Bool
    @Environment(CardStyleSettingsModel.self) private var cards
    @Environment(\.plozzMetrics) private var metrics
    @Environment(\.homeContentSnapshot) private var homeSnapshot
    @SettingsPageDismiss private var dismiss

    init(
        section: CollectionSection, isNew: Bool = false,
        inventory: HomeSectionCatalogModel, visibility: HomeLibraryVisibilityModel,
        libraries: [AggregatedLibrary], accounts: [ResolvedAccount],
        spoilerSettings: SpoilerSettings = .default
    ) {
        _draft = State(initialValue: section)
        self.original = section
        self.isNew = isNew
        self.inventory = inventory
        self.visibility = visibility
        self.libraries = libraries
        self.accounts = accounts
        self.spoilerSettings = spoilerSettings
    }

    private struct PreviewRequest: Hashable {
        let sources: [HomeContentSource]
        let credentials: [String]
        let disabledLibraries: Set<String>
        let profile: ObjectIdentifier
        let retry: Int
    }

    private var request: PreviewRequest {
        PreviewRequest(
            sources: draft.sources,
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
            SettingsSectionGroup {
                Button { choosingSource = true } label: {
                    let choice = HomeRowChoice(collectionSection: draft)
                    HomeEditorRowLabel(
                        title: Text("Content"),
                        subtitle: draft.sources.isEmpty ? nil : choice.homeEditorSource(in: accounts),
                        subtitleProvider: choice.homeEditorProvider(in: accounts)
                    )
                }
                .buttonStyle(SettingsFormButtonStyle())
                .accessibilityIdentifier("collection-section-source")
                #if os(tvOS)
                if !isNew {
                    HomeEditorAutosavingNameInput(
                        "Name", name: draft.name, prompt: Text(verbatim: draft.contentTitle),
                        identifier: "collection-section-name", axis: .horizontal
                    ) { value in
                        guard var saved = visibility.visibility.collectionSections.first(where: { $0.id == draft.id })
                        else { throw AppError.notFound }
                        saved.name = value
                        guard canSaveSources(saved) else { throw AppError.notFound }
                        try visibility.saveCollectionSection(saved, catalog: currentCatalog)
                        draft.name = value
                    }
                } else {
                    nameInput
                }
                #else
                nameInput
                #endif
                SettingsMenuRow(title: "Layout", value: Text(draft.cardStyle.title), minimumContentHeight: 44) {
                    Picker("Layout", selection: $draft.cardStyle) {
                        ForEach(CollectionSection.CardStyle.allCases, id: \.self) { style in
                            Text(style.title).tag(style)
                        }
                    }
                }
                .accessibilityIdentifier("collection-section-card-style")
                if draft.cardStyle == .landscape {
                    SettingsMenuRow(title: "Logo", value: Text(draft.titleLogo.title), minimumContentHeight: 44) {
                        Picker("Logo", selection: $draft.titleLogo) {
                            ForEach(LandscapeTitleLogo.allCases, id: \.self) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                    }
                    .accessibilityIdentifier("collection-section-title-logo")
                }
            }
            if !draft.sources.isEmpty {
                VStack(alignment: .leading, spacing: 16) {
                    Text(verbatim: draft.title).font(.headline)
                    previewContent
                }
                .accessibilityIdentifier("collection-section-preview")
            }
            #if os(tvOS)
            if isNew { explicitSaveAction }
            #elseif !os(iOS)
            explicitSaveAction
            #endif
            if !isNew {
                HomeRowRemoveAction {
                    do {
                        try visibility.setHomeSectionVisible(false, id: draft.rowID, catalog: currentCatalog)
                        dismiss()
                    } catch {
                        saveFailed = true
                        PlozzLog.app.error("Could not remove collection section")
                    }
                }
            }
            if saveFailed || preferencesSaveFailed {
                InlineErrorMessage(Text("Couldn't update this row. Try again."))
            }
            #if os(tvOS)
            if !isNew && preferencesSaveFailed {
                Button("Retry", action: saveExistingPreferences)
                    .plozzActionButton(role: .secondary)
            }
            #endif
        }
        #if os(iOS)
        .modifier(HomeEditorSaveAction(
            title: isNew ? Text("Add to Home") : Text("Save changes"),
            isEnabled: canSave,
            identifier: "collection-section-save", action: save
        ))
        #elseif os(tvOS)
        .onChange(of: draft.cardStyle) { _, _ in saveExistingPreferences() }
        .onChange(of: draft.titleLogo) { _, _ in saveExistingPreferences() }
        .onChange(of: draft.sources) { _, _ in saveExistingPreferences() }
        #endif
        .settingsPageDestination(isPresented: $choosingSource) {
            HomeContentPickerView(
                selections: $draft.sources, inventory: inventory, visibility: visibility,
                libraries: libraries, accounts: accounts, allowsEmpty: isNew
            )
        }
        .task(id: request) { await loadPreview() }
        .environment(\.plozzCardCaptionView, .home)
        .environment(\.plozzCardCaptionSettings, cards.captions)
        .environment(\.plozzArtworkSettings, cards.artwork)
        .environment(\.plozzLandscapeTitleLogo, draft.titleLogo)
    }

    private var currentCatalog: HomeSectionCatalog {
        inventory.currentCatalog(libraries: libraries, accounts: accounts, visibility: visibility)
    }

    private var nameInput: some View {
        SettingsInputRow("Name", axis: .horizontal) {
            TextField("Name", text: $draft.name, prompt: Text(verbatim: draft.contentTitle))
                .focused($isNameFocused)
                .submitLabel(.done)
                .onSubmit { isNameFocused = false }
                .accessibilityIdentifier("collection-section-name")
        }
    }

    private var explicitSaveAction: some View {
        Button {
            do {
                try save()
                dismiss()
            } catch {
                saveFailed = true
                PlozzLog.app.error("Could not save collection section")
            }
        } label: {
            Group {
                if isNew { Text("Add to Home") }
                else { Text("Save changes") }
            }
            .plozzPageActionLabel()
        }
        .plozzPageActionButton()
        .disabled(!canSaveSources(draft))
        .accessibilityIdentifier("collection-section-save")
    }

    #if os(tvOS)
    private func saveExistingPreferences() {
        guard !isNew else { return }
        do {
            guard var saved = visibility.visibility.collectionSections.first(where: { $0.id == draft.id })
            else { throw AppError.notFound }
            saved.cardStyle = draft.cardStyle
            saved.titleLogo = draft.titleLogo
            saved.sources = draft.sources
            guard canSaveSources(saved) else { throw AppError.notFound }
            try visibility.saveCollectionSection(saved, catalog: currentCatalog)
            preferencesSaveFailed = false
        } catch {
            preferencesSaveFailed = true
            PlozzLog.app.error("Could not autosave collection preferences")
        }
    }
    #endif

    private var canSave: Bool {
        var normalizedDraft = draft
        normalizedDraft.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        var saved = visibility.visibility.collectionSections.first { $0.id == draft.id } ?? original
        saved.name = saved.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return canSaveSources(draft) && (isNew || normalizedDraft != saved)
    }

    private func save() throws {
        guard canSaveSources(draft) else { throw AppError.notFound }
        try visibility.saveCollectionSection(draft, catalog: currentCatalog)
        isNameFocused = false
    }

    private func canSaveSources(_ section: CollectionSection) -> Bool {
        !section.sources.isEmpty && section.sources.allSatisfy(\.isValid)
            && !section.availableSources(accounts: accounts, visibility: visibility.visibility).isEmpty
    }

    @ViewBuilder
    private var previewContent: some View {
        let current = draft.sources.isEmpty ? .empty : loadedRequest == request ? preview : .loading
        if let previewFailure, loadedRequest == request {
            InlineErrorMessage(Text(previewFailure.userMessage))
            Button("Retry") { retry += 1 }.plozzActionButton(role: .secondary)
        }
        switch current {
        case .idle, .loading:
            ProgressView("Loading…")
        case .empty:
            Text("No titles in this row.").plozzForeground(.secondary)
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
        previewFailure = nil
        guard !requested.sources.isEmpty else { preview = .empty; return }
        do {
            let accounts = accounts
            let settings = visibility.visibility
            let homeSnapshot = homeSnapshot
            let sources = requested.sources.filter { $0.isAvailable(accounts: accounts, visibility: settings) }
            guard !sources.isEmpty else { throw AppError.notFound }
            let session = HomeContentPageLoader.Session(
                accounts: accounts, visibility: settings,
                recommendationScope: homeSnapshot?.recommendationScope, refreshRecommendations: retry > 0, homeSnapshot: { kind in
                    guard let homeSnapshot else { throw AppError.notFound }
                    return try await homeSnapshot.contentSnapshot(for: kind, visibility: settings)
                }
            )
            let pager = HomeContentPager(sources: sources, serverInfo: accounts.sourceServerInfo()) { source, start, limit in
                let provider = accounts.first(where: source.matches)?.provider.kind
                let captured = await HTTPResponseDiagnostics.capture {
                    try await PerformanceDiagnostics.$provider.withValue(provider) {
                        try await HTTPResponseDiagnostics.$route.withValue(.homeContentPage) {
                            try await session.load(source, start: start, limit: limit)
                        }
                    }
                }
                if case let .failure(error) = captured.result, !captured.isCancelled {
                    LibraryDiagnosticJournal.shared.recordHomeContent(
                        source: source, provider: provider, start: start, limit: limit,
                        snapshotAvailable: homeSnapshot != nil,
                        failure: .init(
                            section: .browse, error: (error as? AppError) ?? .unknown(""),
                            responses: captured.responses, paging: captured.paging,
                            transport: captured.transport, http: captured.http
                        )
                    )
                }
                return try captured.result.get()
            }
            let page = try await pager.loadNext(limit: 20)
            try Task.checkCancellation()
            guard request == requested else { return }
            let items = page.items
            previewFailure = sources.compactMap { page.failures[$0.id] }.first
            if previewFailure != nil { PlozzLog.app.error("Some custom row preview sources could not be loaded") }
            if items.isEmpty, let failure = previewFailure {
                preview = .failed(failure)
                previewFailure = nil
            } else {
                preview = items.isEmpty ? .empty : .loaded(items)
            }
        } catch {
            guard !Task.isCancelled, !(error is CancellationError),
                  request == requested, (error as? AppError) != .cancelled else { return }
            preview = .failed((error as? AppError) ?? .invalidResponse)
            PlozzLog.app.error("Could not load collection section preview")
        }
    }
}
#endif
