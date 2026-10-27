#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI

/// Home customization destinations share the active profile's existing settings.
public struct HomeRowsSettingsView: View {
    public let libraries: [AggregatedLibrary]
    public let accounts: [ResolvedAccount]
    public let visibility: HomeLibraryVisibilityModel
    public let spoilerSettings: SpoilerSettings
    @Environment(HeroSettingsModel.self) private var hero
    @Environment(HeroBackgroundSettingsModel.self) private var heroBackground
    @Environment(CardStyleSettingsModel.self) private var cards
    @State private var inventory: HomeSectionCatalogModel

    public init(
        libraries: [AggregatedLibrary], accounts: [ResolvedAccount],
        visibility: HomeLibraryVisibilityModel, spoilerSettings: SpoilerSettings = .default
    ) {
        self.init(
            libraries: libraries, accounts: accounts, visibility: visibility,
            inventory: HomeSectionCatalogModel(), spoilerSettings: spoilerSettings
        )
    }

    init(
        libraries: [AggregatedLibrary], accounts: [ResolvedAccount],
        visibility: HomeLibraryVisibilityModel, inventory: HomeSectionCatalogModel,
        spoilerSettings: SpoilerSettings = .default
    ) {
        self.libraries = libraries
        self.accounts = accounts
        self.visibility = visibility
        self.spoilerSettings = spoilerSettings
        _inventory = State(initialValue: inventory)
    }

    public var body: some View {
        HomeEditorPage(title: Text("Customize Home"), showsHeader: true) {
            HomeEditorLink {
                HomeHeroSettingsView(libraries: libraries, accounts: accounts, visibility: visibility)
                    .environment(hero)
                    .environment(heroBackground)
            } label: {
                HomeEditorRowLabel(title: heroTitle, value: heroSummary)
            }
            .accessibilityLabel(heroTitle)
            .accessibilityValue(heroSummary ?? Text(verbatim: ""))
            .accessibilityIdentifier("home-section-hero")
            HomeEditorLink {
                CardCaptionCustomizationView(cards: cards, scope: .home, visibility: visibility)
                    .environment(hero)
            } label: {
                HomeEditorRowLabel(title: Text("Card labels"))
            }
            .accessibilityIdentifier("home-customize-labels")
            HomeEditorLink {
                HomeSectionsSettingsView(
                    libraries: libraries, accounts: accounts, visibility: visibility,
                    inventory: inventory, spoilerSettings: spoilerSettings
                )
                .environment(hero)
                .environment(heroBackground)
                .environment(cards)
            } label: {
                HomeEditorRowLabel(title: Text("Rows"))
            }
            .accessibilityIdentifier("home-sections-settings")
        }
    }

    private var heroTitle: Text {
        #if os(tvOS)
        Text("Layout")
        #else
        Text("Hero")
        #endif
    }

    private var heroSummary: Text? {
        #if os(tvOS)
        if hero.settings.style == .followsFocus { return Text("Showcase") }
        return hero.settings.isEnabled ? Text("Hero") : Text("Off")
        #else
        return hero.settings.isEnabled ? nil : Text("Off")
        #endif
    }
}

struct HomeSectionsSettingsView: View {
    let libraries: [AggregatedLibrary]
    let accounts: [ResolvedAccount]
    let visibility: HomeLibraryVisibilityModel
    let spoilerSettings: SpoilerSettings
    @State private var inventory: HomeSectionCatalogModel
    @Environment(HeroSettingsModel.self) private var hero
    @Environment(HeroBackgroundSettingsModel.self) private var heroBackground
    @Environment(CardStyleSettingsModel.self) private var cards
    @State private var reorderSession: HomeSectionReorderSession?
    @State private var isLifting = false
    @State private var reloadRevision = 0
    @State private var editError: AppError?

    init(
        libraries: [AggregatedLibrary], accounts: [ResolvedAccount],
        visibility: HomeLibraryVisibilityModel, inventory: HomeSectionCatalogModel? = nil,
        spoilerSettings: SpoilerSettings = .default
    ) {
        self.libraries = libraries
        self.accounts = accounts
        self.visibility = visibility
        _inventory = State(initialValue: inventory ?? HomeSectionCatalogModel())
        self.spoilerSettings = spoilerSettings
    }

    private var requestID: HomeSectionCatalogModel.RequestID {
        HomeSectionCatalogModel.requestID(libraries: libraries, accounts: accounts, visibility: visibility)
    }

    private var isReordering: Bool { reorderSession != nil }
    private var sectionIssues: [HomeSectionIssue] {
        visibility.sectionDiagnostics.issues(accounts: accounts, visibility: visibility.visibility)
    }

    private var currentCatalog: HomeSectionCatalog {
        inventory.currentCatalog(libraries: libraries, accounts: accounts, visibility: visibility)
    }

    var body: some View {
        ScrollViewReader { scroll in
            editor
                #if os(iOS)
                .task(id: reorderSession?.initialElement) {
                    guard let target = reorderSession?.initialElement else { return }
                    await Task.yield()
                    guard !Task.isCancelled else { return }
                    scroll.scrollTo(target)
                }
                #endif
        }
    }

    private var editor: some View {
        HomeEditorPage(title: Text("Home rows"), showsHeader: true) {
            #if os(tvOS)
            reorderButton
            #endif
        } content: {
            SettingsSectionGroup {
                editorControls
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("home-section-controls")

            addSectionButton(identifier: "home-section-add")

            let catalog = reorderSession?.catalog ?? currentCatalog
            let arrangement = reorderSession?.visibility ?? visibility.visibility
            let sections = catalog.sections(in: arrangement)
            let choices = catalog.editableChoices(in: arrangement)
            if isReordering {
                let byID = Dictionary(choices.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                LiftableReorderList(
                    sections: .init(enabled: sections.enabled, disabled: []),
                    disabledSectionTitle: "Hidden", disabledPlaceholder: "No hidden rows",
                    isLifting: $isLifting, allowsHiding: false, removeTitle: "Remove from Home",
                    onRemove: { id in
                        do {
                            try reorderSession?.remove(id, savingTo: visibility)
                            editError = nil
                        } catch { editError = (error as? AppError) ?? .invalidResponse }
                    },
                    initialElement: reorderSession?.initialElement,
                    row: { id in
                        let choice = byID[id]
                        return .init(
                            title: choice?.homeEditorTitle ?? Text("Row"),
                            symbolName: "rectangle.grid.1x2",
                            providerKind: choice?.homeEditorProvider(in: accounts),
                            mediaShareTransport: choice?.library?.transportKind,
                            subtitle: choice?.homeEditorSource(in: accounts),
                            providerMarkInSubtitle: true
                        )
                    },
                    onChange: { order in
                        do {
                            try reorderSession?.move(order.enabled, savingTo: visibility)
                            editError = nil
                        } catch { editError = (error as? AppError) ?? .invalidResponse }
                    }
                )
                .accessibilityIdentifier("home-section-reorder-list")
            } else {
                ForEach(sections.enabled, id: \.self) { id in
                    if let choice = choices.first(where: { $0.id == id }) {
                        HomeEditorLink {
                            if let section = choice.collectionSection {
                                CollectionSectionSettingsView(
                                    section: section, inventory: inventory, visibility: visibility,
                                    libraries: libraries, accounts: accounts, spoilerSettings: spoilerSettings
                                )
                                .environment(cards)
                            } else {
                                HomeSectionSettingsView(
                                    choice: choice, inventory: inventory, visibility: visibility,
                                    libraries: libraries, accounts: accounts
                                )
                                .environment(cards)
                            }
                        } label: {
                            HomeSectionChoiceLabel(choice: choice, accounts: accounts)
                        }
                        .accessibilityIdentifier("home-section-\(id.presentationID)")
                        .contextMenu {
                            Button("Reorder", systemImage: "arrow.up.arrow.down") {
                                beginReordering(at: id)
                            }
                            .disabled(sections.enabled.count < 2)
                            Button("Remove from Home", systemImage: "minus.circle", role: .destructive) {
                                do {
                                    try visibility.setHomeSectionVisible(false, id: id, catalog: currentCatalog)
                                    editError = nil
                                } catch { editError = (error as? AppError) ?? .invalidResponse }
                            }
                        }
                        if let issue = sectionIssues.first(where: { $0.id == id }) {
                            sectionStatus(issue)
                        }
                    }
                }
                ForEach(sectionIssues.filter { !sections.enabled.contains($0.id) }) { issue in
                    sectionStatus(issue)
                }
            }
            if !sections.enabled.contains(.global(.continueWatching)),
               let watching = HomeRowChoice.shared.first(where: { $0.id == .global(.continueWatching) }) {
                HomeEditorLink {
                    HomeSectionSettingsView(
                        choice: watching,
                        inventory: inventory, visibility: visibility,
                        libraries: libraries, accounts: accounts, showsRemoveAction: false
                    )
                    .environment(cards)
                } label: {
                    HomeEditorRowLabel(
                        title: Text("Continue Watching settings")
                    )
                }
                .disabled(isReordering)
                .accessibilityIdentifier("home-hidden-continue-watching-settings")
            }
            #if os(tvOS)
            if hero.settings.style == .followsFocus {
                HomeEditorLink {
                    HomeHeroSettingsView(libraries: libraries, accounts: accounts, visibility: visibility)
                        .environment(hero)
                        .environment(heroBackground)
                } label: {
                    HomeEditorRowLabel(
                        title: Text("Discovery"),
                        subtitle: Text("Managed by Home layout.")
                    )
                }
                .disabled(isReordering)
                .accessibilityIdentifier("home-layout-discovery")
            }
            #endif
            if editError != nil {
                InlineErrorMessage(Text("Couldn't update this row. Try again."))
            }
            HomeCatalogStatus(inventory: inventory, accounts: accounts, libraries: libraries) {
                reloadRevision += 1
            }
            .disabled(isReordering)
        }
        #if os(iOS)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { reorderButton }
        }
        #endif
        .task(id: HomeSectionCatalogModel.loadID(
            libraries: libraries, accounts: accounts, visibility: visibility, revision: reloadRevision
        )) {
            await inventory.load(libraries: libraries, accounts: accounts, visibility: visibility)
        }
        .onChange(of: requestID) { _, _ in
            reorderSession = nil
            isLifting = false
            editError = nil
        }
    }

    private var editorControls: some View {
        HomeRowPresetPicker(visibility: visibility)
            .id(ObjectIdentifier(visibility))
            .disabled(isReordering)
            .frame(maxWidth: .infinity, alignment: .leading)
            #if os(tvOS)
            .focusSection()
            #endif
    }

    private var reorderButton: some View {
        Button {
            if isReordering {
                reorderSession = nil
                isLifting = false
            } else {
                beginReordering()
            }
        } label: {
            if isReordering { Text("Done").fixedSize(horizontal: false, vertical: true) }
            else { Text("Edit").fixedSize(horizontal: false, vertical: true) }
        }
        .disabled(isLifting || (!isReordering && currentCatalog.sections(in: visibility.visibility).enabled.isEmpty))
        .accessibilityIdentifier("home-section-reorder")
        #if os(tvOS)
        .plozzActionButton(role: .secondary)
        #endif
    }

    private func beginReordering(at element: HomeRowID? = nil) {
        let catalog = currentCatalog
        if let element, !catalog.sections(in: visibility.visibility).enabled.contains(element) {
            editError = .notFound
            return
        }
        reorderSession = HomeSectionReorderSession(
            catalog: catalog, visibility: visibility.visibility, initialElement: element
        )
        #if os(tvOS)
        isLifting = element != nil
        #else
        isLifting = false
        #endif
        editError = nil
    }

    private func sectionStatus(_ issue: HomeSectionIssue) -> some View {
        HomeSectionStatusView(issue: issue) {
            Task {
                await visibility.sectionDiagnostics.retry(accounts: accounts, visibility: visibility.visibility)
            }
        }
        .padding(.vertical, SettingsFormMetrics.navigationRowSpacing)
        .disabled(visibility.sectionDiagnostics.isLoading)
    }

    private func addSectionButton(identifier: String) -> some View {
        SettingsPageLink {
            addSectionDestination
        } label: {
            Label("Add row", systemImage: "plus")
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .plozzActionButton(role: .secondary)
        .buttonBorderShape(.capsule)
        .disabled(isReordering)
        .accessibilityIdentifier(identifier)
        .padding(.vertical, PlozzTheme.Spacing.medium)
    }

    private var addSectionDestination: some View {
        HomeAddSectionView(
            inventory: inventory, visibility: visibility, libraries: libraries, accounts: accounts,
            spoilerSettings: spoilerSettings
        )
        .environment(cards)
    }

}

/// Keep the rows under the user's hands stable while optional discovery finishes.
@MainActor
struct HomeSectionReorderSession {
    let catalog: HomeSectionCatalog
    let initialElement: HomeRowID?
    private(set) var visibility: HomeLibraryVisibility

    init(catalog: HomeSectionCatalog, visibility: HomeLibraryVisibility, initialElement: HomeRowID? = nil) {
        self.catalog = catalog
        self.visibility = visibility
        self.initialElement = initialElement
    }

    mutating func move(_ order: [HomeRowID], savingTo model: HomeLibraryVisibilityModel) throws {
        let updated = try catalog.reordering(order, in: visibility)
        save(updated, to: model)
    }

    mutating func remove(_ id: HomeRowID, savingTo model: HomeLibraryVisibilityModel) throws {
        let updated = try catalog.settingVisible(false, id: id, in: visibility)
        save(updated, to: model)
    }

    private mutating func save(_ updated: HomeLibraryVisibility, to model: HomeLibraryVisibilityModel) {
        guard updated != visibility else { return }
        model.applyRows(catalog.sections(in: updated), choices: catalog.availableChoices(in: updated))
        visibility = model.visibility
    }
}
#endif
