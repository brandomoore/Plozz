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
                isCurrent: {
                    appModel.isActiveProfileAuthorized && !appModel.profiles.activeProfile.isKids
                        && appModel.navigationLibrariesScopeKey == scope
                        && appModel.settings.homeVisibility.visibility == visibility
                }
            )) { feed, items, loading, loadMore in
                PlozziOSHomeMediaRail(
                    title: Text(feed.title), items: items, style: .poster, appModel: appModel,
                    loadingPlaceholderCount: loading ? 6 : 0,
                    onLoadMore: loadMore
                )
            }
            .id("\(scope)|\(appModel.seerService.connectionRevision)|\(locale.identifier)|\(visibility.disabledKeys.sorted())")
            .toolbarTitleDisplayMode(isOverflowDestination ? .inline : .large)
            .toolbar { PlozziOSSettingsToolbarItem(action: onShowSettings) }
        }
    }
}
#endif
