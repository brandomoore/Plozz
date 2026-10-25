#if canImport(SwiftUI)
import CoreModels
import CoreUI
import PublicMetaDBService
import SwiftUI

struct PublicMetaDBPlaybackSettingsView: View {
    let service: PublicMetaDBService
    @State private var confirming = false
    @State private var approvedConnection: UUID?
    @State private var failure: (any Error)?

    var body: some View {
        PublicMetaDBPage {
            SettingsPageHeader("Playback reporting")
            Text("Send future playback from this profile on this device to PublicMetaDB. Connecting a key alone does not enable reporting.")
                .foregroundStyle(.secondary)
            Text("Plozz reports supported movies and individual episodes with a TMDB identity and confirmed episode order. Manual watched changes, external players, and library channels are not reported.")
                .foregroundStyle(.secondary)
            if let consent = service.playbackConsent {
                Text("Playback reporting enabled")
                if let failure = consent.lastFailure { PublicMetaDBPlaybackFailure(failure: failure) }
                Button("Stop reporting playback") { service.disablePlayback() }
                    .accessibilityIdentifier("publicmetadb.playback.disable")
                Text("Existing remote records are left unchanged. Enabling again will not replay old queued sessions.")
                    .foregroundStyle(.secondary)
            } else {
                Button("Enable playback reporting") {
                    approvedConnection = service.connectionID
                    confirming = true
                }
                .disabled(service.phase != .connected)
                .accessibilityIdentifier("publicmetadb.playback.enable")
            }
            if let failure { PublicMetaDBFailureMessage(error: failure) }
        }
        .confirmationDialog("Report playback to PublicMetaDB?", isPresented: $confirming) {
            Button("Enable reporting") {
                do {
                    guard let approvedConnection else { throw PublicMetaDB.Failure.connectionChanged }
                    try service.enablePlayback(expectedConnectionID: approvedConnection)
                    failure = nil
                } catch { failure = error }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This sends playback progress and adds a watch at 90% completion, including genuine rewatches. PublicMetaDB clears resume points at 80%. It does not import history into Plex or Jellyfin. If another app or server plugin also reports watches, duplicate records are still possible; disable duplicate reporting there first.")
        }
        .onChange(of: service.connectionID) { _, _ in
            confirming = false
            approvedConnection = nil
            failure = nil
        }
    }

}

private struct PublicMetaDBPlaybackFailure: View {
    let failure: TrackerPlaybackDeliveryError
    var body: some View {
        switch failure {
        case .connectionChanged:
            Text("A queued session belongs to an earlier connection and was not sent.")
        case .unsupportedIdentity:
            Text("A session could not be reported because its content identity or episode order was not confirmed.")
        case .remoteConflict:
            Text("A session was stopped from reporting because newer progress or a possible existing watch was found on PublicMetaDB.")
        case .unconfirmed:
            Text("A session's delivery could not be confirmed. Plozz will not retry that session automatically. Check PublicMetaDB before changing its records.")
        case .retryAfter:
            Text("A session could not be sent. It remains queued for a later attempt.")
        }
    }
}
#endif
