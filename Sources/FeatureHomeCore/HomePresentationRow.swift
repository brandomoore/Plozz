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

    public var canBrowse: Bool {
        switch source {
        case let .home(row):
            return row.hasMore && !row.items.isEmpty && row.loadingPlaceholderCount == 0 && row.failure == nil
        case let .library(row):
            return row.section.hasMore && !row.section.items.isEmpty && !row.isLoading
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
        presentation: LibraryPresentationSettings = .default
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
        if !liveTV.recentChannels.isEmpty, !rows.contains(where: { $0.kind == .continueWatching }),
           let recent = entry(HomeRow(kind: .continueWatching)) {
            available.insert(recent, at: 0)
        }
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
                $0.id == row.definition.id && $0.source == row.definition.source
            }), definition.source.libraryKey.map(visibility.isEnabled) != false else { continue }
            row.definition = definition
            row.items = row.items.filter { $0.isVisibleOnHome(isLibraryVisible: visibility.isEnabled) }
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
                    $0.id == section.id && $0.source == section.source
                }), section.source.libraryKey.map(visibility.isEnabled) != false else { continue }
            }
            // Keep usable cached/partial content visible; its diagnostic remains in the editor.
            var browseItem: MediaItem?
            if let existing = available.first(where: { $0.id == issue.id }) {
                switch existing.source {
                case let .home(row):
                    if !row.items.isEmpty || !row.libraries.isEmpty { continue }
                    if row.kind == .continueWatching, !liveTV.recentChannels.isEmpty { continue }
                case let .library(row):
                    if !row.section.items.isEmpty || row.isLoading { continue }
                    browseItem = row.browseItem
                case .liveTV: continue
                }
            }
            available.removeAll { $0.id == issue.id }
            available.append(Self(choice: issue.choice, source: .library(.init(
                section: LibrarySection(
                    id: issue.id.presentationID, title: issue.choice.title,
                    localizedTitle: issue.choice.localizedTitle, items: []
                ),
                isLoading: false, failure: nil, browseItem: browseItem, issue: issue
            ))))
        }
        let byID = Dictionary(available.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let ordered = visibility.rowSections(choices: available.map(\.choice)).enabled
        return ordered.compactMap { byID[$0] }.map { entry in
            guard case let .library(row) = entry.source else { return entry }
            return Self(choice: entry.choice, source: .library(.init(
                section: row.section.resolvingCollectionCovers(presentation.collectionCoverLayout(
                    at: LibraryPresentationSettings.collectionCoverAddress(for: entry.id)
                )),
                isLoading: row.isLoading, failure: row.failure, browseItem: row.browseItem,
                issue: row.issue, collectionCardStyle: row.collectionCardStyle
            )))
        }
    }
}
