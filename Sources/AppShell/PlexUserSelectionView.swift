#if canImport(SwiftUI)
import SwiftUI
import AppRuntime
import CoreModels
import CoreUI

/// Shared Plex Home import/identity page. The selected user authenticates in the
/// next library step; other imported users are never authenticated here.
struct PlexUserSelectionView: View {
    let selection: PlexHomeUsersModel.PendingPlexUserSelection
    let onImportAll: () -> PlexHomeProfileImportResult
    let onSelect: (PlexHomeUser, Bool) -> Void

    var body: some View {
        PlexHomeOnboardingView(users: selection.users, onImportAll: onImportAll, onSelect: onSelect)
            .id(selection.id)
    }
}
#endif
