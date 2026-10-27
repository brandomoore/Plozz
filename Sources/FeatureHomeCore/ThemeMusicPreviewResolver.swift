import CoreModels
import CoreNetworking
import Foundation

public enum ThemeMusicPreviewResolver {
    /// Sample only titles already admitted to this profile's Home content.
    @MainActor
    public static func resolve(
        content: HomeViewModel.Content?, accounts: [ResolvedAccount]
    ) async throws -> ThemeMusic? {
        guard let content else { return nil }
        let items = content.continueWatching + content.latest
            + content.serverRows.flatMap(\.items)
            + content.librarySections.flatMap(\.sections).flatMap(\.items)
        var visited = Set<String>()
        var attempts = 0
        var lookupError: Error?
        for item in items {
            try Task.checkCancellation()
            guard let account = accounts.first(where: { $0.account.id == item.sourceAccountID }),
                  item.kind == .movie || item.kind == .series || item.kind == .episode else { continue }
            let itemID = item.kind == .episode ? item.seriesID ?? item.id : item.id
            guard visited.insert("\(account.account.id):\(itemID)").inserted else { continue }
            attempts += 1
            do {
                if let theme = try await account.provider.themeMusic(for: itemID) {
                    try Task.checkCancellation()
                    return theme
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch AppError.cancelled {
                throw CancellationError()
            } catch {
                lookupError = error
                PlozzLog.app.error("Theme music: preview lookup failed provider=\(account.provider.kind.rawValue) type=\(String(describing: type(of: error)))")
            }
            if attempts >= 8 { break }
        }
        if let lookupError { throw lookupError }
        return nil
    }
}
