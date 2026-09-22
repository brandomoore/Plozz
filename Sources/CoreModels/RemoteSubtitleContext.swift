import Foundation

/// The file and session currently playing, not an item's default edition.
public struct RemoteSubtitleContext: Hashable, Sendable {
    public let itemID: String
    public let mediaSourceID: String?
    public let playSessionID: String?

    public init(itemID: String, mediaSourceID: String? = nil, playSessionID: String? = nil) {
        self.itemID = itemID
        self.mediaSourceID = mediaSourceID
        self.playSessionID = playSessionID
    }

    public init(request: PlaybackRequest) {
        if case .authenticatedHTTP(let locator) = request.playbackSource {
            self.init(itemID: locator.itemID, mediaSourceID: locator.mediaSourceID,
                      playSessionID: locator.playSessionID ?? request.playSessionID)
        } else {
            self.init(itemID: request.item.id, mediaSourceID: request.item.selectedVersionID,
                      playSessionID: request.playSessionID)
        }
    }
}

public enum RemoteSubtitleError: Error, Sendable {
    case unavailable
    case incompleteSearch
    case expiredSearch
    case unsupportedPlayback
    case uncertainDownload

    public var userMessage: LocalizedStringResource {
        switch self {
        case .unavailable:
            "Subtitle downloads aren't available for this account. Check your server's subtitle providers and permissions."
        case .incompleteSearch:
            "Your server couldn't complete the subtitle search. Check its subtitle providers and try again."
        case .expiredSearch:
            "These subtitle results are no longer available. Search again before downloading."
        case .unsupportedPlayback:
            "Subtitles can't be added to this playback session. Reopen the title and try again."
        case .uncertainDownload:
            "The subtitle download couldn't be confirmed. Check the subtitle list before searching again."
        }
    }
}
