#if os(iOS)
import CoreModels
import FeatureHomeCore
import SwiftUI

struct PlozziOSAllLibrariesDestinationView: View {
    @Environment(\.locale) private var locale
    let appModel: PlozziOSAppModel

    private var title: String { // l10n:content - locale-scoped resource for the shared grid's String API
        var resource = AllLibrariesBrowse.title
        resource.locale = locale
        return String(localized: resource) // l10n:content - recomputed from the observed locale, never cached
    }

    var body: some View {
        Group {
            if let provider = resolveAllLibrariesBrowse(
                libraries: appModel.visibleNavigationLibraries,
                in: appModel.accountsProviders.homeAccounts,
                identitySources: appModel.identityIndex.identitySourcesProvider,
                identityRevision: appModel.identityIndex.identityRevisionProvider
            ) {
                PlozziOSLibraryGridView(
                    viewModel: LibraryBrowseViewModel(
                        provider: provider,
                        containerID: AllLibrariesBrowse.containerID,
                        containerKind: .unknown,
                        sortKeySuffix: AllLibrariesBrowse.sortKeySuffix,
                        sourceAccountID: nil,
                        settingsNamespace: appModel.profiles.activeNamespace,
                        presentation: appModel.settings.libraryPresentation
                    ),
                    title: title,
                    provider: provider,
                    settings: appModel.settings,
                    scanStatus: appModel.shareScanStatus,
                    isCombinedLibrary: true
                )
            } else {
                ContentUnavailableView {
                    Label {
                        Text(AllLibrariesBrowse.emptyTitle)
                    } icon: {
                        Image(systemName: "square.stack.3d.up.slash")
                    }
                } description: {
                    Text(AllLibrariesBrowse.emptyMessage)
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
#endif
