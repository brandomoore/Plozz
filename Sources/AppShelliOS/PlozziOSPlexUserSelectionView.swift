#if os(iOS)
import AppRuntime
import CoreModels
import CoreUI
import SwiftUI

struct PlozziOSPlexUserSelectionView: View {
    let appModel: PlozziOSAppModel
    let selection: PlexHomeUsersModel.PendingPlexUserSelection
    let onImportAll: () -> PlexHomeProfileImportResult
    let onSelect: (PlexHomeUser, Bool) -> Void
    @State private var hasPresentedAuthorization = false

    var body: some View {
        ZStack {
            NavigationStack {
                PlexHomeOnboardingView(users: selection.users, onImportAll: onImportAll, onSelect: onSelect)
                    .id(selection.id)
                    .settingsPageSurface()
            }
            .opacity(presentsProfileAuthorization ? 0 : 1)
            .allowsHitTesting(!presentsProfileAuthorization)
            .accessibilityHidden(presentsProfileAuthorization)
            if presentsProfileAuthorization {
                PlozziOSProfileAccessGateView(appModel: appModel) {
                    hasPresentedAuthorization = false
                }
            }
        }
        .interactiveDismissDisabled()
        .onChange(of: presentsProfileAuthorization) { _, presented in
            if presented { hasPresentedAuthorization = true }
        }
    }

    private var presentsProfileAuthorization: Bool {
        hasPresentedAuthorization || appModel.parentalSwitch != nil || appModel.lockedSwitch != nil
    }
}
#endif
