import CoreModels
import CoreNetworking
import Foundation

extension SiloProvider: LibraryChannelCatalogProviding, LibraryChannelPlaybackProviding {
    public func prepareLibraryChannels() async throws {
        let capability: SiloPlaybackCapabilities = try await client.request("/playback/capabilities")
        guard capability.allowed else { throw AppError.unauthorized }
        guard capability.state == "available" else { throw LibraryChannelError.sourceUnavailable }
        guard capability.protocol_versions.contains(3), capability.deliveries.contains("original_http") else {
            throw LibraryChannelError.sourceUnsupported
        }
    }

    public func libraryChannelItems(
        in libraryID: String, kind: MediaItemKind, page: PageRequest
    ) async throws -> MediaPage {
        guard [.movie, .episode, .series].contains(kind), (1...500).contains(page.limit),
              page.startIndex >= 0 else { throw LibraryChannelError.invalidRecipe }
        guard try await libraries().contains(where: { $0.id == libraryID }) else {
            throw LibraryChannelError.authorizationChanged
        }
        // Catalog runtimes are metadata minutes, not the selected file's timeline.
        let response: SiloCatalogPage = try await client.request("/catalog", query: [
            .init(name: "library_id", value: libraryID), .init(name: "type", value: kind.rawValue),
            .init(name: "seek", value: String(page.startIndex)),
            .init(name: "limit", value: String(min(page.limit, 200))), .init(name: "sort", value: "title")
        ])
        guard response.total_exact, response.total >= page.startIndex,
              response.items.count <= min(page.limit, 200),
              response.items.count <= response.total - page.startIndex,
              !response.items.isEmpty || page.startIndex == response.total,
              Set(response.items.map(\.content_id)).count == response.items.count else {
            throw LibraryChannelError.catalogChanged
        }
        if kind == .series {
            return MediaPage(items: response.items.map { map($0, libraryID: libraryID) },
                             startIndex: page.startIndex, totalCount: response.total)
        }
        var items: [MediaItem] = []
        for offset in stride(from: 0, to: response.items.count, by: 4) {
            try Task.checkCancellation()
            let batch = Array(response.items[offset..<min(offset + 4, response.items.count)])
            let hydrated = try await withThrowingTaskGroup(of: (Int, MediaItem).self) { group in
                for (index, summary) in batch.enumerated() {
                    group.addTask { [self] in
                        let detail: SiloItem = try await client.request(
                            "/catalog/items/\(try SiloAPI.pathComponent(summary.content_id))",
                            query: [.init(name: "library_id", value: libraryID)])
                        guard detail.content_id == summary.content_id, detail.type == kind.rawValue else {
                            throw LibraryChannelError.catalogChanged
                        }
                        var item = map(detail, libraryID: libraryID)
                        let file = detail.versions?.first(where: Self.isChannelFile)
                        item.selectedVersionID = file?.file_id
                        item.versions = file.flatMap { selected in item.versions.first { $0.id == selected.file_id } }
                            .map { [$0] } ?? []
                        item.runtime = file?.duration
                        item.mediaInfo = file.map(metadata)
                        item.resumePosition = nil
                        return (index, item)
                    }
                }
                var result: [(Int, MediaItem)] = []
                for try await item in group { result.append(item) }
                return result.sorted { $0.0 < $1.0 }.map(\.1)
            }
            items += hydrated
        }
        return MediaPage(items: items, startIndex: page.startIndex, totalCount: response.total)
    }

    public func libraryChannelPlayback(for item: LibraryChannelItem) async throws -> PlaybackRequest {
        try item.validate()
        let credential = try SiloCredential.decode(session.accessToken)
        guard item.library.accountID == accountID, item.serverID == session.server.id,
              item.userID == session.userID,
              "\(credential.accountID):\(credential.profileID)" == item.userID else {
            throw LibraryChannelError.authorizationChanged
        }
        guard try await libraries().contains(where: { $0.id == item.library.libraryID }) else {
            throw LibraryChannelError.authorizationChanged
        }
        guard item.mediaSourceID != nil else { throw LibraryChannelError.mediaChanged }
        // A lost start response still owns its attempt. Recover and retire it
        // before creating a different session, even when both initial replies were lost.
        for pending in await playback.pendingLibraryStarts() {
            let decision: SiloPlaybackDecision = try await client.request(
                "/playback/start", method: .post, body: pending.body)
            if let id = decision.session_id ?? decision.playback_plan?.session_id, !id.isEmpty {
                await playback.retainLibraryRelease(
                    id: id, itemID: pending.itemID, installationID: pending.installationID)
                let release = Task { try await releaseLibrarySession(id: id, itemID: pending.itemID) }
                try await release.value
            } else {
                guard decision.protocol_version == 3, decision.terminal != nil else {
                    throw AppError.invalidResponse
                }
            }
            await playback.removeLibraryStart(pending.attemptID)
        }
        // An earlier unconfirmed stop must not accumulate orphaned sessions on Retry.
        for pending in await playback.pendingLibraryReleases() {
            try await releaseLibrarySession(id: pending.id, itemID: pending.itemID)
        }
        return try await resolvePlayback(
            for: item.itemID, mediaSourceID: item.mediaSourceID, forceTranscode: false,
            streaming: nil, libraryChannel: item)
    }

    public func reportLibraryChannelPlayback(_ progress: PlaybackProgress) async throws {
        try await reportSession(progress, event: .progress, libraryChannel: true)
    }

    public func releaseLibraryChannelPlayback(_ request: PlaybackRequest) async throws {
        guard request.suppressOrdinaryWatchReporting, let id = request.playSessionID else { return }
        try await releaseLibrarySession(id: id, itemID: request.item.id)
    }

    func releaseLibrarySession(id: String, itemID: String) async throws {
        guard let context = await playback.releaseContext(
            id: id, itemID: itemID, libraryChannel: true) else { return }
        struct Body: Encodable { let installation_id: String; let stop_id: String }
        struct Receipt: Decodable, Sendable { let outcome: String }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let body = try encoder.encode(Body(
            installation_id: context.installationID, stop_id: context.stopID))
        // A bounded retry reuses the same stop receipt. Never send a final position.
        for attempt in 0..<2 {
            do {
                let receipt: Receipt = try await client.request(
                    "/playback/\(try SiloAPI.pathComponent(id))", method: .delete, body: body)
                guard ["stopped", "replayed"].contains(receipt.outcome) else { throw AppError.invalidResponse }
                await playback.remove(id)
                return
            } catch AppError.notFound {
                await playback.remove(id)
                return
            } catch {
                guard attempt == 0, error is URLError || (error as? AppError) == .serverUnreachable else {
                    throw error
                }
            }
        }
    }

    public func recordLibraryChannelCompletion(itemID: String) async throws {
        try await client.send("/watched/\(try SiloAPI.pathComponent(itemID))", method: .post)
    }

    func validateLibraryChannel(_ item: LibraryChannelItem, detail: SiloItem, file: SiloFileVersion) throws {
        guard detail.content_id == item.itemID, detail.type == item.kind.rawValue,
              file.file_id == item.mediaSourceID, Self.isChannelFile(file),
              Int64(file.duration.rounded(.down)) == item.durationSeconds,
              item.sourceSizeBytes == file.file_size, item.edition == file.edition_raw,
              item.sourceRevision == nil,
              item.seriesID == map(detail).seriesID else { throw LibraryChannelError.mediaChanged }
    }

    private static func isChannelFile(_ file: SiloFileVersion) -> Bool {
        file.duration.isFinite && (1...604_800).contains(file.duration) && file.file_size > 0
            && !file.file_id.isEmpty && !file.container.isEmpty
            && !["iso", "dvd", "bluray"].contains(file.container.lowercased())
            && (file.presentation_part_total ?? 1) <= 1
            && file.presentation_kind != "multipart"
            && (file.multi_episode_start == nil || file.multi_episode_end == nil
                || file.multi_episode_start == file.multi_episode_end)
    }
}
