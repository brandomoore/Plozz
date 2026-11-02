#if os(iOS)
import AppRuntime
import CoreModels
import FeatureHomeCore
import MediaTransportCore
import ProviderShare

extension PlozziOSAppModel {
    var detailPlaybackPreparation: DetailPlaybackPreparationEnvironment {
        DetailPlaybackPreparationEnvironment(
            allowsMultipleVersions: settings.playback.settings.versionSelectionMode == .automatic,
            scope: { [weak self] accountID in
                guard let self, self.isActiveProfileAuthorized,
                      let account = self.accountsProviders.resolvedActiveAccounts.first(where: {
                          $0.account.id == accountID
                      })?.account
                else { return nil }
                return DetailPlaybackPreparationScope(
                    webDAVAccount: account,
                    profileID: self.profiles.activeProfileID,
                    authorizationID: self.accountsProviders.liveTVAuthorizationID,
                    credentialRevision: self.accountsProviders.credentialRevision(account),
                    isAuthorized: self.isActiveProfileAuthorized
                )
            },
            exactFileRelativePath: { ShareProvider.exactFileRelativePath(for: $0) },
            provider: { [weak self] accountID in
                guard let self, self.isActiveProfileAuthorized else { return nil }
                return self.accountsProviders.resolvedActiveAccounts.first {
                    $0.account.id == accountID
                }?.provider
            },
            reserve: { [weak self] locator, position in
                guard let self, self.isActiveProfileAuthorized else { throw CancellationError() }
                let handle = try self.mediaShareRuntime.networkFileResolver.beginPreparation(locator, startPosition: position)
                return DetailPlaybackPreparationReservation(
                    cancel: { handle.cancel() },
                    requestPlaybackHandoff: { handle.requestPlaybackHandoff() }
                )
            }
        )
    }
}
#endif
