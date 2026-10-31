import Foundation
import CoreModels
import CoreNetworking

struct HomeDisplayPreferencesDto: Decodable {
    let CustomPrefs: [String: String?]?
}

/// The native Emby ContentService contract. Only verified SectionType values
/// are interpreted; unknown sections retain their server-owned presentation.
struct EmbyHomeSectionDto: Decodable {
    let Id: String
    let Name: String? // l10n:content — server-authored section heading
    let CustomName: String? // l10n:content — server-authored section heading
    let SectionType: String?
    let CollectionType: String?
    let ItemTypes: [String]?
    let ParentId: String?
    let ParentItem: BaseItemDto?
    let IncludeNextUpInResume: Bool?
    let Query: EmbyHomeQueryDto?
}

struct EmbyHomeQueryDto: Decodable {
    let CollectionTypes: [String]?
    let IsResumable: Bool?
}

extension JellyfinProvider {
    public func homeRowPage(_ feed: HomeRowFeed, startIndex: Int, limit: Int) async throws -> HomeRowPage {
        guard startIndex >= 0, limit > 0, limit <= PageRequest.defaultLimit,
              startIndex < Int.max - limit else { throw AppError.invalidResponse }
        if case let .latest(libraries?) = feed {
            var items: [MediaItem] = []
            var seen = Set<String>()
            for library in libraries where library != collectionDirectoryID {
                try Task.checkCancellation()
                let latest = try await client.latestItems(
                    userID: session.userID, limit: startIndex + limit + 1, parentID: library
                )
                items += latest.filter { seen.insert($0.Id).inserted }.map { map(item: $0).taggingLibrary(library) }
            }
            return .prefix(items, startIndex: startIndex, limit: limit)
        }
        guard case let .server(section, excluded, _) = feed else {
            return try await homeRowPrefixPage(feed, startIndex: startIndex, limit: limit)
        }
        let items = try await loadServerHomeItems(
            section: section, limit: startIndex + limit + 1, excludingLibraryIDs: excluded,
            allowedParents: nil, isPreview: false
        )
        return .prefix(items, startIndex: startIndex, limit: limit)
    }

    public func serverHomeLayout() async throws -> ServerHomeLayout? {
        if kind == .emby {
            let native: [EmbyHomeSectionDto]?
            do {
                native = try await client.nativeHomeSections(userID: session.userID)
            } catch AppError.notFound {
                // Only a missing ContentService endpoint permits legacy fallback.
                native = nil
            }
            if let native {
                let views = try await client.userViews(userID: session.userID)
                return nativeHomeLayout(native, views: views)
            }
        }
        let preferences: HomeDisplayPreferencesDto
        do {
            preferences = try await client.homeDisplayPreferences(userID: session.userID)
        } catch AppError.notFound {
            return nil
        }
        let views = try await client.userViews(userID: session.userID)
        return webHomeLayout(preferences, views: views)
    }

    public func serverHomeItems(
        section: ServerHomeSection, limit: Int, excludingLibraryIDs: Set<String>
    ) async throws -> [MediaItem] {
        return try await loadServerHomeItems(
            section: section, limit: limit, excludingLibraryIDs: excludingLibraryIDs,
            allowedParents: nil
        )
    }

    public func serverHomeItems(
        sections: [ServerHomeSection], limit: Int, excludingLibraryIDs: Set<String>
    ) async -> [String: Result<[MediaItem], AppError>] {
        var allowedParents: Result<[String?], AppError>?
        var results: [String: Result<[MediaItem], AppError>] = [:]
        for section in sections where results[section.id] == nil {
            do {
                try Task.checkCancellation()
                if allowedParents == nil, limit > 0, !excludingLibraryIDs.isEmpty,
                   section.libraryID == nil, section.kind != .libraries, section.kind != .liveTV,
                   !(section.kind == .recordings && section.id.hasPrefix("web:")) {
                    do {
                        allowedParents = .success(try await homeVisibleParents(excluding: excludingLibraryIDs))
                    } catch {
                        // Retain a failed lookup too: dependent rows share the
                        // failure, while library-scoped rows can still succeed.
                        allowedParents = .failure(Self.homeRequestError(error))
                    }
                }
                results[section.id] = .success(try await loadServerHomeItems(
                    section: section, limit: limit, excludingLibraryIDs: excludingLibraryIDs,
                    allowedParents: allowedParents
                ))
            } catch {
                results[section.id] = .failure(Self.homeRequestError(error))
            }
        }
        return results
    }

    private func loadServerHomeItems(
        section: ServerHomeSection, limit: Int, excludingLibraryIDs: Set<String>,
        allowedParents: Result<[String?], AppError>?, isPreview: Bool = true
    ) async throws -> [MediaItem] {
        guard limit > 0, section.kind != .libraries, section.kind != .liveTV,
              section.libraryID.map({ !excludingLibraryIDs.contains($0) }) ?? true else { return [] }
        let boundedLimit = section.kind == .continueWatching || !isPreview ? limit : min(limit, 100)
        if section.id.hasPrefix("emby:") {
            guard kind == .emby else { throw AppError.invalidResponse }
            let nativeID = String(section.id.dropFirst("emby:".count))
            let parents = try await homeParents(
                for: section, excluding: excludingLibraryIDs, allowedParents: allowedParents
            )
            var result: [MediaItem] = []
            var seen = Set<String>()
            for parent in parents {
                try Task.checkCancellation()
                let items = try await client.nativeHomeItems(
                    userID: session.userID, sectionID: nativeID,
                    limit: boundedLimit, parentID: parent
                )
                result += items.filter { Self.isHomeVideo($0) && seen.insert($0.Id).inserted }
                    .map { map(item: $0).taggingLibrary(parent) }
            }
            return Array(result.prefix(boundedLimit))
        }
        guard section.id.hasPrefix("web:") else { throw AppError.invalidResponse }
        if section.kind == .recordings {
            // Recordings has no library filter or reliable root-library attribution.
            // Do not let this unscoped endpoint bypass a hidden library.
            guard excludingLibraryIDs.isEmpty else { return [] }
            let items = try await client.activeHomeRecordings(
                userID: session.userID, limit: boundedLimit
            )
            return Array(items.filter(Self.isHomeVideo).prefix(boundedLimit)).map(map(item:))
        }
        let parents = try await homeParents(
            for: section, excluding: excludingLibraryIDs, allowedParents: allowedParents
        )
        var result: [MediaItem] = []
        var seen = Set<String>()
        for parent in parents {
            try Task.checkCancellation()
            let items: [BaseItemDto]
            switch section.kind {
            case .continueWatching:
                items = try await client.resumeItems(
                    userID: session.userID, limit: boundedLimit, parentID: parent
                )
            case .nextUp:
                items = try await client.nextUpItems(
                    userID: session.userID, limit: boundedLimit, parentID: parent
                )
            case .recentlyAdded:
                guard let parent else { throw AppError.invalidResponse }
                items = try await client.latestItems(
                    userID: session.userID, limit: boundedLimit, parentID: parent, videoOnly: true
                )
            default:
                throw AppError.invalidResponse
            }
            result += items.filter { Self.isHomeVideo($0) && seen.insert($0.Id).inserted }
                .map { map(item: $0).taggingLibrary(parent) }
        }
        return Array(result.prefix(boundedLimit))
    }

    private func homeParents(
        for section: ServerHomeSection, excluding libraryIDs: Set<String>,
        allowedParents: Result<[String?], AppError>?
    ) async throws -> [String?] {
        if let libraryID = section.libraryID { return [libraryID] }
        guard !libraryIDs.isEmpty else { return [nil] }
        if let allowedParents { return try allowedParents.get() }
        return try await homeVisibleParents(excluding: libraryIDs)
    }

    private func homeVisibleParents(excluding libraryIDs: Set<String>) async throws -> [String?] {
        return try await client.userViews(userID: session.userID)
            .filter { Self.isHomeVideoView($0) && !libraryIDs.contains($0.Id) }
            .map { Optional($0.Id) }
    }

    private static func homeRequestError(_ error: Error) -> AppError {
        (error as? AppError) ?? (error is CancellationError ? .cancelled : .invalidResponse)
    }

    private func webHomeLayout(
        _ preferences: HomeDisplayPreferencesDto, views: [BaseItemDto]
    ) -> ServerHomeLayout {
        let defaults = [
            "smalllibrarytiles", "resume", "resumeaudio", "resumebook", "livetv",
            "nextup", "latestmedia", "none", "none", "none"
        ]
        var layout = ServerHomeLayout(
            sections: [], source: .webPreferences,
            omitsReading: views.contains { Self.isReadingCollection($0.CollectionType) },
            omitsMusic: views.contains { Self.isMusicCollection($0.CollectionType) }
        )
        for (slot, defaultValue) in defaults.enumerated() {
            let configured = preferences.CustomPrefs?["homesection\(slot)"] ?? nil
            let value = configured.flatMap { $0.isEmpty ? nil : $0 } ?? defaultValue
            let id = "web:\(slot):\(value)"
            let kind: ServerHomeSection.Kind
            switch value {
            case "smalllibrarytiles", "librarybuttons", "folders": kind = .libraries
            case "resume": kind = .continueWatching
            case "nextup": kind = .nextUp
            case "livetv": kind = .liveTV
            case "activerecordings": kind = .recordings
            case "resumeaudio":
                layout.omitsMusic = true
                continue
            case "resumebook":
                layout.omitsReading = true
                continue
            case "latestmedia":
                layout.sections += views.filter(Self.isHomeVideoView).map {
                    ServerHomeSection(
                        id: "\(id):\($0.Id)", kind: .recentlyAdded,
                        title: $0.Name, libraryID: $0.Id
                    )
                }
                continue
            default: continue
            }
            layout.sections.append(ServerHomeSection(id: id, kind: kind))
        }
        return layout
    }

    private func nativeHomeLayout(
        _ native: [EmbyHomeSectionDto], views: [BaseItemDto]
    ) -> ServerHomeLayout {
        let viewIDs = Set(views.map(\.Id))
        var layout = ServerHomeLayout(
            sections: [], source: .server,
            omitsReading: views.contains { Self.isReadingCollection($0.CollectionType) },
            omitsMusic: views.contains { Self.isMusicCollection($0.CollectionType) }
        )
        var seen = Set<String>()
        for section in native {
            let parent = section.ParentId ?? section.ParentItem?.Id
            let collectionType = section.CollectionType ?? section.ParentItem?.CollectionType
                ?? views.first(where: { $0.Id == parent })?.CollectionType
            let collections = Set(([collectionType].compactMap { $0 }
                + (section.Query?.CollectionTypes ?? [])).map { $0.lowercased() })
            let itemTypes = Set((section.ItemTypes ?? []).map { $0.lowercased() })
            let music = collections.contains(where: { Self.isMusicCollection($0) })
                || !itemTypes.isDisjoint(with: ["audio", "musicalbum", "musicartist"])
            let reading = collections.contains(where: { Self.isReadingCollection($0) })
                || !itemTypes.isDisjoint(with: ["book", "audiobook"])
            layout.omitsMusic = layout.omitsMusic || music
            layout.omitsReading = layout.omitsReading || reading
            let videoTypes: Set<String> = ["movie", "series", "season", "episode", "video"]
            guard !(music || reading) || !itemTypes.isDisjoint(with: videoTypes) else { continue }
            guard !section.Id.isEmpty, seen.insert(section.Id).inserted else { continue }
            let kind: ServerHomeSection.Kind
            if collections.contains("livetv")
                || !itemTypes.isDisjoint(with: ["tvchannel", "program"]) {
                kind = .liveTV
            } else if !itemTypes.isEmpty
                        && itemTypes.isSubset(of: ["collectionfolder", "userview"]) {
                kind = .libraries
            } else if section.Query?.IsResumable == true {
                kind = .continueWatching
            } else if section.SectionType?.lowercased() == "latestmedia" {
                kind = .recentlyAdded
            } else {
                kind = .recommendations
            }
            let title = [section.CustomName, section.Name].compactMap { $0 }
                .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            layout.sections.append(ServerHomeSection(
                id: "emby:\(section.Id)", kind: kind, title: title,
                libraryID: parent.flatMap { viewIDs.contains($0) ? $0 : nil },
                includesNextUp: section.IncludeNextUpInResume ?? false
            ))
        }
        return layout
    }

    private static func isMusicCollection(_ type: String?) -> Bool {
        ["music", "musicvideos"].contains(type?.lowercased() ?? "")
    }

    private static func isReadingCollection(_ type: String?) -> Bool {
        ["books", "audiobooks"].contains(type?.lowercased() ?? "")
    }

    private static func isHomeVideoView(_ item: BaseItemDto) -> Bool {
        let type = item.CollectionType?.lowercased() ?? ""
        return !isMusicCollection(type) && !isReadingCollection(type)
            && !["playlists", "livetv", "boxsets", "channels", "folders", "photos"].contains(type)
    }

    private static func isHomeVideo(_ item: BaseItemDto) -> Bool {
        ["movie", "series", "season", "episode", "video"].contains(item.Type?.lowercased() ?? "")
    }
}
