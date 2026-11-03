import Foundation
import CoreModels

extension SiloProvider {
    public func serverHomeLayout() async throws -> ServerHomeLayout? {
        let sections: [SiloHomeSection]
        do {
            let layout: SiloHomeResponse = try await client.request("/home/layout")
            sections = layout.sections
        } catch AppError.notFound {
            do {
                let layout: SiloHomeResponse = try await client.request("/home/sections")
                sections = layout.sections
            } catch AppError.notFound {
                return nil
            }
        }
        try Self.validateHomeSections(sections)
        return ServerHomeLayout(sections: sections.map(\.definition), source: .server)
    }

    public func serverHomeItems(
        section: ServerHomeSection, limit: Int, excludingLibraryIDs: Set<String>
    ) async throws -> [MediaItem] {
        guard limit > 0 else { return [] }
        let row: SiloHomeSection
        do {
            row = try await client.request("/home/sections/\(try SiloAPI.pathComponent(section.id))/items")
        } catch AppError.notFound {
            let response: SiloHomeResponse = try await client.request("/home/sections")
            try Self.validateHomeSections(response.sections)
            guard let found = response.sections.first(where: { $0.id == section.id }) else {
                throw AppError.notFound
            }
            row = found
        }
        guard row.id == section.id else { throw AppError.invalidResponse }
        return try await homeItems(row, limit: limit, excludingLibraryIDs: excludingLibraryIDs)
    }

    public func serverHomeItems(
        sections: [ServerHomeSection], limit: Int, excludingLibraryIDs: Set<String>
    ) async -> [String: Result<[MediaItem], AppError>] {
        var results: [String: Result<[MediaItem], AppError>] = [:]
        guard !sections.isEmpty else { return results }
        do {
            try Task.checkCancellation()
            guard limit > 0 else {
                for section in sections { results[section.id] = .success([]) }
                return results
            }
            // Share one fresh response across this refresh, never across logins or watch mutations.
            let response: SiloHomeResponse = try await client.request("/home/sections")
            try Self.validateHomeSections(response.sections)
            let rows = Dictionary(uniqueKeysWithValues: response.sections.map { ($0.id, $0) })
            for section in sections where results[section.id] == nil {
                do {
                    try Task.checkCancellation()
                    guard let row = rows[section.id] else { throw AppError.notFound }
                    results[section.id] = .success(try await homeItems(
                        row, limit: limit, excludingLibraryIDs: excludingLibraryIDs
                    ))
                } catch {
                    results[section.id] = .failure(Self.homeError(error))
                }
            }
        } catch {
            for section in sections { results[section.id] = .failure(Self.homeError(error)) }
        }
        return results
    }

    private func homeItems(
        _ row: SiloHomeSection, limit: Int, excludingLibraryIDs: Set<String>
    ) async throws -> [MediaItem] {
        guard let cards = row.items else { throw AppError.invalidResponse }
        let allowed: [String]?
        if excludingLibraryIDs.isEmpty { allowed = nil }
        else { allowed = try await libraries().filter { !excludingLibraryIDs.contains($0.id) }.map(\.id) }
        if allowed?.isEmpty == true { return [] }
        var items: [MediaItem] = []
        var seen = Set<String>()
        var requested = Set<String>()
        for card in cards {
            try Task.checkCancellation()
            guard ["movie", "series", "season", "episode", "video"].contains(card.type ?? "") else { continue }
            var candidate = map(card)
            if row.definition.kind == .continueWatching || row.definition.kind == .nextUp,
               let target = card.play_content_id, target != card.content_id {
                guard requested.insert(target).inserted,
                      let existing = try await existingHomeItem(id: target) else { continue }
                candidate = existing
                candidate = inheritingSeriesArtwork(candidate, from: map(card))
                Self.applyResume(position: card.position_seconds, duration: card.duration_seconds, to: &candidate)
                candidate.lastPlayedAt = card.progress_updated_at.flatMap(Self.date) ?? candidate.lastPlayedAt
            }
            if let allowed {
                guard let membership = try await homeLibraryID(for: candidate, in: allowed) else { continue }
                candidate.libraryID = membership
            }
            guard seen.insert(candidate.id).inserted else { continue }
            items.append(candidate)
            if items.count == limit { break }
        }
        return items
    }

    func homeLibraryID(for item: MediaItem, in libraryIDs: [String]) async throws -> String? {
        for libraryID in libraryIDs {
            let matches = try await catalogItems([
                URLQueryItem(name: "library_id", value: libraryID),
                URLQueryItem(name: "q", value: item.title),
                URLQueryItem(name: "type", value: item.kind.rawValue)
            ], limit: Int.max, libraryID: libraryID)
            if matches.contains(where: { $0.id == item.id }) { return libraryID }
        }
        return nil
    }

    private static func validateHomeSections(_ sections: [SiloHomeSection]) throws {
        var seen = Set<String>()
        for section in sections {
            _ = try SiloAPI.pathComponent(section.id)
            guard seen.insert(section.id).inserted else { throw AppError.invalidResponse }
        }
    }

    private static func homeError(_ error: Error) -> AppError {
        (error as? AppError) ?? (error is CancellationError ? .cancelled : .invalidResponse)
    }
}

private struct SiloHomeResponse: Decodable, Sendable {
    let sections: [SiloHomeSection]
}

private struct SiloHomeSection: Decodable, Sendable {
    let id: String
    let section_type: String
    let title: String?
    let items: [SiloItem]?

    var definition: ServerHomeSection {
        let kind: ServerHomeSection.Kind
        switch section_type {
        case "continue_watching": kind = .continueWatching
        case "next_up": kind = .nextUp
        case "recently_added": kind = .recentlyAdded
        default: kind = .recommendations
        }
        return ServerHomeSection(id: id, kind: kind, title: title)
    }
}
