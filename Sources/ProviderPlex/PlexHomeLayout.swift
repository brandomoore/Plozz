import Foundation
import CoreModels
import CoreNetworking

extension PlexProvider {
    public func homeRowPage(_ feed: HomeRowFeed, startIndex: Int, limit: Int) async throws -> HomeRowPage {
        guard startIndex >= 0, limit > 0, limit <= PageRequest.defaultLimit,
              startIndex < Int.max - limit else { throw AppError.invalidResponse }
        let key: String?
        let libraryID: String?
        switch feed {
        case let .recommendation(library, _, browseID, _):
            libraryID = library
            if browseID.hasPrefix("hub:") {
                let rawID = String(browseID.dropFirst(4))
                let count = startIndex + limit + 1
                let promoted = try await client.promotedHubs(sectionID: library, count: count)
                let hubs: [PlexHub]
                if promoted.contains(where: { ($0.hubIdentifier ?? $0.context) == rawID }) {
                    hubs = promoted
                } else {
                    hubs = try await client.sectionHubs(sectionID: library, count: count)
                }
                guard let hub = hubs.first(where: { ($0.hubIdentifier ?? $0.context) == rawID }) else {
                    throw AppError.notFound
                }
                let items = mappedServerHomeItems(hub, libraryID: library, limit: count)
                guard items.count >= count || hub.more != true else { throw AppError.invalidResponse }
                return .prefix(items, startIndex: startIndex, limit: limit)
            }
            key = browseID
        case let .server(section, excluded, anchors):
            guard section.libraryID.map({ !excluded.contains($0) }) ?? true else {
                return .init(items: [], nextOffset: nil)
            }
            libraryID = section.libraryID
            guard let libraryID, section.id != "plex:continueWatching" else {
                return try await homeRowPrefixPage(feed, startIndex: startIndex, limit: limit)
            }
            let hubs = try await client.serverHomeHubs(sectionID: libraryID, count: 100)
            guard let hub = Self.serverHomeSections(hubs, libraryID: libraryID).first(where: {
                $0.0.id == section.id
                    && Set(anchors).isSubset(of: Set(($0.1.Metadata ?? []).compactMap(\.ratingKey)))
            })?.1 else { throw AppError.notFound }
            key = PlexClient.homeShelfKey(hub.key)
            if key == nil {
                guard hub.more != true else { throw AppError.invalidResponse }
                return .prefix(
                    mappedServerHomeItems(hub, libraryID: libraryID, limit: 100),
                    startIndex: startIndex, limit: limit
                )
            }
        default:
            return try await homeRowPrefixPage(feed, startIndex: startIndex, limit: limit)
        }
        guard let key else {
            return try await homeRowPrefixPage(feed, startIndex: startIndex, limit: limit)
        }
        let page = try await client.homeShelfPage(key: key, startIndex: startIndex, limit: limit)
        return HomeRowPage(
            items: page.items.filter {
                Self.isServerHomeVideo($0)
                    && (libraryID == nil || ($0.librarySectionID.map { String($0) == libraryID } ?? true))
            }.map { map(metadata: $0).taggingLibrary(libraryID) },
            nextOffset: page.nextOffset
        )
    }

    public func serverHomeLayout() async throws -> ServerHomeLayout? {
        let libraries = try await client.sections()
        var layout = ServerHomeLayout(
            sections: [], source: .promotedHubs,
            omitsMusic: libraries.contains { $0.type == "artist" }
        )
        var seen = Set<String>()
        // PMS exposes promotion order within a library, not another client's
        // sidebar pins. Keep the server's library order without fabricating pins.
        for library in libraries where ["movie", "show"].contains(library.type ?? "") {
            guard let libraryID = library.key else { continue }
            try Task.checkCancellation()
            let hubs = try await client.serverHomeHubs(sectionID: libraryID, count: 1)
            for (section, _) in Self.serverHomeSections(hubs, libraryID: libraryID) {
                guard seen.insert(section.id).inserted else { continue }
                layout.sections.append(section)
            }
        }
        return layout
    }

    public func serverHomeItems(
        section: ServerHomeSection, limit: Int, excludingLibraryIDs: Set<String>
    ) async throws -> [MediaItem] {
        guard limit > 0, section.kind != .libraries, section.kind != .liveTV,
              section.libraryID.map({ !excludingLibraryIDs.contains($0) }) ?? true else { return [] }
        let boundedLimit = min(limit, 100)
        if section.id == "plex:continueWatching" {
            let requestLimit = limit > 100 || !excludingLibraryIDs.isEmpty ? Int.max : limit
            let (metadata, _) = try await resumeFeed(limit: requestLimit)
            return Array(metadata.filter {
                guard Self.isServerHomeVideo($0) else { return false }
                return $0.librarySectionID.map { !excludingLibraryIDs.contains(String($0)) }
                    ?? excludingLibraryIDs.isEmpty
            }.prefix(limit)).map(map(metadata:))
        }
        guard let libraryID = section.libraryID else { throw AppError.invalidResponse }
        let hubs = try await client.serverHomeHubs(sectionID: libraryID, count: boundedLimit)
        let hub = Self.serverHomeSections(hubs, libraryID: libraryID)
            .first(where: { $0.0.id == section.id })?.1
        return mappedServerHomeItems(hub, libraryID: libraryID, limit: boundedLimit)
    }

    public func serverHomeItems(
        sections: [ServerHomeSection], limit: Int, excludingLibraryIDs: Set<String>
    ) async -> [String: Result<[MediaItem], AppError>] {
        var results: [String: Result<[MediaItem], AppError>] = [:]
        var libraryOrder: [String] = []
        var librarySections: [String: [ServerHomeSection]] = [:]
        var seen = Set<String>()
        for section in sections where seen.insert(section.id).inserted {
            if limit > 0, section.kind != .libraries, section.kind != .liveTV,
               section.id != "plex:continueWatching",
               let libraryID = section.libraryID, !excludingLibraryIDs.contains(libraryID) {
                if librarySections[libraryID] == nil { libraryOrder.append(libraryID) }
                librarySections[libraryID, default: []].append(section)
            } else {
                do {
                    try Task.checkCancellation()
                    results[section.id] = .success(try await serverHomeItems(
                        section: section, limit: limit, excludingLibraryIDs: excludingLibraryIDs
                    ))
                } catch {
                    results[section.id] = .failure(Self.homeRequestError(error))
                }
            }
        }
        let boundedLimit = min(limit, 100)
        // One payload at a time, shared only by rows in this batch. A later Home
        // load must observe watch mutations rather than a time-based item cache.
        for libraryID in libraryOrder {
            do {
                try Task.checkCancellation()
                let hubs = try await client.serverHomeHubs(sectionID: libraryID, count: boundedLimit)
                let indexed = Self.serverHomeSections(hubs, libraryID: libraryID)
                    .reduce(into: [String: PlexHub]()) { indexed, entry in
                        if indexed[entry.0.id] == nil { indexed[entry.0.id] = entry.1 }
                    }
                for section in librarySections[libraryID] ?? [] {
                    results[section.id] = .success(mappedServerHomeItems(
                        indexed[section.id], libraryID: libraryID, limit: boundedLimit
                    ))
                }
            } catch {
                let failure = Self.homeRequestError(error)
                for section in librarySections[libraryID] ?? [] {
                    results[section.id] = .failure(failure)
                }
            }
        }
        return results
    }

    private func mappedServerHomeItems(
        _ hub: PlexHub?, libraryID: String, limit: Int
    ) -> [MediaItem] {
        Array((hub?.Metadata ?? []).filter {
            Self.isServerHomeVideo($0)
                && ($0.librarySectionID.map { String($0) == libraryID } ?? true)
        }.prefix(limit)).map { map(metadata: $0).taggingLibrary(libraryID) }
    }

    private static func homeRequestError(_ error: Error) -> AppError {
        (error as? AppError) ?? (error is CancellationError ? .cancelled : .invalidResponse)
    }

    private static func serverHomeSections(
        _ hubs: [PlexHub], libraryID: String
    ) -> [(ServerHomeSection, PlexHub)] {
        var slots: [String: Int] = [:]
        var seen = Set<String>()
        return hubs.compactMap { hub in
            guard !["artist", "album", "track", "photo"].contains(hub.type ?? ""),
                  let rawID = [hub.hubIdentifier, hub.context].compactMap({ $0 })
                    .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
                  seen.insert(rawID).inserted else { return nil }
            let tokens = Set([rawID, hub.context ?? ""].joined(separator: ".")
                .lowercased().split(separator: ".").map(String.init))
            let kind: ServerHomeSection.Kind
            let identity: String
            if !tokens.isDisjoint(with: [
                "continuewatching", "continue", "ondeck", "inprogress", "resume", "keepwatching"
            ]) {
                kind = .continueWatching
                identity = "plex:continueWatching"
            } else {
                kind = tokens.contains("recentlyadded") ? .recentlyAdded : .recommendations
                let family = ["similar", "actor", "director", "writer", "producer", "cast", "crew"]
                    .first { tokens.contains($0) || tokens.contains("by\($0)") }
                if let family {
                    let slot = slots[family, default: 0]
                    slots[family] = slot + 1
                    identity = "plex:\(libraryID):recommendation:\(family):\(slot)"
                } else {
                    identity = "plex:\(libraryID):\(rawID)"
                }
            }
            let title = hub.title.flatMap {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0
            }
            return (
                ServerHomeSection(
                    id: identity, kind: kind, title: title,
                    libraryID: kind == .continueWatching ? nil : libraryID,
                    includesNextUp: kind == .continueWatching
                ),
                hub
            )
        }
    }

    private static func isServerHomeVideo(_ item: PlexMetadata) -> Bool {
        ["movie", "show", "season", "episode", "clip"].contains(item.type ?? "")
    }
}
