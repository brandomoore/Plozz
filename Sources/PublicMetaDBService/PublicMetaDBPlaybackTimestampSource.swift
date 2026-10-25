import CoreModels
import Foundation

@MainActor
final class PublicMetaDBPlaybackTimestampSource: CommunityPlaybackTimestampProviding {
    let name = "PublicMetaDB"
    private weak var service: PublicMetaDBService?
    private let connectionID: UUID
    private let epoch: PublicMetaDBConnectionEpoch

    init(service: PublicMetaDBService, connectionID: UUID, epoch: PublicMetaDBConnectionEpoch) {
        self.service = service
        self.connectionID = connectionID
        self.epoch = epoch
    }

    var isCurrent: Bool {
        epoch.isCurrent && service?.connectionID == connectionID && service?.phase == .connected
    }

    func timestamps(for item: MediaItem, includeHighlights: Bool) async throws -> [CommunityPlaybackTimestamp] {
        guard isCurrent, let service else { throw PublicMetaDB.Failure.connectionChanged }
        guard let content = PublicMetaDB.Content.matching(item), content.isPlayable else {
            throw PublicMetaDB.Failure.invalidInput
        }
        let skips = try await service.skipsForManagement(content, expectedConnectionID: connectionID)
        guard isCurrent, !Task.isCancelled else { throw PublicMetaDB.Failure.connectionChanged }
        var result: [CommunityPlaybackTimestamp] = []
        for record in skips {
            let release: CommunityPlaybackTimestamp.Release
            switch record.value.source {
            case .streaming: release = .streaming
            case .physical: release = .physical
            case nil: release = .unknown
            }
            let segments: [(CommunityPlaybackTimestamp.Kind, PublicMetaDB.Segment?)] = [
                (.intro, record.value.intro), (.credits, record.value.credits),
                (.recap, record.value.recap), (.preview, record.value.preview)
            ]
            for (kind, segment) in segments {
                guard let segment else { continue }
                result.append(.init(
                    id: "skip:\(record.id):\(kind.rawValue)", kind: kind,
                    start: segment.startMilliseconds / 1_000, end: segment.endMilliseconds / 1_000,
                    release: release, contributor: record.contributor
                ))
            }
        }
        if includeHighlights {
            let highlights = try await service.highlightsForManagement(content, expectedConnectionID: connectionID)
            guard isCurrent, !Task.isCancelled else { throw PublicMetaDB.Failure.connectionChanged }
            result += highlights.map { record in
                .init(
                    id: "highlight:\(record.id)", kind: .highlight,
                    start: record.value.segment.startMilliseconds / 1_000,
                    end: record.value.segment.endMilliseconds / 1_000,
                    release: .unknown, contributor: record.contributor, description: record.value.description
                )
            }
        }
        return result
    }
}
