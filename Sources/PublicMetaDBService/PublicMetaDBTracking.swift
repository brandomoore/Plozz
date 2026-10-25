import Foundation

extension PublicMetaDB {
    public struct ResumeBatchResult: Decodable, Sendable {
        public struct Summary: Decodable, Sendable {
            public let saved: Int
            public let completed: Int
            public let ignored: Int
            public let errors: Int
        }

        public struct Outcome: Decodable, Sendable {
            public enum Action: String, Decodable, Sendable { case saved, completed, ignored, error }
            public let content: Content?
            public let action: Action
            public let progress: Double?

            private enum CodingKeys: String, CodingKey { case action, progress, tmdbID = "tmdb_id" }

            public init(from decoder: Decoder) throws {
                let values = try decoder.container(keyedBy: CodingKeys.self)
                action = try values.decode(Action.self, forKey: .action)
                progress = try values.decodeIfPresent(Double.self, forKey: .progress)
                content = values.contains(.tmdbID) ? try Content(from: decoder) : nil
                guard action == .error || content != nil else { throw Failure.incompleteResponse }
            }
        }

        public let results: [Outcome]
        public let summary: Summary
        public var isCompleteSuccess: Bool { summary.errors == 0 }

        func validate(expected: Int) throws {
            guard results.count == expected,
                  summary.saved == results.filter({ $0.action == .saved }).count,
                  summary.completed == results.filter({ $0.action == .completed }).count,
                  summary.ignored == results.filter({ $0.action == .ignored }).count,
                  summary.errors == results.filter({ $0.action == .error }).count else {
                throw Failure.uncertainWrite
            }
        }
    }
}

public extension PublicMetaDBClient {
    func resumePoints(
        content: PublicMetaDB.Content? = nil, page: Int = 1, perPage: Int = 100
    ) async throws -> PublicMetaDB.Page<PublicMetaDB.Record<PublicMetaDB.Resume>> {
        try await self.page(
            PublicMetaDB.Record<PublicMetaDB.Resume>.self, path: "/resume",
            query: content?.query ?? [], page: page, perPage: perPage
        )
    }

    func resumePoints(
        idType: PublicMetaDB.ExternalIDType, idValue: String,
        mediaType: PublicMetaDB.MediaType? = nil, season: Int? = nil, episode: Int? = nil,
        page: Int = 1, perPage: Int = 100
    ) async throws -> PublicMetaDB.Page<PublicMetaDB.Record<PublicMetaDB.Resume>> {
        guard !idValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              season.map({ $0 >= 0 }) ?? true, episode.map({ $0 > 0 }) ?? true,
              episode == nil || season != nil, mediaType != .movie || (season == nil && episode == nil) else {
            throw PublicMetaDB.Failure.invalidInput
        }
        var query = [URLQueryItem(name: "id_type", value: idType.rawValue), .init(name: "id_value", value: idValue)]
        if let mediaType { query.append(.init(name: "media_type", value: mediaType.rawValue)) }
        if let season { query.append(.init(name: "season", value: String(season))) }
        if let episode { query.append(.init(name: "episode", value: String(episode))) }
        return try await self.page(
            PublicMetaDB.Record<PublicMetaDB.Resume>.self, path: "/resume",
            query: query, page: page, perPage: perPage
        )
    }

    func saveResume(_ resume: PublicMetaDB.Resume) async throws -> PublicMetaDB.ResumeResult {
        let result = try await send(
            PublicMetaDB.ResumeResult.self, method: .post, path: "/resume", body: Self.encode(resume)
        )
        guard result.action == resume.expectedDisposition else { throw PublicMetaDB.Failure.uncertainWrite }
        if result.action == .saved {
            guard let item = result.item, item.value.content == resume.content,
                  item.value.positionMilliseconds == resume.positionMilliseconds,
                  item.value.runtimeMilliseconds == resume.runtimeMilliseconds else {
                throw PublicMetaDB.Failure.uncertainWrite
            }
        } else if result.action == .completed {
            guard result.content == resume.content else { throw PublicMetaDB.Failure.uncertainWrite }
        }
        return result
    }

    func saveResumeBatch(_ resumes: [PublicMetaDB.Resume]) async throws -> PublicMetaDB.ResumeBatchResult {
        guard (1...50).contains(resumes.count),
              Set(resumes.map(\.content)).count == resumes.count else { throw PublicMetaDB.Failure.invalidInput }
        let result = try await send(
            PublicMetaDB.ResumeBatchResult.self, method: .post, path: "/resume/batch",
            body: Self.encode(ResumeBatchBody(items: resumes))
        )
        try result.validate(expected: resumes.count)
        let returned = result.results.compactMap(\.content)
        guard Set(returned).count == returned.count, Set(returned).isSubset(of: Set(resumes.map(\.content))) else {
            throw PublicMetaDB.Failure.uncertainWrite
        }
        return result
    }

    func deleteResume(id: String) async throws {
        try await acknowledge(path: "/resume/\(Self.component(id))")
    }

    func history(
        content: PublicMetaDB.Content? = nil, page: Int = 1, perPage: Int = 100
    ) async throws -> PublicMetaDB.Page<PublicMetaDB.Record<PublicMetaDB.Watch>> {
        try await self.page(
            PublicMetaDB.Record<PublicMetaDB.Watch>.self, path: "/watched",
            query: content?.query ?? [], page: page, perPage: perPage
        )
    }

    func watchedShows(page: Int = 1, perPage: Int = 100) async throws -> PublicMetaDB.Page<PublicMetaDB.ShowTotal> {
        try await self.page(PublicMetaDB.ShowTotal.self, path: "/watched/shows", page: page, perPage: perPage)
    }

    func recordWatch(
        _ content: PublicMetaDB.Content, at date: PublicMetaDB.WatchDate
    ) async throws -> PublicMetaDB.Record<PublicMetaDB.Watch> {
        guard content.isPlayable else { throw PublicMetaDB.Failure.invalidInput }
        // dedupe=true suppresses genuine rewatches. Coordination must reconcile uncertain deliveries.
        let result = try await create(
            PublicMetaDB.Record<PublicMetaDB.Watch>.self, path: "/watched",
            body: WatchBody(content: content, date: date)
        )
        guard result.value.content == content, date.matches(result.value.watchedAt) else {
            throw PublicMetaDB.Failure.uncertainWrite
        }
        return result
    }

    /// A library watched flag is not evidence of a new play. Unlike playback
    /// reporting, backfill also asks the server to suppress concurrent duplicates.
    func backfillWatch(
        _ content: PublicMetaDB.Content, at date: PublicMetaDB.WatchDate
    ) async throws -> PublicMetaDB.Record<PublicMetaDB.Watch> {
        guard content.isPlayable, date != .now else { throw PublicMetaDB.Failure.invalidInput }
        let result = try await create(
            PublicMetaDB.Record<PublicMetaDB.Watch>.self, path: "/watched",
            query: [URLQueryItem(name: "dedupe", value: "true")],
            body: WatchBody(content: content, date: date)
        )
        guard result.value.content == content else { throw PublicMetaDB.Failure.uncertainWrite }
        return result
    }

    func updateWatchDate(id: String, at date: PublicMetaDB.WatchDate) async throws -> PublicMetaDB.Record<PublicMetaDB.Watch> {
        guard date != .now else { throw PublicMetaDB.Failure.invalidInput }
        let result = try await create(
            PublicMetaDB.Record<PublicMetaDB.Watch>.self, method: .patch,
            path: "/watched/\(Self.component(id))", body: WatchDateBody(date: date)
        )
        guard result.id == id, date.matches(result.value.watchedAt) else { throw PublicMetaDB.Failure.uncertainWrite }
        return result
    }

    func deleteWatch(id: String) async throws {
        try await acknowledge(path: "/watched/\(Self.component(id))")
    }

    /// Destructive, explicit scope only. Never called to reconcile missing observations.
    func deleteWatches(matching content: PublicMetaDB.Content) async throws {
        try await acknowledge(path: "/watched", query: content.query)
    }

    func dropped(page: Int = 1, perPage: Int = 100) async throws -> PublicMetaDB.Page<PublicMetaDB.Record<PublicMetaDB.Content>> {
        try await self.page(
            PublicMetaDB.Record<PublicMetaDB.Content>.self, path: "/dropped", page: page, perPage: perPage
        )
    }

    func drop(_ content: PublicMetaDB.Content) async throws {
        guard content.mediaType == .tv, content.season == nil, content.episode == nil else {
            throw PublicMetaDB.Failure.invalidInput
        }
        try await acknowledge(method: .post, path: "/dropped", body: Self.encode(content))
    }

    func undrop(_ content: PublicMetaDB.Content) async throws {
        guard content.mediaType == .tv, content.season == nil, content.episode == nil else {
            throw PublicMetaDB.Failure.invalidInput
        }
        try await acknowledge(path: "/dropped/\(content.tmdbID)/\(content.mediaType.rawValue)")
    }

    func completeHistory(maximumPages: Int = 100) async throws -> [PublicMetaDB.Record<PublicMetaDB.Watch>] {
        try await completePages(maximumPages: maximumPages) { try await history(page: $0, perPage: 500) }
    }

    func completeResumePoints(maximumPages: Int = 100) async throws -> [PublicMetaDB.Record<PublicMetaDB.Resume>] {
        try await completePages(maximumPages: maximumPages) { try await resumePoints(page: $0, perPage: 500) }
    }
}

extension PublicMetaDBClient {
    func completePages<Item: Decodable & Identifiable & Sendable>(
        maximumPages: Int,
        load: @Sendable (Int) async throws -> PublicMetaDB.Page<Item>
    ) async throws -> [Item] {
        guard (1...1_000).contains(maximumPages) else { throw PublicMetaDB.Failure.invalidInput }
        var records: [Item] = []
        var ids = Set<Item.ID>()
        var expectedTotal: Int?
        for pageNumber in 1...maximumPages {
            try Task.checkCancellation()
            let page = try await load(pageNumber)
            if let expectedTotal, expectedTotal != page.total { throw PublicMetaDB.Failure.incompleteResponse }
            expectedTotal = page.total
            for item in page.items {
                guard ids.insert(item.id).inserted else { throw PublicMetaDB.Failure.incompleteResponse }
                records.append(item)
            }
            if page.page >= page.totalPages {
                guard records.count == page.total else { throw PublicMetaDB.Failure.incompleteResponse }
                return records
            }
        }
        throw PublicMetaDB.Failure.incompleteResponse
    }
}

private struct ResumeBatchBody: Encodable {
    let items: [PublicMetaDB.Resume]
}

private struct WatchBody: Encodable {
    let content: PublicMetaDB.Content
    let date: PublicMetaDB.WatchDate

    func encode(to encoder: Encoder) throws {
        try content.encode(to: encoder)
        try WatchDateBody(date: date).encode(to: encoder)
    }
}

private struct WatchDateBody: Encodable {
    let date: PublicMetaDB.WatchDate
    enum CodingKeys: String, CodingKey { case watchedAt = "watched_at" }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch date {
        case .now: break
        case .unknown: try values.encodeNil(forKey: .watchedAt)
        case .known(let date):
            guard date.timeIntervalSince1970.isFinite else { throw PublicMetaDB.Failure.invalidInput }
            try values.encode(date, forKey: .watchedAt)
        }
    }
}
