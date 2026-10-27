import Foundation

/// A completed server write, not the optimistic/local Watchlist notification.
public struct WatchlistProviderChange: Sendable, Equatable {
    public static let notification = Notification.Name("plozz.watchlistProviderDidChange")

    public let profileNamespace: String?
    public let accountID: String
    public let serverUserID: String

    public init(profileNamespace: String?, accountID: String, serverUserID: String) {
        self.profileNamespace = profileNamespace
        self.accountID = accountID
        self.serverUserID = serverUserID
    }

    @MainActor public func post() {
        NotificationCenter.default.post(name: Self.notification, object: self)
    }
}
