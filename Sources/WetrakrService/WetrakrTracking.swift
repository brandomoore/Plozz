import CoreModels
import CoreNetworking
import Foundation

struct WetrakrTrackingBody: Encodable, Sendable {
    struct Item: Encodable, Sendable {
        var id: Int?
        var ids: WetrakrIDs?
        var number: Int?
        var status: String?
        var trackedAt: String?
        var trackedAtUnknown: Bool?
        var seasons: [Item]?
        var episodes: [Item]?
        enum CodingKeys: String, CodingKey {
            case id, ids, number, status, seasons, episodes, trackedAt = "tracked_at", trackedAtUnknown = "tracked_at_unknown"
        }
    }
    var movies: [Item]?
    var shows: [Item]?
    var episodes: [Item]?
    var allowRewatch: Bool?
    enum CodingKeys: String, CodingKey { case movies, shows, episodes, allowRewatch = "allow_rewatch" }
}

struct WetrakrTrackingResult: Decodable, Sendable {
    struct Counts: Decodable, Sendable {
        let total: Int?
        let movies: Int?
        let shows: Int?
        let episodes: Int?
        var hasChanges: Bool { [total, movies, shows, episodes].contains { ($0 ?? 0) > 0 } }
    }
    struct StatusCounts: Decodable, Sendable {
        let total: Int?
        let planning: Counts?
        let watched: Counts?
        var hasChanges: Bool { (total ?? 0) > 0 || planning?.hasChanges == true || watched?.hasChanges == true }
    }
    struct Failure: Decodable, Sendable {
        let id: Int?
        let ids: WetrakrIDs?
        let error: String?
    }
    let added: StatusCounts?
    let removed: StatusCounts?
    let existing: StatusCounts?
    let notFound: [String: [Failure]]?
    let errored: [String: [Failure]]?

    func planningOutcomes(
        movies: [WetrakrTrackingBody.Item], shows: [WetrakrTrackingBody.Item], removing: Bool
    ) throws -> [Result<Void, WatchlistDestinationError>] {
        for groups in [notFound, errored] {
            guard groups?.allSatisfy({ ["movies", "shows"].contains($0.key) || $0.value.isEmpty }) != false
            else { throw AppError.invalidResponse }
        }
        var results: [Result<Void, WatchlistDestinationError>] = []
        for (name, items) in [("movies", movies), ("shows", shows)] {
            var identified: [Int: Result<Void, WatchlistDestinationError>] = [:]
            for (failures, unresolved) in [(notFound?[name] ?? [], true), (errored?[name] ?? [], false)] {
                for failure in failures {
                    let matches = items.indices.filter { index in
                        let item = items[index]
                        if let id = failure.id, let expected = item.id { return id == expected }
                        if let ids = failure.ids, let expected = item.ids {
                            return Self.matches(ids.externalIDs, expected.externalIDs)
                        }
                        return failure.id == nil && failure.ids == nil && items.count == 1
                    }
                    guard matches.count == 1, let index = matches.first, identified[index] == nil
                    else { throw AppError.invalidResponse }
                    if unresolved {
                        identified[index] = .failure(.unsupportedIdentity)
                    } else if removing, failure.error == "Nothing to remove" {
                        identified[index] = .success(())
                    } else {
                        identified[index] = .failure(.permanent)
                    }
                }
            }
            let addedCount = name == "movies" ? added?.planning?.movies : added?.planning?.shows
            let existingCount = name == "movies" ? existing?.planning?.movies : existing?.planning?.shows
            let removedCount = name == "movies" ? removed?.planning?.movies : removed?.planning?.shows
            let counts = removing ? [removedCount ?? 0] : [addedCount ?? 0, existingCount ?? 0]
            guard counts.allSatisfy({ $0 >= 0 && $0 <= items.count }),
                  counts.reduce(0, +) == items.count - identified.count
            else { throw AppError.invalidResponse }
            results.append(contentsOf: items.indices.map { identified[$0] ?? .success(()) })
        }
        return results
    }

    static func matches(_ lhs: [WatchlistExternalID], _ rhs: [WatchlistExternalID]) -> Bool {
        let shared = lhs.filter { value in rhs.contains { $0.namespace == value.namespace } }
        return !shared.isEmpty && shared.allSatisfy { rhs.contains($0) }
    }

    func validate(allowDuplicateWatch: Bool, removing: Bool = false) throws {
        if notFound?.values.contains(where: { !$0.isEmpty }) == true { throw AppError.notFound }
        let failures = errored?.values.flatMap { $0 } ?? []
        let duplicates: Set<String> = [
            "Already added!",
            "Already added! A play within the hour counts as the same watch",
            "Already added! A play on the same day counts as the same watch",
        ]
        guard failures.allSatisfy({
            guard let error = $0.error?.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
            return (allowDuplicateWatch && duplicates.contains(error)) || (removing && error == "Nothing to remove")
        }) else { throw WetrakrError.itemRejected }
        let changed = removing ? removed?.hasChanges == true : added?.hasChanges == true || existing?.hasChanges == true
        guard changed || !failures.isEmpty
        else { throw AppError.invalidResponse }
    }
}

extension WetrakrClient {
    func tracking(
        _ body: WetrakrTrackingBody, remove: Bool = false,
        idempotencyKey: String, accessToken: String
    ) async throws {
        let response = try await trackingResult(
            body, remove: remove, idempotencyKey: idempotencyKey, accessToken: accessToken
        )
        try response.validate(allowDuplicateWatch: body.allowRewatch == true, removing: remove)
    }

    func trackingResult(
        _ body: WetrakrTrackingBody, remove: Bool = false,
        idempotencyKey: String, accessToken: String
    ) async throws -> WetrakrTrackingResult {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let endpoint = try Endpoint(
            method: .post, path: remove ? "/sync/tracking/remove" : "/sync/tracking",
            headers: ["Idempotency-Key": idempotencyKey]
        ).jsonBody(body, encoder: encoder)
        return try await decode(
            WetrakrTrackingResult.self, endpoint: endpoint, accessToken: accessToken,
            operation: body.allowRewatch == true ? .historyWrite : .planningWrite
        )
    }
}
