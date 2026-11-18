import CoreModels
import Foundation

/// A painted selection belongs to a subject and policy, not to its changing candidate list.
struct ArtworkDisplayIdentity: Hashable {
    let subject: String?
    let policy: String
    let variant: ArtworkImageVariant
    let maxAspectRatio: CGFloat?
    let prefersPrimaryReference: Bool
    let prefersLandscape: Bool
    private let unpinnedReferences: [ArtworkReference]
    private let networkAccess: Set<NetworkAccess>

    private struct NetworkAccess: Hashable {
        let account: String
        let credentialRevision: CredentialRevision
    }

    init(
        subject: String?, policy: String, references: [ArtworkReference],
        variant: ArtworkImageVariant, maxAspectRatio: CGFloat? = nil,
        prefersPrimaryReference: Bool = false, prefersLandscape: Bool = false
    ) {
        self.subject = subject
        self.policy = policy
        self.variant = variant
        self.maxAspectRatio = maxAspectRatio
        self.prefersPrimaryReference = prefersPrimaryReference
        self.prefersLandscape = prefersLandscape
        unpinnedReferences = subject == nil ? references : []
        networkAccess = Set(references.compactMap {
            guard case .networkFile(let reference) = $0 else { return nil }
            return NetworkAccess(account: reference.accountID, credentialRevision: reference.credentialRevision)
        })
    }
}
