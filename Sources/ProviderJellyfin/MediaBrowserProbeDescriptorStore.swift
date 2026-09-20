import Foundation
import CoreModels

actor MediaBrowserProbeDescriptorStore {
    private static let maxEntries = 256
    struct Descriptor: Sendable {
        let itemID: String
        let sourceID: String
        let container: String
        let etag: String?
        let revision: String
    }

    private var descriptors: [String: Descriptor] = [:]
    private var completedRevisions: [String: SupplementalStreamProbeRequirements] = [:]
    private var factsByRevision: [String: ProbedStreamFacts] = [:]
    private var lruItemIDs: [String] = []

    func remember(itemID: String, sources: [MediaSourceInfo]?) {
        guard let source = sources?.first,
              let container = source.Container,
              !container.isEmpty else {
            if let previous = descriptors.removeValue(forKey: itemID) {
                completedRevisions[previous.revision] = nil
                factsByRevision[previous.revision] = nil
            }
            lruItemIDs.removeAll { $0 == itemID }
            return
        }
        let sourceID = source.Id ?? itemID
        let revision = Self.revision(
            itemID: itemID,
            sourceID: sourceID,
            etag: source.ETag,
            size: source.Size
        )
        if let previous = descriptors[itemID], previous.revision != revision {
            completedRevisions[previous.revision] = nil
            factsByRevision[previous.revision] = nil
        }
        descriptors[itemID] = Descriptor(
            itemID: itemID,
            sourceID: sourceID,
            container: container,
            etag: source.ETag,
            revision: revision
        )
        touch(itemID)
        evictIfNeeded()
    }

    func descriptor(for itemID: String) -> Descriptor? {
        if descriptors[itemID] != nil { touch(itemID) }
        return descriptors[itemID]
    }

    func cachedResult(
        for revision: String, requirements: SupplementalStreamProbeRequirements = []
    ) -> (completed: Bool, facts: ProbedStreamFacts?) {
        (completedRevisions[revision].map { $0.isSuperset(of: requirements) } ?? false, factsByRevision[revision])
    }

    func store(
        _ facts: ProbedStreamFacts?, for revision: String, requirements: SupplementalStreamProbeRequirements
    ) {
        guard descriptors.values.contains(where: { $0.revision == revision }) else { return }
        completedRevisions[revision, default: []].formUnion(requirements)
        var confirmed = factsByRevision[revision] ?? ProbedStreamFacts()
        if requirements.contains(.atmos), facts?.audioIsAtmos == true { confirmed.audioIsAtmos = true }
        if requirements.contains(.hdr10Plus), facts?.videoRangeType == "HDR10Plus" {
            confirmed.videoRangeType = "HDR10Plus"
        }
        factsByRevision[revision] = confirmed.audioIsAtmos || confirmed.videoRangeType != nil ? confirmed : nil
    }

    private func touch(_ itemID: String) {
        lruItemIDs.removeAll { $0 == itemID }
        lruItemIDs.append(itemID)
    }

    private func evictIfNeeded() {
        while lruItemIDs.count > Self.maxEntries {
            let itemID = lruItemIDs.removeFirst()
            guard let descriptor = descriptors.removeValue(forKey: itemID) else {
                continue
            }
            completedRevisions[descriptor.revision] = nil
            factsByRevision[descriptor.revision] = nil
        }
    }

    nonisolated static func revision(
        itemID: String,
        sourceID: String,
        etag: String?,
        size: Int64?
    ) -> String {
        "\(itemID)|\(sourceID)|\(etag ?? "-")|\(size.map(String.init) ?? "-")"
    }
}
