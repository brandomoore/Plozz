import CoreModels
import Foundation

public struct ManagedHTTPPreparationReference:
    Codable,
    Sendable,
    Hashable
{
    public let queueIdentifier: String
    public let itemIdentifier: String

    public init(queueIdentifier: String, itemIdentifier: String) {
        self.queueIdentifier = queueIdentifier
        self.itemIdentifier = itemIdentifier
    }
}

/// Secret-free reopen information for a managed-provider background download.
///
/// Credentials and resolved URLs are deliberately excluded. The iOS app resolves
/// a fresh authenticated URL from the active account each time work starts or
/// resumes.
public struct ManagedHTTPDownloadSource: Codable, Sendable, Hashable {
    public let provider: ProviderKind
    public let accountID: String
    public let itemID: String
    public let mediaSourceID: String?
    public let quality: DownloadQuality
    /// Saved request flags are preserved on retry; Original keeps its file intact.
    public let includesAllAudioTracks: Bool
    public let includesTextSubtitleTracks: Bool
    public let preferredAudioLanguages: [String]
    public let preparationReference: ManagedHTTPPreparationReference?
    public let audioPreparationReferences: [Int: ManagedHTTPPreparationReference]

    public var requiresUncappedRenditionTransfer: Bool {
        quality != .original
            && (provider == .jellyfin || (provider == .emby && !includesAllAudioTracks))
    }

    public init(
        provider: ProviderKind,
        accountID: String,
        itemID: String,
        mediaSourceID: String? = nil,
        quality: DownloadQuality = .original,
        includesAllAudioTracks: Bool = false,
        includesTextSubtitleTracks: Bool = true,
        preferredAudioLanguages: [String] = [],
        preparationReference: ManagedHTTPPreparationReference? = nil,
        audioPreparationReferences: [Int: ManagedHTTPPreparationReference] = [:]
    ) {
        self.provider = provider
        self.accountID = accountID
        self.itemID = itemID
        self.mediaSourceID = mediaSourceID
        self.quality = quality
        self.includesAllAudioTracks = includesAllAudioTracks
        self.includesTextSubtitleTracks = includesTextSubtitleTracks
        self.preferredAudioLanguages = preferredAudioLanguages
        self.preparationReference = preparationReference
        self.audioPreparationReferences = audioPreparationReferences
    }

    private enum CodingKeys: String, CodingKey {
        case provider
        case accountID
        case itemID
        case mediaSourceID
        case quality
        case includesAllAudioTracks
        case includesTextSubtitleTracks
        case preferredAudioLanguages
        case preparationReference
        case audioPreparationReferences
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        provider = try container.decode(ProviderKind.self, forKey: .provider)
        accountID = try container.decode(String.self, forKey: .accountID)
        itemID = try container.decode(String.self, forKey: .itemID)
        mediaSourceID = try container.decodeIfPresent(String.self, forKey: .mediaSourceID)
        quality = try container.decodeIfPresent(DownloadQuality.self, forKey: .quality)
            ?? .original
        includesAllAudioTracks = try container.decodeIfPresent(
            Bool.self,
            forKey: .includesAllAudioTracks
        ) ?? false
        includesTextSubtitleTracks = try container.decodeIfPresent(
            Bool.self,
            forKey: .includesTextSubtitleTracks
        ) ?? true
        preferredAudioLanguages = try container.decodeIfPresent(
            [String].self,
            forKey: .preferredAudioLanguages
        ) ?? []
        preparationReference = try container.decodeIfPresent(
            ManagedHTTPPreparationReference.self,
            forKey: .preparationReference
        )
        audioPreparationReferences = try container.decodeIfPresent(
            [Int: ManagedHTTPPreparationReference].self,
            forKey: .audioPreparationReferences
        ) ?? [:]
    }

    public func replacingPreparationReference(
        _ reference: ManagedHTTPPreparationReference?, audioTrackID: Int? = nil
    ) -> Self {
        var audioReferences = audioPreparationReferences
        if let audioTrackID { audioReferences[audioTrackID] = reference }
        return Self(
            provider: provider, accountID: accountID, itemID: itemID,
            mediaSourceID: mediaSourceID, quality: quality,
            includesAllAudioTracks: includesAllAudioTracks,
            includesTextSubtitleTracks: includesTextSubtitleTracks,
            preferredAudioLanguages: preferredAudioLanguages,
            preparationReference: audioTrackID == nil ? reference : preparationReference,
            audioPreparationReferences: audioReferences
        )
    }
}
