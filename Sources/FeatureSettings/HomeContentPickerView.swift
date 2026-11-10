#if canImport(SwiftUI)
import CoreModels
import CoreUI
import SwiftUI

struct HomeContentPickerView: View {
    @Binding var selections: [HomeContentSource]
    let inventory: HomeSectionCatalogModel
    let visibility: HomeLibraryVisibilityModel
    let libraries: [AggregatedLibrary]
    let accounts: [ResolvedAccount]
    var allowsEmpty = true
    @State private var choosingCollections = false
    @State private var choosingPlaylists = false
    @State private var revision = 0

    var body: some View {
        let groupedFeeds = Dictionary(grouping: feedChoices, by: \.libraryKey)
        HomeEditorPage(title: Text("Content"), showsHeader: true) {
            if !selections.isEmpty {
                SettingsSectionGroup("Selected") {
                    ForEach(selections) { source in choice(source, selectedSummary: true) }
                }
            }
            SettingsSectionGroup {
                Button { choosingCollections = true } label: { HomeEditorRowLabel(title: Text("Collections")) }
                    .accessibilityIdentifier("home-content-collections")
                Button { choosingPlaylists = true } label: { HomeEditorRowLabel(title: Text("Playlists")) }
                    .accessibilityIdentifier("home-content-playlists")
            }
            .buttonStyle(SettingsFormButtonStyle())
            SettingsSectionGroup("Home") {
                ForEach(HomeGlobalRow.allCases, id: \.self) { kind in
                    choice(.init(home: kind))
                }
            }
            ForEach(availableLibraries) { library in
                SettingsSectionGroup(verbatim: library.library.title) {
                    if let account = accounts.first(where: { $0.account.id == library.accountID }) {
                        choice(.init(
                            feed: .library(library.library.kind), accountID: library.accountID,
                            serverUserID: account.plexHomeUserID ?? account.provider.session.userID,
                            libraryID: library.library.id, title: library.library.title
                        ))
                    }
                    ForEach(groupedFeeds[library.key] ?? []) { source in
                        choice(source)
                    }
                }
            }
            let serverFeeds = groupedFeeds[nil] ?? []
            if !serverFeeds.isEmpty {
                SettingsSectionGroup("Recommended") {
                    ForEach(serverFeeds) { source in choice(source) }
                }
            }
            if inventory.isLoading { ProgressView() }
            if !inventory.libraryFailures.isEmpty || !inventory.serverFailures.isEmpty {
                InlineErrorMessage(Text("Some sources couldn't be loaded."))
                Button("Retry") { revision += 1 }.plozzActionButton(role: .secondary)
            }
        }
        .settingsPageDestination(isPresented: $choosingCollections) {
            HeroCollectionPickerView(
                selections: containerSelections(playlists: false), libraries: availableLibraries, accounts: accounts
            )
        }
        .settingsPageDestination(isPresented: $choosingPlaylists) {
            HeroCollectionPickerView(
                selections: containerSelections(playlists: true), libraries: availableLibraries,
                accounts: accounts, playlists: true
            )
        }
        .task(id: HomeSectionCatalogModel.loadID(
            libraries: libraries, accounts: accounts, visibility: visibility, revision: revision
        )) {
            await inventory.load(libraries: libraries, accounts: accounts, visibility: visibility)
        }
    }

    private var availableLibraries: [AggregatedLibrary] {
        libraries.filter { library in
            visibility.isEnabled(library.key) && !library.library.isMusic && !library.isRetiredCollectionShortcut
                && accounts.contains { $0.account.id == library.accountID }
        }
    }

    private var feedChoices: [HomeContentSource] {
        inventory.currentCatalog(libraries: libraries, accounts: accounts, visibility: visibility).choices.compactMap { choice in
            let accountID = choice.serverRow?.accountID ?? choice.library?.accountID
            guard let account = accounts.first(where: { $0.account.id == accountID }) else { return nil }
            let feed: HomeContentSource.Feed
            if let server = choice.serverRow {
                guard ![.libraries, .liveTV].contains(server.section.kind) else { return nil }
                feed = .server(server.section)
            } else if let library = choice.library, case let .library(_, section) = choice.id {
                feed = .recommendation(sectionID: section, kind: library.library.kind)
            } else { return nil }
            return HomeContentSource(
                feed: feed, accountID: account.account.id,
                serverUserID: account.plexHomeUserID ?? account.provider.session.userID,
                libraryID: choice.serverRow?.section.libraryID ?? choice.library?.library.id,
                title: choice.localizedTitle.map { String(localized: $0) } ?? choice.title
            )
        }
    }

    private func choice(_ source: HomeContentSource, selectedSummary: Bool = false) -> some View {
        let selected = selections.contains { $0.id == source.id }
        let account = accounts.first(where: source.matches)
        let available = source.isAvailable(accounts: accounts, visibility: visibility.visibility)
        return SettingsCheckableRow(
            title: source.localizedTitle.map(Text.init) ?? Text(verbatim: source.title),
            subtitle: !available ? Text("Unavailable source") : source.home != nil ? nil
                : account.map { Text(verbatim: $0.account.server.name) },
            subtitleProvider: account?.provider.kind,
            titleLineLimit: nil, subtitleLineLimit: nil, isChecked: selected, flushLeading: false
        ) {
            if selected { selections.removeAll { $0.id == source.id } }
            else { selections.append(source) }
        }
        .disabled(!allowsEmpty && selected && selections.count == 1)
        .accessibilityIdentifier("home-content-\(selectedSummary ? "selected" : "choice")-\(source.home?.rawValue ?? "server")")
    }

    private func containerSelections(playlists: Bool) -> Binding<[HeroCollectionSelection]> {
        func matches(_ source: HomeContentSource) -> Bool {
            if playlists, case .playlist = source.feed { return true }
            if !playlists, case .collection = source.feed { return true }
            return false
        }
        return Binding(
            get: {
                selections.filter(matches).compactMap { source in
                    guard let accountID = source.accountID else { return nil }
                    let id: String
                    switch source.feed {
                    case let .collection(value), let .playlist(value): id = value
                    default: return nil
                    }
                    return HeroCollectionSelection(
                        accountID: accountID, libraryID: source.libraryID,
                        collectionID: id, title: source.title, serverUserID: source.serverUserID
                    )
                }
            },
            set: { values in
                let incoming = values.map {
                    HomeContentSource(
                        feed: playlists ? .playlist($0.collectionID) : .collection($0.collectionID),
                        accountID: $0.accountID, serverUserID: $0.serverUserID,
                        libraryID: $0.libraryID, title: $0.title
                    )
                }
                let ids = Set(incoming.map(\.id))
                var result = selections.filter { !matches($0) || ids.contains($0.id) }
                let existing = Set(result.map(\.id))
                result += incoming.filter { !existing.contains($0.id) }
                if allowsEmpty || !result.isEmpty { selections = result }
            }
        )
    }
}
#endif
