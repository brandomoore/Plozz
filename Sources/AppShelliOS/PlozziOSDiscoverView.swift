#if os(iOS)
import AppRuntime
import CoreModels
import CoreUI
import FeatureHomeCore
import SwiftUI

struct PlozziOSDiscoverView: View {
    let appModel: PlozziOSAppModel
    let onShowSettings: () -> Void
    @Environment(\.locale) private var locale
    @Environment(\.plozziOSIsOverflowDestination) private var isOverflowDestination
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.plozziOSUsesVerticalToolbar) private var usesVerticalToolbar

    var body: some View {
        if appModel.isActiveProfileAuthorized, !appModel.profiles.activeProfile.isKids {
            let scope = appModel.navigationLibrariesScopeKey
            let visibility = appModel.settings.homeVisibility.visibility
            DiscoverBrowseView(model: DiscoverRuntime.makeModel(
                namespace: appModel.profiles.activeNamespace,
                accounts: appModel.accountsProviders.homeAccounts,
                identitySources: appModel.identityIndex.identitySourcesProvider,
                visibility: visibility,
                seer: appModel.seerService,
                language: locale.identifier,
                pendingWatchMutations: { await appModel.pendingWatchMutations() },
                isCurrent: {
                    appModel.isActiveProfileAuthorized && !appModel.profiles.activeProfile.isKids
                        && appModel.navigationLibrariesScopeKey == scope
                        && appModel.settings.homeVisibility.visibility == visibility
                }
            ), pageActions: {
                PlozziOSSettingsAvatarButton(action: onShowSettings)
                    .accessibilityIdentifier("discover-settings-avatar")
            }) { feed, items, loading, loadMore in
                PlozziOSHomeMediaRail(
                    title: Text(feed.title), items: items, style: .poster, appModel: appModel,
                    loadingPlaceholderCount: loading ? 6 : 0,
                    onLoadMore: loadMore
                )
            }
            .id("\(scope)|\(appModel.seerService.connectionRevision)|\(locale.identifier)|\(visibility.disabledKeys.sorted())")
            .toolbarTitleDisplayMode(.inline)
            .toolbar(sizeClass == .compact && !isOverflowDestination && !usesVerticalToolbar ? .hidden : .visible,
                     for: .navigationBar)
        }
    }
}
#endif
