import CoreModels

/// The same flat, profile-resolved list feeds every Home layout on every platform.
public struct HomePresentationRow: Identifiable, Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        case home(HomeRow)
        case library(HomeLibrarySectionGroup.Row)
        case liveTV([HomeLiveTVChannel])
    }

    public let choice: HomeRowChoice
    public let source: Source
    public var id: HomeRowID { choice.id }

    public init(choice: HomeRowChoice, source: Source) {
        self.choice = choice
        self.source = source
    }

    public var canBrowse: Bool {
        supportsBrowsing()
    }

    /// A loaded-count threshold changes the browse action, not the rail's items or paging.
    public func supportsBrowsing(loadedItemThreshold: Int? = nil) -> Bool {
        switch source {
        case let .home(row):
            return (loadedItemThreshold.map { row.items.count > $0 } ?? row.hasMore) && !row.items.isEmpty
                && row.loadingPlaceholderCount == 0 && row.failure == nil
        case let .library(row):
            return (loadedItemThreshold.map { row.section.items.count > $0 } ?? row.section.hasMore)
                && !row.section.items.isEmpty && !row.isLoading
                && row.failure == nil && row.issue == nil
        case .liveTV:
            return false
        }
    }

    public static func hasLiveTVRows(
        _ liveTV: HomeLiveTVSnapshot, visibility: HomeLibraryVisibility
    ) -> Bool {
        !resolve(rows: [], content: .init(), visibility: visibility, liveTV: liveTV).isEmpty
    }

    public static func displayState(
        _ state: LoadState<HomeViewModel.Content>,
        liveTV: HomeLiveTVSnapshot, visibility: HomeLibraryVisibility
    ) -> LoadState<HomeViewModel.Content> {
        if case .empty = state, hasLiveTVRows(liveTV, visibility: visibility) {
            return .loaded(.init())
        }
        return state
    }

    public static func resolve(
        rows: [HomeRow], content: HomeViewModel.Content, visibility: HomeLibraryVisibility,
        liveTV: HomeLiveTVSnapshot = .empty,
        presentation: LibraryPresentationSettings = .default,
        showsEmptySectionMessages: Bool = true,
        serverInfo: [String: SourceServerInfo] = [:],
        identitySources: (MediaItem) -> [MediaSourceRef] = { _ in [] }
    ) -> [Self] {
        let shared = HomeRowChoice.shared
        func entry(_ row: HomeRow) -> Self? {
            var row = row
            if row.kind == .recentlyAdded, row.loadingPlaceholderCount == 0 {
                let candidates = (content.recentlyAddedCandidates ?? row.items).filter {
                    $0.isVisibleOnHome(isLibraryVisible: visibility.isEnabled)
                        && (!visibility.hideWatchedRecentlyAdded || !HomeRecentlyAddedPolicy.isWatched($0))
                }
                let preview = HomeRowPreview(
                    candidates, limit: HomeRecentlyAddedPolicy.rowLimit
                )
                row.items = preview.items
                row.hasMore = preview.hasMore
                guard !row.isEmptyOnHome else { return nil }
            }
            let id: HomeRowID
            if row.kind == .libraries {
                id = .libraries
            } else if let kind = HomeGlobalRow(rawValue: row.kind.rawValue) {
                id = .global(kind)
            } else {
                return nil
            }
            guard let choice = shared.first(where: { $0.id == id }) else { return nil }
            return Self(choice: choice, source: .home(row))
        }
        var available = rows.filter { $0.kind != .libraries }.compactMap(entry)
        if !liveTV.channels.isEmpty, let choice = shared.first(where: { $0.id == .liveTV }) {
            available.append(Self(choice: choice, source: .liveTV(liveTV.channels)))
        }
        if visibility.usesIndividualHomeRows {
            for group in content.librarySections where visibility.isEnabled(group.library.key) {
                for var row in group.rows {
                    if row.id == LibraryHomeRowKind.recentlyAdded.rawValue {
                        var section = row.section
                        if visibility.hideWatchedRecentlyAdded {
                            section.hasMore = HomeRowPreview(
                                section.items.filter { !HomeRecentlyAddedPolicy.isWatched($0) },
                                limit: HomeRecentlyAddedPolicy.rowLimit
                            ).hasMore
                        }
                        section.items = HomeRecentlyAddedPolicy.items(
                            section.items, hideWatched: visibility.hideWatchedRecentlyAdded
                        )
                        row = .init(
                            section: section, isLoading: row.isLoading, failure: row.failure,
                            browseItem: row.browseItem, issue: row.issue, collectionCardStyle: row.collectionCardStyle
                        )
                    }
                    guard !row.section.items.isEmpty || row.isLoading || row.failure != nil else { continue }
                    if row.id == "pending-hubs" {
                        let known = (visibility.rowCustomization?.order ?? []).filter {
                            $0.libraryKey == group.library.key && $0.libraryKind == .hubs
                                && visibility.rowCustomization?.hidden.contains($0) != true
                        }
                        for id in known.isEmpty ? [.library(key: group.library.key, section: row.id)] : known {
                            available.append(Self(
                                choice: HomeRowChoice(
                                    id: id, title: row.section.title,
                                    localizedTitle: row.section.localizedTitle, library: group.library,
                                    isProviderDefault: true
                                ),
                                source: .library(row)
                            ))
                        }
                    } else {
                        available.append(Self(
                            choice: HomeRowChoice(section: row.section, library: group.library),
                            source: .library(row)
                        ))
                    }
                }
            }
            for var row in content.serverRows {
                if let libraryID = row.definition.section.libraryID,
                   !visibility.isEnabled("\(row.definition.accountID):\(libraryID)") { continue }
                if !row.definition.section.isAccountWideHistory {
                    row.items = row.items.filter { $0.isVisibleOnHome(isLibraryVisible: visibility.isEnabled) }
                }
                if row.definition.section.kind == .recentlyAdded {
                    if visibility.hideWatchedRecentlyAdded {
                        row.hasMore = HomeRowPreview(
                            row.items.filter { !HomeRecentlyAddedPolicy.isWatched($0) },
                            limit: HomeRecentlyAddedPolicy.rowLimit
                        ).hasMore
                    }
                    row.items = HomeRecentlyAddedPolicy.items(
                        row.items, hideWatched: visibility.hideWatchedRecentlyAdded
                    )
                }
                guard !row.items.isEmpty || row.isLoading || row.failure != nil else { continue }
                available.append(Self(
                    choice: HomeRowChoice(serverRow: row.definition), source: .library(row.row)
                ))
            }
        }
        for var row in content.collectionRows {
            guard let definition = visibility.collectionSections.first(where: {
                $0.id == row.definition.id && $0.sources == row.definition.sources && $0.query == row.definition.query
            }), definition.sources.contains(where: { $0.libraryKey.map(visibility.isEnabled) != false }) else { continue }
            row.definition = definition
            row = row.resolving(home: [
                .continueWatching: content.continueWatching,
                .watchlist: content.watchlist,
                .recentlyAdded: HomeRecentlyAddedPolicy.items(
                    content.recentlyAddedCandidates ?? content.latest,
                    hideWatched: visibility.hideWatchedRecentlyAdded, limit: .max
                )
            ], visibility: visibility, serverInfo: serverInfo, identitySources: identitySources)
            if !definition.sources.contains(where: \.isAccountWideHistory) {
                row.items = row.items.filter { $0.isVisibleOnHome(isLibraryVisible: visibility.isEnabled) }
            }
            available.append(Self(
                choice: HomeRowChoice(collectionSection: definition), source: .library(row.row)
            ))
        }
        available += rows.filter { $0.kind == .libraries }.compactMap(entry)
        for issue in content.sectionIssues where visibility.isHomeRowVisible(issue.choice) {
            if let key = issue.choice.id.libraryKey, !visibility.isEnabled(key) { continue }
            if let source = issue.choice.serverRow, let library = source.section.libraryID,
               !visibility.isEnabled("\(source.accountID):\(library)") { continue }
            if let section = issue.choice.collectionSection {
                guard visibility.collectionSections.contains(where: {
                    $0.id == section.id && $0.sources == section.sources
                }), section.sources.contains(where: { $0.libraryKey.map(visibility.isEnabled) != false }) else { continue }
            }
            // Keep usable cached/partial content visible; its diagnostic remains in the editor.
            var browseItem: MediaItem?
            var style: LibrarySection.Style = issue.choice.collectionSection?.cardStyle == .landscape
                || issue.choice.collectionSection?.cardStyle == .featured
                || issue.choice.serverRow?.section.kind == .nextUp
                || issue.choice.id.libraryKind == .nextUp ? .landscape : .poster
            var collectionCardStyle = issue.choice.collectionSection?.cardStyle
            if let existing = available.first(where: { $0.id == issue.id }) {
                switch existing.source {
                case let .home(row):
                    if !row.items.isEmpty || !row.libraries.isEmpty || row.loadingPlaceholderCount > 0 { continue }
                case let .library(row):
                    if !row.section.items.isEmpty || row.isLoading { continue }
                    browseItem = row.browseItem
                    style = row.section.style
                    collectionCardStyle = row.collectionCardStyle
                case .liveTV: continue
                }
            }
            available.removeAll { $0.id == issue.id }
            if issue.reason == .empty,
               !showsEmptySectionMessages || visibility.dismissedEmptyHomeRows.contains(issue.id) {
                continue
            }
            available.append(Self(choice: issue.choice, source: .library(.init(
                section: LibrarySection(
                    id: issue.id.presentationID, title: issue.choice.title,
                    localizedTitle: issue.choice.localizedTitle, style: style, items: []
                ),
                isLoading: false, failure: nil, browseItem: browseItem, issue: issue,
                collectionCardStyle: collectionCardStyle
            ))))
        }
        let byID = Dictionary(available.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let ordered = visibility.rowSections(choices: available.map(\.choice)).enabled
        return ordered.compactMap { byID[$0] }.map { entry in
            let name = visibility.homeRowName(for: entry.id)
            let choice = name.map { entry.choice.renamed(to: $0) } ?? entry.choice
            switch entry.source {
            case var .home(row):
                row.customTitle = name
                return Self(choice: choice, source: .home(row))
            case .liveTV:
                return Self(choice: choice, source: entry.source)
            case let .library(row):
                var section = row.section.resolvingCollectionCovers(presentation.collectionCoverLayout(
                    at: LibraryPresentationSettings.collectionCoverAddress(for: entry.id)
                ))
                if let name {
                    section = LibrarySection(
                        id: section.id, title: name, style: section.style, items: section.items,
                        isHomeDefault: section.isHomeDefault, isLegacyHomeDefault: section.isLegacyHomeDefault,
                        browseID: section.browseID, hasMore: section.hasMore
                    )
                }
                let issue = row.issue.map {
                    HomeSectionIssue(
                        choice: choice, reason: $0.reason, serverName: $0.serverName, providerKind: $0.providerKind
                    )
                }
                return Self(choice: choice, source: .library(.init(
                    section: section,
                    isLoading: row.isLoading, failure: row.failure, browseItem: row.browseItem,
                    issue: issue, collectionCardStyle: row.collectionCardStyle
                )))
            }
        }
    }
}
