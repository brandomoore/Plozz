import Foundation

public enum MediaCrewRole: Int, CaseIterable, Sendable {
    case director, creator, writer, producer, executiveProducer, composer, music

    public init?(kind: String?) {
        switch kind?.lowercased().filter(\.isLetter) {
        case "director": self = .director
        case "creator": self = .creator
        case "writer", "screenplay", "story", "teleplay": self = .writer
        case "producer": self = .producer
        case "executiveproducer": self = .executiveProducer
        case "composer", "originalmusiccomposer": self = .composer
        case "music": self = .music
        default: return nil
        }
    }

    public var title: String {
        switch self {
        case .director: String(localized: "Director")
        case .creator: String(localized: "Creator")
        case .writer: String(localized: "Writer")
        case .producer: String(localized: "Producer")
        case .executiveProducer: String(localized: "Executive Producer")
        case .composer: String(localized: "Composer")
        case .music: String(localized: "Music")
        }
    }
}

/// A detail-rail presentation, not a replacement for the source's person route.
public struct MediaPersonCredit: Identifiable, Equatable, Sendable {
    public let id: String
    public private(set) var person: MediaPerson
    public private(set) var characters: [String]
    public private(set) var crewRoles: [MediaCrewRole]
    public private(set) var isCast: Bool

    public var caption: String? {
        let lines = [characters.joined(separator: ", "), crewRoles.map(\.title).joined(separator: ", ")]
            .filter { !$0.isEmpty }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    public static func ordered(_ people: [MediaPerson]) -> [Self] {
        let people = people.filter { $0.isCast || MediaCrewRole(kind: $0.kind) != nil }
        var parents = Array(people.indices)
        var identities: [String: Int] = [:]
        func root(_ index: Int) -> Int {
            var current = index
            while parents[current] != current {
                parents[current] = parents[parents[current]]
                current = parents[current]
            }
            return current
        }
        // Resolve all aliases first: a later credit can join two earlier groups.
        for (index, person) in people.enumerated() {
            var aliases = ["id:\(person.id)"]
            if let identity = person.creditIdentity, !identity.isEmpty { aliases.append("id:\(identity)") }
            if let external = person.externalID?.trimmingCharacters(in: .whitespacesAndNewlines),
               !external.isEmpty { aliases.append("external:\(external)") }
            for alias in aliases {
                if let previous = identities[alias] {
                    let left = root(index), right = root(previous)
                    parents[max(left, right)] = min(left, right)
                } else {
                    identities[alias] = index
                }
            }
        }
        var credits: [Self] = []
        var positions: [Int: Int] = [:]
        for (sourceIndex, person) in people.enumerated() {
            let identity = root(sourceIndex)
            let role = MediaCrewRole(kind: person.kind)
            let character = person.isCast
                ? person.role?.trimmingCharacters(in: .whitespacesAndNewlines) : nil
            if let index = positions[identity] {
                credits[index].isCast = credits[index].isCast || person.isCast
                if credits[index].person.imageURL == nil { credits[index].person.imageURL = person.imageURL }
                if let character, !character.isEmpty, !credits[index].characters.contains(character) {
                    credits[index].characters.append(character)
                }
                if let role, !credits[index].crewRoles.contains(role) {
                    credits[index].crewRoles.append(role)
                    credits[index].crewRoles.sort { $0.rawValue < $1.rawValue }
                }
            } else {
                positions[identity] = credits.count
                credits.append(Self(
                    id: person.id, person: person,
                    characters: character.flatMap { $0.isEmpty ? nil : [$0] } ?? [],
                    crewRoles: role.map { [$0] } ?? [], isCast: person.isCast
                ))
            }
        }
        let cast = credits.filter(\.isCast)
        let leading = Array(cast.prefix(8))
        var shown = Set(leading.map(\.id))
        let crew = credits.enumerated()
            .filter { !$0.element.crewRoles.isEmpty && !shown.contains($0.element.id) }
            .sorted {
                let left = $0.element.crewRoles[0].rawValue
                let right = $1.element.crewRoles[0].rawValue
                return left == right ? $0.offset < $1.offset : left < right
            }
            .map(\.element)
        var featuredCrew: [Self] = []
        var representedRoles = Set(leading.flatMap(\.crewRoles))
        let roleGroups: [[MediaCrewRole]] = [
            [.director, .creator], [.writer], [.producer, .executiveProducer], [.composer, .music]
        ]
        for roles in roleGroups where representedRoles.isDisjoint(with: roles) {
            guard let person = crew.first(where: {
                !shown.contains($0.id) && $0.crewRoles.contains(where: roles.contains)
            }) else { continue }
            featuredCrew.append(person)
            shown.insert(person.id)
            representedRoles.formUnion(person.crewRoles)
        }
        let remainingCast = cast.filter { !shown.contains($0.id) }
        shown.formUnion(remainingCast.map(\.id))
        return leading + featuredCrew + remainingCast + crew.filter { !shown.contains($0.id) }
    }
}

extension MediaItem {
    public var detailCredits: [MediaPersonCredit] { MediaPersonCredit.ordered(people) }
}
