#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI

struct HomeEditorPage<HeaderActions: View, Content: View>: View {
    let title: Text
    var showsHeader = false
    @ViewBuilder var headerActions: () -> HeaderActions
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: pageSpacing) {
                #if os(tvOS)
                if showsHeader { SettingsPageHeader(title, trailing: headerActions) }
                #endif
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            #if os(tvOS)
            .padding(.horizontal, SettingsFormMetrics.pageInset)
            .padding(.top, SettingsFormMetrics.pageTopInset)
            .padding(.bottom, SettingsFormMetrics.pageBottomInset)
            #endif
        }
        .navigationTitle(title)
        #if os(iOS)
        .settingsPageSurface()
        #endif
        #if os(tvOS)
        .scrollClipDisabled()
        .toggleStyle(SettingsSwitchToggleStyle())
        .toolbar(.hidden, for: .tabBar)
        #endif
    }

    private var pageSpacing: CGFloat {
        #if os(tvOS)
        SettingsFormMetrics.navigationRowSpacing
        #else
        12
        #endif
    }
}

extension HomeEditorPage where HeaderActions == EmptyView {
    init(title: Text, showsHeader: Bool = false, @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title, showsHeader: showsHeader, headerActions: { EmptyView() }, content: content)
    }
}

struct HomeEditorLink<Destination: View, Label: View>: View {
    @ViewBuilder let destination: () -> Destination
    @ViewBuilder let label: () -> Label
    #if !os(tvOS)
    @State private var isPresented = false
    #endif

    var body: some View {
        #if os(tvOS)
        SettingsPageLink(destination: destination) {
            label().padding(16).settingsGroupSurface(cornerRadius: SettingsRowMetrics.navigationCornerRadius)
        }
            .buttonStyle(SettingsFocusButtonStyle(size: .navigation))
        #else
        Button { isPresented = true } label: {
            label().padding(14)
                .settingsGroupSurface(cornerRadius: 12)
                .contentShape(Rectangle())
        }
            .buttonStyle(.plain)
            .navigationDestination(isPresented: $isPresented, destination: destination)
        #endif
    }
}

struct HomeEditorRowLabel: View {
    let title: Text
    var subtitle: Text? = nil
    var value: Text? = nil
    var accessory = "chevron.forward"
    var titleSymbol: String? = nil
    var subtitleProvider: ProviderKind? = nil
    var mediaShareTransport: MediaShareTransportKind? = nil
    @ScaledMetric(relativeTo: .footnote) private var sourceMarkSize: CGFloat = 20

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    title.font(.body.weight(.medium))
                    if let titleSymbol {
                        Image(systemName: titleSymbol)
                            .font(.footnote)
                            .settingsRowSecondary()
                            .accessibilityHidden(true)
                    }
                }
                if let subtitle {
                    HStack(spacing: 6) {
                        if let subtitleProvider {
                            ProviderBrandMark(
                                provider: subtitleProvider, size: sourceMarkSize, showsBackground: false,
                                mediaShareTransport: mediaShareTransport
                            )
                            .accessibilityHidden(true)
                        }
                        subtitle.font(.footnote).settingsRowSecondary()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let value {
                value.settingsRowSecondary()
            }
            Image(systemName: accessory).font(.footnote).settingsRowSecondary().accessibilityHidden(true)
        }
        .multilineTextAlignment(.leading)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }
}

extension HomeRowChoice {
    var homeEditorTitle: Text { localizedTitle.map(Text.init) ?? Text(verbatim: title) }
    func homeEditorProvider(in accounts: [ResolvedAccount]) -> ProviderKind? {
        library?.providerKind ?? serverRow?.providerKind
            ?? collectionSection.flatMap { section in
                accounts.first(where: section.source.matches)?.account.server.provider
            }
    }

    func homeEditorSource(in accounts: [ResolvedAccount]) -> Text {
        if library == nil, let collectionSection,
           let account = accounts.first(where: collectionSection.source.matches) {
            return Text(verbatim: "\(collectionSection.source.title) · \(account.account.server.name)")
        }
        return homeEditorSource
    }

    @ViewBuilder var homeEditorProviderMark: some View {
        if let provider = library?.providerKind ?? serverRow?.providerKind {
            ProviderBrandMark(
                provider: provider, size: 32, showsBackground: false,
                mediaShareTransport: library?.transportKind
            )
            .frame(width: 36)
            .accessibilityHidden(true)
        }
    }

    var homeEditorSource: Text {
        if let library {
            return library.library.displayName + Text(verbatim: " · \(library.serverName)")
        }
        if let serverRow { return Text(verbatim: serverRow.serverName) }
        if let collectionSection { return Text(verbatim: collectionSection.source.title) }
        return id == .liveTV ? Text("All live sources") : Text("All libraries")
    }
}

struct HomeSectionChoiceLabel: View {
    let choice: HomeRowChoice
    var accessory = "chevron.forward"
    var accounts: [ResolvedAccount] = []

    var body: some View {
        HomeEditorRowLabel(
            title: choice.homeEditorTitle, subtitle: choice.homeEditorSource(in: accounts),
            accessory: accessory,
            subtitleProvider: choice.homeEditorProvider(in: accounts),
            mediaShareTransport: choice.library?.transportKind
        )
    }
}

struct HomeSectionSettingsView: View {
    let choice: HomeRowChoice
    let inventory: HomeSectionCatalogModel
    let visibility: HomeLibraryVisibilityModel
    let libraries: [AggregatedLibrary]
    let accounts: [ResolvedAccount]
    var showsRemoveAction = true
    @Environment(CardStyleSettingsModel.self) private var cards
    @Environment(LibraryPresentationSettingsModel.self) private var libraryPresentation: LibraryPresentationSettingsModel?
    #if os(tvOS)
    @Environment(HeroSettingsModel.self) private var hero
    #endif
    @SettingsPageDismiss private var dismiss
    @State private var failed = false

    var body: some View {
        HomeEditorPage(title: choice.homeEditorTitle, showsHeader: true) {
            HStack(spacing: 12) {
                choice.homeEditorProviderMark
                choice.homeEditorSource.font(.subheadline).plozzForeground(.secondary)
            }
            if hasCollectionCovers, let libraryPresentation {
                SettingsSectionGroup {
                    CollectionCoverLayoutPicker(selection: Binding(
                        get: { libraryPresentation.settings.collectionCoverLayout(at: coverAddress) },
                        set: { libraryPresentation.settings.collectionCoverLayouts[coverAddress] = $0 }
                    ))
                }
            }
            if choice.id == .global(.continueWatching) {
                ContinueWatchingArtworkPicker(style: Binding(
                    get: {
                        if visibility.continueWatchingLayout == .portrait { return .portraitPosters }
                        return visibility.continueWatchingShowsSeriesArtwork ? .logoAndArtwork : .thumbnail
                    },
                    set: { option in
                        if option.layout == .landscape {
                            visibility.setContinueWatchingShowsSeriesArtwork(option.showsSeriesArtwork)
                        }
                        visibility.setContinueWatchingLayout(option.layout)
                    }
                ), playbackDetails: visibility.continueWatchingPlaybackDetails,
                   captions: cards.captions, isShowcase: previewsShowcase)
                #if os(tvOS)
                SettingsControlGroup { presentationControls }
                #else
                SettingsSectionGroup { presentationControls }
                #endif
                Text("Appearance also applies on Recommended.")
                    .settingsHelperText()
                #if os(tvOS)
                SettingsControlGroup { behaviorControls }
                #else
                SettingsSectionGroup { behaviorControls }
                #endif
            }
            if showsRemoveAction {
                Button("Remove from Home", role: .destructive) {
                    do {
                        try visibility.setHomeSectionVisible(false, id: choice.id, catalog: inventory.currentCatalog(
                            libraries: libraries, accounts: accounts, visibility: visibility
                        ))
                        dismiss()
                    } catch { failed = true }
                }
                .plozzActionButton(role: .secondary)
                .accessibilityIdentifier("home-section-remove")
            }
            if failed { InlineErrorMessage(Text("Couldn't update this row. Try again.")) }
            if inventory.isLoading { ProgressView("Loading available rows…") }
        }
        .task(id: HomeSectionCatalogModel.loadID(
            libraries: libraries, accounts: accounts, visibility: visibility
        )) {
            await inventory.load(libraries: libraries, accounts: accounts, visibility: visibility)
        }
    }

    @ViewBuilder
    private var presentationControls: some View {
        ContinueWatchingPlaybackDetailsControl(visibility: visibility)
        CardCaptionViewChoices(
            view: .continueWatching,
            settings: Binding(get: { cards.captions }, set: { cards.captions = $0 }),
            title: "Labels"
        )
    }

    private var coverAddress: String {
        LibraryPresentationSettings.collectionCoverAddress(for: choice.id)
    }

    private var hasCollectionCovers: Bool {
        if choice.hasCollectionCovers { return true }
        guard let row = choice.serverRow, let libraryID = row.section.libraryID else { return false }
        return libraries.contains {
            $0.accountID == row.accountID && $0.library.id == libraryID && $0.library.kind == .collection
        }
    }

    @ViewBuilder
    private var behaviorControls: some View {
        ContinueWatchingNextUpControl(visibility: visibility)
        ContinueWatchingActionControl(visibility: visibility)
    }

    private var previewsShowcase: Bool {
        #if os(tvOS)
        hero.settings.style == .followsFocus
        #else
        false
        #endif
    }
}

struct ContinueWatchingActionControl: View {
    let visibility: HomeLibraryVisibilityModel

    var body: some View {
        let selection = visibility.continueWatchingAction
        Group {
            #if os(iOS)
            ViewCustomizationMenu(
                id: "continue-watching-action", title: "When tapping an item",
                value: selection.displayName, detail: selection.detail,
                selection: Binding(
                    get: { visibility.continueWatchingAction },
                    set: { visibility.setContinueWatchingAction($0) }
                )
            ) {
                ForEach(ContinueWatchingAction.allCases, id: \.self) { action in
                    Text(action.displayName).tag(action)
                }
            }
            #else
            VStack(alignment: .leading, spacing: 12) {
                ViewCustomizationRow(
                    id: "continue-watching-action", title: "Center button action",
                    value: selection.displayName, detail: selection.detail
                ) {
                    visibility.setContinueWatchingAction(selection == .play ? .openDetails : .play)
                }
                #if os(tvOS)
                Text("Play/Pause always starts playback.")
                    .settingsHelperText()
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("continue-watching-remote-help")
                #endif
            }
            #endif
        }
    }
}

private struct ContinueWatchingPlaybackDetailsControl: View {
    let visibility: HomeLibraryVisibilityModel

    var body: some View {
        let selection = visibility.continueWatchingPlaybackDetails
        Group {
            #if os(iOS)
            ViewCustomizationMenu(
                id: "continue-watching-playback-details", title: "Playback details",
                value: selection.displayName, detail: selection.detail,
                selection: Binding(
                    get: { visibility.continueWatchingPlaybackDetails },
                    set: { visibility.setContinueWatchingPlaybackDetails($0) }
                )
            ) {
                ForEach(ContinueWatchingPlaybackDetails.allCases, id: \.self) { details in
                    Text(details.displayName).tag(details)
                }
            }
            #else
            ViewCustomizationRow(
                id: "continue-watching-playback-details", title: "Playback details",
                value: selection.displayName, detail: selection.detail
            ) {
                visibility.setContinueWatchingPlaybackDetails(selection == .detailed ? .progressOnly : .detailed)
            }
            #endif
        }
    }
}

struct HomeAddSectionView: View {
    let inventory: HomeSectionCatalogModel
    let visibility: HomeLibraryVisibilityModel
    let libraries: [AggregatedLibrary]
    let accounts: [ResolvedAccount]
    var spoilerSettings: SpoilerSettings = .default
    @Environment(CardStyleSettingsModel.self) private var cards
    @SettingsPageDismiss private var dismiss
    @State private var failed = false
    @State private var reloadRevision = 0

    var body: some View {
        HomeEditorPage(title: Text("Add row"), showsHeader: true) {
            HomeEditorLink {
                CollectionSectionCreationView(
                    inventory: inventory, visibility: visibility, libraries: libraries, accounts: accounts,
                    spoilerSettings: spoilerSettings
                )
                .environment(cards)
            } label: {
                HomeEditorRowLabel(title: Text("From a collection"))
            }
            .accessibilityIdentifier("home-add-collection")
            let catalog = inventory.currentCatalog(libraries: libraries, accounts: accounts, visibility: visibility)
            let disabled = Set(catalog.sections(in: visibility.visibility).disabled)
            let choices = catalog.editableChoices(in: visibility.visibility).filter { disabled.contains($0.id) }
            if !choices.isEmpty {
                Text("Available rows")
                    .font(.headline)
                    .padding(.top, 12)
                    .accessibilityAddTraits(.isHeader)
            } else if !inventory.isLoading && inventory.serverFailures.isEmpty && inventory.libraryFailures.isEmpty {
                Text("No additional rows available.")
                    .plozzForeground(.secondary)
                    .accessibilityIdentifier("home-add-empty")
            }
            ForEach(choices) { choice in
                Button {
                    do {
                        try visibility.setHomeSectionVisible(true, id: choice.id, catalog: catalog)
                        dismiss()
                    } catch { failed = true }
                } label: {
                    HomeSectionChoiceLabel(choice: choice, accessory: "plus", accounts: accounts)
                }
                .buttonStyle(SettingsFormButtonStyle())
                .accessibilityIdentifier("home-add-\(choice.id.presentationID)")
            }
            HomeCatalogStatus(inventory: inventory, accounts: accounts, libraries: libraries) {
                reloadRevision += 1
            }
            if visibility.visibility.mergesNextUpRows {
                Text("Next Up is included in Continue Watching.").font(.footnote).plozzForeground(.secondary)
            }
            if failed { InlineErrorMessage(Text("Couldn't update this row. Try again.")) }
        }
        .task(id: HomeSectionCatalogModel.loadID(
            libraries: libraries, accounts: accounts, visibility: visibility, revision: reloadRevision
        )) {
            await inventory.load(libraries: libraries, accounts: accounts, visibility: visibility)
        }
    }
}

struct HomeHeroSettingsView: View {
    let libraries: [AggregatedLibrary]
    let accounts: [ResolvedAccount]
    let visibility: HomeLibraryVisibilityModel
    @Environment(HeroSettingsModel.self) private var hero
    #if os(tvOS)
    @State private var navigation = SettingsDetailNavigation()
    #endif

    private var availableLibraries: [AggregatedLibrary] {
        let accountIDs = Set(accounts.map(\.account.id))
        return libraries.filter {
            accountIDs.contains($0.accountID) && !$0.library.isMusic && visibility.isEnabled($0.key)
        }
    }

    var body: some View {
        #if os(tvOS)
        SettingsDetailPages(navigation: navigation) {
            page
        } detail: {
            HeroSettingsDestination(libraries: availableLibraries, accounts: accounts)
        }
        #else
        page
        #endif
    }

    @ViewBuilder private var page: some View {
        @Bindable var hero = hero
        HomeEditorPage(title: pageTitle, showsHeader: true) {
            #if os(tvOS)
            HomeLayoutPicker(
                layout: $hero.settings.style,
                homeLogoSize: hero.settings.logoSize, showcaseLogoSize: hero.settings.showcaseLogoSize,
                homeTextSize: hero.settings.textSize, showcaseTextSize: hero.settings.showcaseTextSize
            )
            if hero.settings.style == .followsFocus {
                SettingsControlGroup {
                    HeroLogoSizeControl(
                        size: $hero.settings.showcaseLogoSize, textSize: $hero.settings.showcaseTextSize, surface: .showcase
                    )
                }
                SettingsControlGroup {
                    Toggle("Ratings", isOn: $hero.settings.showsRatings)
                    if hero.settings.showsRatings {
                        Toggle("Show Common Sense age", isOn: $hero.settings.ratingPreferences.showsHeaderFamilyGuidance)
                        HeaderReviewScoreCountPicker(settings: $hero.settings.ratingPreferences)
                    }
                }
                if hero.allowsDiscovery {
                    SettingsControlGroup {
                        Toggle("Discovery row", isOn: $hero.settings.showsDiscoverRow)
                        if hero.settings.showsDiscoverRow {
                            HeroSettingsLink(page: .discovery, libraries: availableLibraries, accounts: accounts)
                        }
                    }
                } else {
                    Text("Discovery is unavailable in Kids profiles.")
                        .settingsHelperText()
                }
            } else {
                HeroSettingsControls(libraries: availableLibraries, accounts: accounts)
            }
            #else
            HeroSettingsControls(libraries: availableLibraries, accounts: accounts)
            #endif
        }
    }

    private var pageTitle: Text {
        #if os(tvOS)
        Text("Home layout")
        #else
        Text("Hero")
        #endif
    }
}

struct HomeCatalogStatus: View {
    let inventory: HomeSectionCatalogModel
    let accounts: [ResolvedAccount]
    let libraries: [AggregatedLibrary]
    let retry: () -> Void

    var body: some View {
        if inventory.isLoading { ProgressView("Loading available rows…") }
        if !inventory.serverFailures.isEmpty || !inventory.libraryFailures.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(accounts.filter { inventory.serverFailures[$0.account.id] != nil }, id: \.account.id) { source in
                    if let error = inventory.serverFailures[source.account.id], error != .cancelled {
                        InlineErrorMessage(message(server: source.account.server.name, error: error))
                            .accessibilityIdentifier("home-server-failure-\(source.account.id)")
                    }
                }
                ForEach(libraries.filter { inventory.libraryFailures[$0.key] != nil }) { library in
                    InlineErrorMessage(Text("Couldn't load rows from \(library.library.title)."))
                }
                Button("Retry", action: retry)
                    .plozzActionButton(role: .secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .settingsGroupSurface(cornerRadius: 12)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("home-section-discovery-issues")
        }
    }

    private func message(server: String, error: AppError) -> Text {
        if error == .serverUnreachable { return Text("\(server) is offline.") }
        if error.requiresSignIn { return Text("Sign in to \(server) again.") }
        return Text("Couldn't load rows from \(server).")
    }
}

struct HomeRowPresetPicker: View {
    let visibility: HomeLibraryVisibilityModel
    @State private var resetDefaults: HomeRowCustomization.Defaults?

    private var current: HomeRowCustomization.Defaults {
        switch visibility.visibility.rowCustomization?.defaults {
        case .matchServer: .matchServer
        case .combined: .combined
        default: .custom
        }
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                presetLabel
                #if os(iOS)
                Spacer(minLength: 12)
                #endif
                picker
                    #if os(iOS)
                    .fixedSize()
                    #endif
            }
                #if !os(iOS)
                .fixedSize(horizontal: true, vertical: false)
                #endif
            VStack(alignment: .leading, spacing: 4) {
                presetLabel
                picker.fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(minHeight: 44)
        .confirmationDialog(
            "Replace your row arrangement?",
            isPresented: Binding(
                get: { resetDefaults != nil },
                set: { if !$0 { resetDefaults = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let preset = resetDefaults {
                Button {
                    visibility.useRowDefaults(preset)
                    resetDefaults = nil
                } label: {
                    if preset == .matchServer { Text("Match server") }
                    else { Text("Combined rows") }
                }
            }
            Button("Cancel", role: .cancel) { resetDefaults = nil }
        } message: {
            if resetDefaults == .matchServer { Text("Follow your servers' Home rows.") }
            else { Text("Start with rows across all libraries.") }
        }
    }

    private var presetLabel: some View {
        Text("Preset")
            #if os(iOS)
            .font(.subheadline.weight(.semibold))
            .settingsRowSecondary()
            .fixedSize()
            #endif
    }

    @ViewBuilder private var picker: some View {
        Menu {
            selectionPicker.pickerStyle(.inline).labelsHidden()
        } label: {
            HStack(spacing: 8) {
                currentTitle.fixedSize(horizontal: false, vertical: true)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.semibold))
                    .accessibilityHidden(true)
            }
            #if os(iOS)
                .font(.subheadline.weight(.semibold))
                .padding(.vertical, 6)
            #endif
        }
        #if os(tvOS)
        .menuStyle(.button)
        .plozzActionButton(role: .secondary)
        #else
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .frame(minHeight: 44)
        #endif
        .accessibilityLabel(Text("Preset"))
        .accessibilityValue(currentTitle)
        .accessibilityIdentifier("home-row-preset")
    }

    private var currentTitle: Text {
        switch current {
        case .matchServer: Text("Match server")
        case .combined: Text("Combined rows")
        default: Text("Custom")
        }
    }

    private var selectionPicker: some View {
        Picker("Preset", selection: Binding(
            get: { current },
            set: { proposed in
                if proposed != current, proposed != .custom { resetDefaults = proposed }
            }
        )) {
            if current == .custom {
                Text("Custom").tag(HomeRowCustomization.Defaults.custom).disabled(true)
            }
            Text("Match server").tag(HomeRowCustomization.Defaults.matchServer)
            Text("Combined rows").tag(HomeRowCustomization.Defaults.combined)
        }
    }
}
#endif
