import CoreModels
import FeatureLiveTVCore
import Foundation

extension AccountsProvidersModel {
    /// Settings model for per-provider Xtream backup server addresses; saving rebuilds that account's provider.
    public func makeLiveTVAlternateAddressesModel() -> LiveTVAlternateAddressesModel {
        LiveTVAlternateAddressesModel(
            load: { [weak self] in self?.alternateAddresses(accountID: $0) },
            save: { [weak self] accountID, urls in
                guard let self else { return }
                try self.saveAlternateAddresses(accountID: accountID, urls: urls)
            }
        )
    }

    func alternateAddresses(accountID: String) -> [URL]? {
        guard let account = accounts.first(where: { $0.id == accountID }), account.server.provider == .iptv,
              let token = accountStore.token(for: accountID),
              let credential = try? IPTVCredential.decode(token),
              credential.mode == .xtream else { return nil }
        return credential.alternateAddresses
    }

    func saveAlternateAddresses(accountID: String, urls: [URL]) throws {
        guard let account = accounts.first(where: { $0.id == accountID }) else { throw AppError.notFound }
        try accountStore.replaceIPTVAlternateAddresses(expected: account, addresses: urls)
        registry.invalidate(accountID: accountID)
        reloadAccounts()
    }
}
