import Foundation
import SQLite3
import CoreModels
import MetadataKit

/// Catalog-backed projection for one live share-directory listing.
///
/// The live browser owns hierarchy and availability. This helper resolves files
/// and adds logical catalog entities only when persisted path evidence proves a
/// one-to-one identity. Unproven folders keep their navigation and may borrow
/// artwork from structurally matching catalog content. Queries are batched and
/// bounded; no network work occurs here.
struct ShareCatalogBrowseProjection {
    private struct AssetRow {
        var relPath: String
        var kind: CatalogAssetKind
        var groupKey: String?
    }

    private struct FolderEvidence {
        var assetCount: Int
        var movieCount: Int
        var episodeCount: Int
        var movieGroupCount: Int
        var movieGroup: String?
        var nullMovieGroupCount: Int
        var movieKeyCount: Int
        var movieKey: String?
        var nullMovieKeyCount: Int
        var movieTitleKeyCount: Int
        var movieTitleKey: String?
        var nullMovieTitleKeyCount: Int
        var directAssetCount: Int
        var seriesKeyCount: Int
        var seriesKey: String?
        var nullSeriesKeyCount: Int
        var seasonCount: Int
        var season: Int?
        var metadataRootCount: Int
        var metadataRoot: String?
        var nullMetadataRootCount: Int
    }

    private struct SeasonCandidate: Hashable {
        var folderPath: String
        var seriesKey: String
        var season: Int
    }

    private let connection: CatalogConnection
    private static let queryChunkSize = 150

    init(connection: CatalogConnection) {
        self.connection = connection
    }

    func project(
        _ items: [MediaItem],
        resolve: ([String]) -> [String: MediaItem]
    ) -> [MediaItem] {
        guard !items.isEmpty else { return [] }

        let filePaths = unique(items.compactMap(Self.filePath))
        let folderPaths = unique(items.compactMap(Self.folderPath))
        let exactFiles = loadExactFiles(filePaths)
        let folderEvidence = loadFolderEvidence(folderPaths)
        let movieNFOGroups = loadAssociatedMovieNFOGroups(folderPaths)
        let unambiguousFolders = loadProjectionSafeFolderPaths(folderPaths)

        var folderTargets: [String: String] = [:]
        var possibleSeasons: [SeasonCandidate] = []

        for folderPath in folderPaths {
            guard let evidence = folderEvidence[folderPath],
                  evidence.assetCount > 0
            else { continue }

            if let target = seriesTarget(folderPath: folderPath, evidence: evidence) {
                folderTargets[folderPath] = target
                continue
            }
            if let candidate = seasonCandidate(folderPath: folderPath, evidence: evidence) {
                possibleSeasons.append(candidate)
                continue
            }
            if let group = possibleMovieGroup(
                folderPath: folderPath,
                evidence: evidence,
                associatedMovieNFOGroups: movieNFOGroups[folderPath] ?? []
            ) {
                folderTargets[folderPath] = ShareCatalogID.movie(group)
            }
        }

        let completeSeasons = loadCompleteSeasonRoots(possibleSeasons)
        for candidate in possibleSeasons
        where completeSeasons[candidate] == true {
            folderTargets[candidate.folderPath] = ShareCatalogID.season(
                candidate.seriesKey,
                candidate.season
            )
        }

        let targets: [String?] = items.map { live in
            if let path = Self.folderPath(live) {
                return folderTargets[path]
            } else if let path = Self.filePath(live), let row = exactFiles[path] {
                if row.kind == .movie, let group = row.groupKey {
                    return ShareCatalogID.movie(group)
                } else {
                    return ShareCatalogID.file(path)
                }
            } else {
                return nil
            }
        }
        let catalogItems = resolve(unique(targets.compactMap { $0 }))
        var result: [MediaItem] = []
        result.reserveCapacity(items.count)
        var emittedCatalogIDs = Set<String>()

        for (live, targetID) in zip(items, targets) {
            guard let targetID, let catalogItem = catalogItems[targetID] else {
                result.append(live)
                continue
            }
            if let folderPath = Self.folderPath(live), !unambiguousFolders.contains(folderPath) {
                result.append(Self.decoratingFolder(live, with: catalogItem))
                continue
            }
            guard emittedCatalogIDs.insert(catalogItem.id).inserted else { continue }
            var projected = Self.preservingLiveState(catalogItem, from: live)
            if Self.folderPath(live) != nil {
                projected.fileBrowserContainerID = ShareCatalogID.fileBrowserID(for: live.id)
            }
            result.append(projected)
        }
        return result
    }

    /// Known mixed/unclassified content keeps folder navigation. Identity uses
    /// the retained catalog, not scan stamps: starting or cancelling maintenance
    /// must not turn an established title back into a folder. Newly added files
    /// remain reachable through the title's explicit file-browser route.
    private func loadProjectionSafeFolderPaths(_ paths: [String]) -> Set<String> {
        guard !paths.isEmpty else { return [] }
        var result = Set<String>()
        for chunk in paths.chunked(maxCount: Self.queryChunkSize) {
            let values = Array(repeating: "(?,?,?)", count: chunk.count).joined(separator: ",")
            connection.query("""
            WITH requested(path, lower_path, upper_path) AS (VALUES \(values))
            SELECT r.path
            FROM requested r
            WHERE NOT EXISTS (
              SELECT 1
              FROM playable_inventory p
              WHERE p.rel_path >= r.lower_path AND p.rel_path < r.upper_path
                AND NOT EXISTS (
                  SELECT 1 FROM assets a
                  WHERE a.rel_path=p.rel_path
                )
                AND NOT EXISTS (
                  SELECT 1 FROM extras e
                  WHERE e.rel_path=p.rel_path AND e.owner_id IS NOT NULL
                    AND e.owner_kind IN ('movie','series','season','episode')
                )
            );
            """, bind: { stmt in
                var index: Int32 = 1
                for path in chunk {
                    CatalogConnection.bindText(stmt, index, path)
                    CatalogConnection.bindText(stmt, index + 1, path + "/")
                    CatalogConnection.bindText(stmt, index + 2, path + "0")
                    index += 3
                }
            }) { stmt in
                if let path = CatalogConnection.columnText(stmt, 0) { result.insert(path) }
            }
        }
        return result
    }

    private func seriesTarget(folderPath: String, evidence: FolderEvidence) -> String? {
        guard evidence.episodeCount == evidence.assetCount,
              evidence.seriesKeyCount == 1,
              evidence.nullSeriesKeyCount == 0,
              let key = evidence.seriesKey,
              evidence.metadataRootCount == 1,
              evidence.nullMetadataRootCount == 0,
              evidence.metadataRoot == folderPath
        else { return nil }
        return ShareCatalogID.series(key)
    }

    private func seasonCandidate(
        folderPath: String,
        evidence: FolderEvidence
    ) -> SeasonCandidate? {
        guard evidence.episodeCount == evidence.assetCount,
              evidence.seriesKeyCount == 1,
              evidence.nullSeriesKeyCount == 0,
              evidence.seasonCount == 1,
              let key = evidence.seriesKey,
              let season = evidence.season
        else { return nil }

        let parent = (folderPath as NSString).deletingLastPathComponent
        guard !parent.isEmpty,
              evidence.metadataRootCount == 1,
              evidence.nullMetadataRootCount == 0,
              evidence.metadataRoot == parent
        else { return nil }
        return SeasonCandidate(folderPath: folderPath, seriesKey: key, season: season)
    }

    private func possibleMovieGroup(
        folderPath: String,
        evidence: FolderEvidence,
        associatedMovieNFOGroups: Set<String>
    ) -> String? {
        // A title folder need only contain one movie, not every copy of that
        // movie elsewhere on the share. Its explicit file route stays local.
        guard evidence.movieCount == evidence.assetCount,
              evidence.movieGroupCount == 1,
              evidence.nullMovieGroupCount == 0,
              let group = evidence.movieGroup,
              evidence.directAssetCount == evidence.assetCount
        else { return nil }

        let folderName = (folderPath as NSString).lastPathComponent
        let folderIdentity = ShareMediaParser.movieGrouping(
            relPath: "\(folderPath)/__catalog_projection__.mkv",
            parsedTitle: "",
            parsedYear: nil
        )
        let folderKey = folderIdentity.year.map {
            ShareCatalogID.movieKey(fromTitle: folderIdentity.title, year: $0)
        }
        let matchesDedicatedFolder = folderKey != nil
            && evidence.movieKeyCount == 1
            && evidence.nullMovieKeyCount == 0
            && evidence.movieKey == folderKey
            && !folderName.isEmpty
        // The indexed file owns the identity. Folder labels can use a different
        // release year, including numeric titles such as "300 (2006)".
        let parsedFolder = ShareMediaParser.parseMovie(stem: folderName, parentFolder: nil)
        let normalizedFolderTitle = ShareCatalogID.seriesKey(fromTitle: folderName)
        let parsedFolderTitle = ShareCatalogID.seriesKey(fromTitle: parsedFolder.title)
        let isYearBucket = parsedFolder.year.map { normalizedFolderTitle == String($0) } ?? false
        let matchesTitleFolder = !ShareMediaParser.isLibraryRootName(folderName)
            && !isYearBucket
            && !normalizedFolderTitle.isEmpty
            && evidence.movieTitleKeyCount == 1
            && evidence.nullMovieTitleKeyCount == 0
            && (evidence.movieTitleKey == normalizedFolderTitle
                || evidence.movieTitleKey == parsedFolderTitle)
        let hasMatchingMovieNFO = associatedMovieNFOGroups.contains(group)
        guard matchesDedicatedFolder || matchesTitleFolder || hasMatchingMovieNFO else { return nil }
        return group
    }

    private func loadExactFiles(_ paths: [String]) -> [String: AssetRow] {
        guard !paths.isEmpty else { return [:] }
        var result: [String: AssetRow] = [:]
        for chunk in paths.chunked(maxCount: Self.queryChunkSize) {
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            connection.query("""
            SELECT rel_path, kind, COALESCE(movie_group_key,movie_key)
            FROM assets WHERE rel_path IN (\(placeholders));
            """, bind: { stmt in
                for (offset, path) in chunk.enumerated() {
                    CatalogConnection.bindText(stmt, Int32(offset + 1), path)
                }
            }) { stmt in
                guard let row = Self.assetRow(stmt) else { return }
                result[row.relPath] = row
            }
        }
        return result
    }

    private func loadFolderEvidence(_ paths: [String]) -> [String: FolderEvidence] {
        guard !paths.isEmpty else { return [:] }
        var result: [String: FolderEvidence] = [:]
        for chunk in paths.chunked(maxCount: Self.queryChunkSize) {
            let values = Array(repeating: "(?,?,?)", count: chunk.count).joined(separator: ",")
            connection.query("""
            WITH requested(path, lower_path, upper_path) AS (VALUES \(values))
            SELECT r.path,
                   COUNT(*) AS asset_count,
                   SUM(CASE WHEN a.kind='movie' THEN 1 ELSE 0 END) AS movie_count,
                   SUM(CASE WHEN a.kind='episode' THEN 1 ELSE 0 END) AS episode_count,
                   COUNT(DISTINCT CASE WHEN a.kind='movie'
                         THEN COALESCE(a.movie_group_key,a.movie_key) END) AS movie_group_count,
                   MIN(CASE WHEN a.kind='movie'
                       THEN COALESCE(a.movie_group_key,a.movie_key) END) AS movie_group,
                   SUM(CASE WHEN a.kind='movie'
                         AND COALESCE(a.movie_group_key,a.movie_key) IS NULL
                       THEN 1 ELSE 0 END) AS null_movie_group_count,
                   COUNT(DISTINCT CASE WHEN a.kind='movie' THEN a.movie_key END) AS movie_key_count,
                   MIN(CASE WHEN a.kind='movie' THEN a.movie_key END) AS movie_key,
                   SUM(CASE WHEN a.kind='movie' AND a.movie_key IS NULL THEN 1 ELSE 0 END)
                     AS null_movie_key_count,
                   COUNT(DISTINCT CASE WHEN a.kind='movie' THEN a.movie_title_key END)
                     AS movie_title_key_count,
                   MIN(CASE WHEN a.kind='movie' THEN a.movie_title_key END) AS movie_title_key,
                   SUM(CASE WHEN a.kind='movie' AND a.movie_title_key IS NULL THEN 1 ELSE 0 END)
                     AS null_movie_title_key_count,
                   SUM(CASE WHEN
                         substr(a.rel_path,1,length(a.rel_path)-length(a.basename)-1)=r.path
                       THEN 1 ELSE 0 END) AS direct_asset_count,
                   COUNT(DISTINCT CASE WHEN a.kind='episode' THEN a.series_key END) AS series_key_count,
                   MIN(CASE WHEN a.kind='episode' THEN a.series_key END) AS series_key,
                   SUM(CASE WHEN a.kind='episode' AND a.series_key IS NULL THEN 1 ELSE 0 END)
                     AS null_series_key_count,
                   COUNT(DISTINCT CASE WHEN a.kind='episode'
                         THEN COALESCE(a.season,1) END) AS season_count,
                   MIN(CASE WHEN a.kind='episode' THEN COALESCE(a.season,1) END) AS season,
                   COUNT(DISTINCT CASE WHEN a.kind='episode' THEN a.metadata_root END)
                     AS metadata_root_count,
                   MIN(CASE WHEN a.kind='episode' THEN a.metadata_root END) AS metadata_root,
                   SUM(CASE WHEN a.kind='episode' AND a.metadata_root IS NULL THEN 1 ELSE 0 END)
                     AS null_metadata_root_count
            FROM requested r
            JOIN assets a
              ON a.rel_path >= r.lower_path AND a.rel_path < r.upper_path
            GROUP BY r.path;
            """, bind: { stmt in
                var index: Int32 = 1
                for path in chunk {
                    CatalogConnection.bindText(stmt, index, path)
                    CatalogConnection.bindText(stmt, index + 1, path + "/")
                    CatalogConnection.bindText(stmt, index + 2, path + "0")
                    index += 3
                }
            }) { stmt in
                guard let path = CatalogConnection.columnText(stmt, 0) else { return }
                result[path] = FolderEvidence(
                    assetCount: Int(sqlite3_column_int64(stmt, 1)),
                    movieCount: Int(sqlite3_column_int64(stmt, 2)),
                    episodeCount: Int(sqlite3_column_int64(stmt, 3)),
                    movieGroupCount: Int(sqlite3_column_int64(stmt, 4)),
                    movieGroup: CatalogConnection.columnText(stmt, 5),
                    nullMovieGroupCount: Int(sqlite3_column_int64(stmt, 6)),
                    movieKeyCount: Int(sqlite3_column_int64(stmt, 7)),
                    movieKey: CatalogConnection.columnText(stmt, 8),
                    nullMovieKeyCount: Int(sqlite3_column_int64(stmt, 9)),
                    movieTitleKeyCount: Int(sqlite3_column_int64(stmt, 10)),
                    movieTitleKey: CatalogConnection.columnText(stmt, 11),
                    nullMovieTitleKeyCount: Int(sqlite3_column_int64(stmt, 12)),
                    directAssetCount: Int(sqlite3_column_int64(stmt, 13)),
                    seriesKeyCount: Int(sqlite3_column_int64(stmt, 14)),
                    seriesKey: CatalogConnection.columnText(stmt, 15),
                    nullSeriesKeyCount: Int(sqlite3_column_int64(stmt, 16)),
                    seasonCount: Int(sqlite3_column_int64(stmt, 17)),
                    season: sqlite3_column_type(stmt, 18) == SQLITE_NULL
                        ? nil
                        : Int(sqlite3_column_int64(stmt, 18)),
                    metadataRootCount: Int(sqlite3_column_int64(stmt, 19)),
                    metadataRoot: CatalogConnection.columnText(stmt, 20),
                    nullMetadataRootCount: Int(sqlite3_column_int64(stmt, 21))
                )
            }
        }
        return result
    }

    private func loadAssociatedMovieNFOGroups(_ paths: [String]) -> [String: Set<String>] {
        guard !paths.isEmpty else { return [:] }
        var result: [String: Set<String>] = [:]
        for chunk in paths.chunked(maxCount: Self.queryChunkSize) {
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            connection.query("""
            SELECT DISTINCT f.parent_dir, COALESCE(a.movie_group_key,a.movie_key)
            FROM local_metadata_files f
            JOIN assets a ON f.associated_item_id='f:' || a.rel_path
            WHERE f.kind='movieGeneric' AND f.associated_item_id IS NOT NULL
              AND f.parent_dir IN (\(placeholders))
              AND a.kind='movie'
              AND substr(a.rel_path,1,length(a.rel_path)-length(a.basename)-1)=f.parent_dir;
            """, bind: { stmt in
                for (offset, path) in chunk.enumerated() {
                    CatalogConnection.bindText(stmt, Int32(offset + 1), path)
                }
            }) { stmt in
                guard let path = CatalogConnection.columnText(stmt, 0),
                      let group = CatalogConnection.columnText(stmt, 1) else { return }
                result[path, default: []].insert(group)
            }
        }
        return result
    }

    /// A physical season folder is promoted only when it contains the complete
    /// catalog season, not a disc/release subset of that season.
    private func loadCompleteSeasonRoots(_ candidates: [SeasonCandidate]) -> [SeasonCandidate: Bool] {
        guard !candidates.isEmpty else { return [:] }
        var result: [SeasonCandidate: Bool] = [:]
        for chunk in candidates.chunked(maxCount: Self.queryChunkSize) {
            let values = Array(repeating: "(?,?,?,?,?)", count: chunk.count).joined(separator: ",")
            connection.query("""
            WITH requested(folder_path, lower_path, upper_path, series_key, season)
              AS (VALUES \(values))
            SELECT r.folder_path,
                   COUNT(a.rel_path) AS total_count,
                   SUM(CASE WHEN a.rel_path >= r.lower_path AND a.rel_path < r.upper_path
                            THEN 1 ELSE 0 END) AS contained_count
            FROM requested r
            JOIN assets a
              ON a.kind='episode' AND a.series_key=r.series_key
             AND COALESCE(a.season,1)=r.season
            GROUP BY r.folder_path;
            """, bind: { stmt in
                var index: Int32 = 1
                for candidate in chunk {
                    CatalogConnection.bindText(stmt, index, candidate.folderPath)
                    CatalogConnection.bindText(stmt, index + 1, candidate.folderPath + "/")
                    CatalogConnection.bindText(stmt, index + 2, candidate.folderPath + "0")
                    CatalogConnection.bindText(stmt, index + 3, candidate.seriesKey)
                    sqlite3_bind_int64(stmt, index + 4, Int64(candidate.season))
                    index += 5
                }
            }) { stmt in
                guard let folderPath = CatalogConnection.columnText(stmt, 0),
                      let candidate = chunk.first(where: { $0.folderPath == folderPath })
                else { return }
                result[candidate] = sqlite3_column_int64(stmt, 1) == sqlite3_column_int64(stmt, 2)
            }
        }
        return result
    }

    private static func assetRow(
        _ stmt: OpaquePointer?,
        startingAt base: Int32 = 0
    ) -> AssetRow? {
        guard let relPath = CatalogConnection.columnText(stmt, base),
              let rawKind = CatalogConnection.columnText(stmt, base + 1),
              let kind = CatalogAssetKind(rawValue: rawKind)
        else { return nil }
        return AssetRow(
            relPath: relPath,
            kind: kind,
            groupKey: CatalogConnection.columnText(stmt, base + 2)
        )
    }

    private static func filePath(_ item: MediaItem) -> String? {
        ShareCatalogID.relPath(forFileID: item.id)
    }

    private static func folderPath(_ item: MediaItem) -> String? {
        guard item.kind == .folder, item.id.hasPrefix("d:") else { return nil }
        let path = String(item.id.dropFirst(2))
        return path.isEmpty ? nil : path
    }

    private static func preservingLiveState(_ catalog: MediaItem, from live: MediaItem) -> MediaItem {
        var item = catalog
        item.watchlistAliasID = live.watchlistAliasID ?? catalog.watchlistAliasID
        item.resumePosition = live.resumePosition
        item.playedPercentage = live.playedPercentage
        item.isPlayed = live.isPlayed
        item.hasBeenPlayed = live.hasBeenPlayed
        item.isFavorite = live.isFavorite
        item.lastPlayedAt = live.lastPlayedAt
        item.sourceAccountID = live.sourceAccountID
        item.additionalSourceAccountIDs = live.additionalSourceAccountIDs
        item.sources = live.sources
        item.selectedVersionID = live.selectedVersionID
        item.selectedSourceAccountID = live.selectedSourceAccountID
        item.explicitSourceSelection = live.explicitSourceSelection
        return item
    }

    /// Appearance is not proof of complete contents. Keep the raw folder identity
    /// and action so pending scans and unclassified extras stay fully browsable.
    private static func decoratingFolder(_ live: MediaItem, with catalog: MediaItem) -> MediaItem {
        let placement: ArtworkPlacement = catalog.kind == .season ? .seasonPoster : .poster
        let posterReferences = catalog.artworkReferences(for: placement)
        guard let subject = ArtworkLookupSubject(catalog: catalog) else { return live }
        func eligible(_ url: URL?) -> URL? {
            guard let url else { return nil }
            return catalog.libraryArtworkURL(url) != nil
                || catalog.artworkMetadataSource(for: url).map(MetadataEnrichmentConfig.defaultBaseOrder.contains) == true
                ? url : nil
        }
        var item = live
        item.artworkLookupSubject = subject
        item.posterURL = live.posterURL ?? eligible(catalog.posterURL)
        item.seriesPosterURL = live.seriesPosterURL ?? eligible(catalog.seriesPosterURL)
        item.backdropURL = live.backdropURL ?? eligible(catalog.backdropURL)
        item.heroBackdropURL = live.heroBackdropURL ?? eligible(catalog.heroBackdropURL)
        item.fallbackArtworkURL = live.fallbackArtworkURL ?? eligible(catalog.fallbackArtworkURL)
        item.logoURL = live.logoURL ?? eligible(catalog.logoURL)
        item.productionYear = live.productionYear ?? catalog.productionYear
        var catalogSelections = catalog.artworkSelections.filter { $0.placement != .poster }
        let selectedPosters = catalog.artworkSelections.first { $0.placement == placement }?.references ?? []
        let posters = selectedPosters + posterReferences
        if !posters.isEmpty {
            catalogSelections.append(.init(placement: .poster, references: posters))
        }
        for selection in catalogSelections {
            if let index = item.artworkSelections.firstIndex(where: { $0.placement == selection.placement }) {
                var seen = Set<ArtworkReference>()
                item.artworkSelections[index] = .init(
                    placement: selection.placement,
                    references: (item.artworkSelections[index].references + selection.references)
                        .filter { seen.insert($0).inserted }
                )
            } else {
                var seen = Set<ArtworkReference>()
                item.artworkSelections.append(.init(
                    placement: selection.placement,
                    references: selection.references.filter { seen.insert($0).inserted }
                ))
            }
        }
        // The catalog resolver already applied provider enablement. Preserve its
        // attribution without recasting external artwork as a library selection.
        let liveURLs = [
            live.posterURL, live.seriesPosterURL, live.backdropURL,
            live.heroBackdropURL, live.fallbackArtworkURL, live.logoURL
        ]
        for url in [
            item.posterURL, item.seriesPosterURL, item.backdropURL,
            item.heroBackdropURL, item.fallbackArtworkURL, item.logoURL
        ].compactMap({ $0 }) {
            let source = liveURLs.contains(url)
                ? live.artworkMetadataSource(for: url) : catalog.artworkMetadataSource(for: url)
            item.recordArtworkMetadataSource(source ?? .server, for: url)
        }
        item.artworkMetadataSourcesByURL.merge(catalog.artworkMetadataSourcesByURL) { live, _ in live }
        item.artworkSourceAccountIDsByURL.merge(catalog.artworkSourceAccountIDsByURL) { live, _ in live }
        return item
    }

    private func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}

private extension Array {
    func chunked(maxCount: Int) -> [ArraySlice<Element>] {
        guard maxCount > 0, !isEmpty else { return [] }
        return stride(from: 0, to: count, by: maxCount).map {
            self[$0..<Swift.min($0 + maxCount, count)]
        }
    }
}
