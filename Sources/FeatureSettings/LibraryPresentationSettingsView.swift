#if canImport(SwiftUI)
import CoreModels
import CoreUI
import SwiftUI

public struct LibraryPresentationSettingsView: View {
    @Bindable private var model: LibraryPresentationSettingsModel
    private let cards: CardStyleSettingsModel
    private let visibility: HomeLibraryVisibilityModel
    private let accounts: [ResolvedAccount]
    private let loader: any LibraryPresentationLoading
    @State private var discovery: LibraryPresentationDiscovery?
    @State private var discoveryScope: HomeSectionCatalogModel.RequestID?
    @State private var reloadRevision = 0

    private struct DiscoveryRequest: Equatable {
        let scope: HomeSectionCatalogModel.RequestID
        let revision: Int
    }

    public init(
        model: LibraryPresentationSettingsModel, cards: CardStyleSettingsModel, visibility: HomeLibraryVisibilityModel,
        accounts: [ResolvedAccount], loader: any LibraryPresentationLoading
    ) {
        self.model = model
        self.cards = cards
        self.visibility = visibility
        self.accounts = accounts
        self.loader = loader
    }

    private var requestID: HomeSectionCatalogModel.RequestID {
        HomeSectionCatalogModel.requestID(libraries: [], accounts: accounts, visibility: visibility)
    }

    public var body: some View {
        HomeEditorPage(title: Text("Customize Libraries"), showsHeader: true) {
            HomeEditorLink {
                LibraryNavigationSettingsView(model: model)
            } label: {
                HomeEditorRowLabel(
                    title: Text("Library Navigation"),
                    subtitle: Text("Tab order and visibility apply to all libraries."),
                    titleSymbol: "arrow.up.arrow.down"
                )
            }
            .accessibilityIdentifier("library-navigation-settings")
            #if os(tvOS)
            SettingsFormGroup(title: Text("Page appearance"), hasGroupedContent: true) {
                SettingsConnectedControlGroups {
                    VStack(alignment: .leading, spacing: SettingsFormMetrics.relatedControlSpacing) {
                        Text("Recommended Page").font(.headline)
                        HeroLogoSizeControl(
                            size: $model.settings.logoSize, textSize: $model.settings.textSize,
                            surface: .showcase, showsLibraryPreview: true
                        )
                    }
                    CardCaptionSettingsLink(cards: cards, scope: .libraries, visibility: visibility)
                }
            }
            #else
            SettingsSectionGroup("Page appearance") {
                CardCaptionSettingsLink(cards: cards, scope: .libraries, visibility: visibility)
            }
            #endif
            Text("Libraries")
                .font(.headline)
                .padding(.top)
                .accessibilityAddTraits(.isHeader)
            libraryChoices
        }
        .task(id: DiscoveryRequest(scope: requestID, revision: reloadRevision)) {
            await discoverLibraries()
        }
    }

    @ViewBuilder private var libraryChoices: some View {
        if discoveryScope == requestID, let discovery {
            let libraries = discovery.libraries.filter {
                visibility.isEnabled($0.key) && $0.providerKind != .mediaShare
                    && [.movie, .series, .video, .collection].contains($0.library.kind)
            }
            ForEach(libraries, id: \.key) { library in
                if let account = accounts.first(where: { $0.account.id == library.accountID }) {
                    HomeEditorLink {
                        LibraryDisplaySettingsView(
                            library: library, account: account, model: model, loader: loader
                        )
                        .id([
                            library.key, account.credentialRevision.rawValue.uuidString,
                            account.provider.session.userID, account.plexHomeUserID ?? ""
                        ])
                    } label: {
                        HomeEditorRowLabel(
                            title: library.library.displayName,
                            subtitle: Text(verbatim: library.serverName),
                            subtitleProvider: library.providerKind
                        )
                    }
                }
            }
            if libraries.isEmpty, discovery.failures.isEmpty {
                Text("No libraries available.")
                    .foregroundStyle(.secondary)
            }
            if !discovery.failures.isEmpty {
                InlineErrorMessage(Text("Some libraries couldn't be loaded."))
                Button("Try Again") { reloadRevision += 1 }
            }
        } else {
            ProgressView()
        }
    }

    private func discoverLibraries() async {
        let scope = requestID
        let result = await loader.libraries(accounts: accounts)
        guard !Task.isCancelled else { return }
        discovery = result
        discoveryScope = scope
    }
}

struct LibraryNavigationSettingsView: View {
    @Bindable var model: LibraryPresentationSettingsModel
    @State private var isLifting = false

    var body: some View {
        HomeEditorPage(title: Text("Library Navigation"), showsHeader: true) {
            let available = LibraryContentMode.allCases.map(\.rawValue)
            let sections = model.settings.navigation.sections(available: available)
            LiftableReorderList(
                sections: sections, disabledSectionTitle: "Hidden", disabledPlaceholder: "No hidden tabs",
                isLifting: $isLifting,
                requiredEnabled: sections.enabled.count == 1 ? Set(sections.enabled) : [],
                row: { id in
                    .init(
                        title: LibraryContentMode(rawValue: id).map { Text($0.displayName) } ?? Text(verbatim: id),
                        symbolName: "rectangle.on.rectangle"
                    )
                },
                onChange: { model.settings.navigation.apply($0, available: available) }
            )
            Text("Each library shows only the tabs it supports. Browse stays available if all its other tabs are hidden.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Reset Navigation") { model.settings.navigation = .init() }
                .disabled(isLifting)
        }
    }
}

struct LibraryDisplaySettingsView: View {
    let library: AggregatedLibrary
    let account: ResolvedAccount
    let model: LibraryPresentationSettingsModel
    let loader: any LibraryPresentationLoading
    @State private var state: LoadState<[LibrarySection]> = .idle
    @State private var diagnostic: LibraryLoadDiagnostic?
    @State private var reloadRevision = 0
    @State private var isLifting = false

    var showsRecommendedRows: Bool {
        [.movie, .series, .video].contains(library.library.kind)
    }

    var showsCollectionCovers: Bool {
        library.library.kind == .collection
            || ([.movie, .series].contains(library.library.kind)
                && (account.provider as? any CapabilityReporting)?.capabilities.contains(.libraryCollections) == true)
    }

    var collectionCoverSelection: Binding<CollectionCoverLayout> {
        let address = LibraryPresentationSettings.collectionCoverAddress(
            accountID: library.accountID, libraryID: library.library.id
        )
        return Binding(
            get: { model.settings.collectionCoverLayout(at: address) },
            set: { model.settings.collectionCoverLayouts[address] = $0 }
        )
    }

    private var choices: [LibrarySection] {
        var rows = state.value ?? []
        if !rows.contains(where: { $0.id == "continueWatching" }) {
            rows.insert(.init(
                id: "continueWatching", title: "Continue Watching", localizedTitle: "Continue Watching"
            ), at: 0)
        }
        if !rows.contains(where: { $0.id == "recentlyAdded" }) {
            rows.append(.init(id: "recentlyAdded", title: "Recently Added", localizedTitle: "Recently Added"))
        }
        return rows
    }

    var body: some View {
        HomeEditorPage(title: library.library.displayName, showsHeader: true) {
            if showsCollectionCovers {
                SettingsSectionGroup {
                    CollectionCoverLayoutPicker(selection: collectionCoverSelection, title: "Collection covers")
                }
                .accessibilityIdentifier("library-collection-covers")
            }
            if showsRecommendedRows {
                Text("Recommended Page Rows").font(.headline)
                switch state {
                case .idle, .loading:
                    ProgressView()
                case .loaded, .empty:
                    rowEditor
                case .failed(let error):
                    InlineErrorMessage(Text(error.userMessage))
                    retry
                }
                if let error = diagnostic?.failures.first?.error, state.value != nil {
                    InlineErrorMessage(Text(error.userMessage))
                    retry
                }
            }
        }
        .task(id: reloadRevision) {
            guard showsRecommendedRows else { return }
            if state.value == nil { state = .loading }
            let result = await loader.recommendations(library: library, account: account)
            guard !Task.isCancelled else { return }
            state = result.state
            diagnostic = result.diagnostic
        }
    }

    private var retry: some View {
        ContentFailureActions(report: diagnostic.map(PlaybackDiagnosticReport.library)) {
            reloadRevision += 1
        }
        .disabled(isLifting)
    }

    private var rowEditor: some View {
        let available = choices.map(\.id)
        let address = LibraryPresentationSettings.rowAddress(accountID: library.accountID, libraryID: library.library.id)
        let layout = model.settings.recommendedRows[address] ?? .init()
        return VStack(alignment: .leading, spacing: 20) {
            LiftableReorderList(
                sections: layout.sections(available: available),
                disabledSectionTitle: "Hidden", disabledPlaceholder: "No hidden rows",
                isLifting: $isLifting,
                row: { id in
                    .init(
                        title: choices.first(where: { $0.id == id })?.displayName ?? Text(verbatim: id),
                        symbolName: "rectangle.grid.1x2"
                    )
                },
                onChange: { sections in
                    var updated = model.settings.recommendedRows[address] ?? .init()
                    updated.apply(sections, available: available)
                    model.settings.recommendedRows[address] = updated
                }
            )
            ForEach(choices.filter { CollectionCoverLayout.isCollectionGroup($0.items) }) { row in
                let coverAddress = LibraryPresentationSettings.collectionCoverAddress(
                    accountID: library.accountID, libraryID: library.library.id, rowID: row.id
                )
                SettingsSectionGroup {
                    row.displayName.font(.headline)
                    CollectionCoverLayoutPicker(selection: Binding(
                        get: { model.settings.collectionCoverLayout(at: coverAddress) },
                        set: { model.settings.collectionCoverLayouts[coverAddress] = $0 }
                    ))
                }
                .disabled(isLifting)
            }
            Text("Changes apply only to this library's Recommended page, not Home.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Reset Rows") { model.settings.recommendedRows.removeValue(forKey: address) }
                .disabled(isLifting)
        }
    }
}
#endif
