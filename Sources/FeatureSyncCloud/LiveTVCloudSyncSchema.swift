import Foundation

public extension CloudSyncSchemaDescriptor {
    static let liveTVSourcesV1 = CloudSyncSchemaDescriptor(
        recordType: "PlozzTrackerTokensV1Record", encryptsValue: true,
        zoneName: "PlozzLiveTVSourcesV1Zone", maximumPayloadBytes: 256 * 1_024 * 1_024
    )

    /// Reuses the deployed non-secret media-state record type/fields, in an
    /// isolated zone. Old media-state clients omit unknown prefixes from their
    /// authoritative captures, so sharing their zone would let them delete Live
    /// TV records. This remains a channel on the ONE existing CKSyncEngine.
    static let liveTVStateV1 = CloudSyncSchemaDescriptor(
        recordType: "PlozzMediaStateV1Record",
        zoneName: "PlozzLiveTVStateV1Zone",
        kindDerivation: .prefixBeforeFirstColon
    )
}
