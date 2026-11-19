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
        GroupedSettingsPage(title: "Playback reporting", backIdentifier: "publicmetadb.playback.back") {
            SettingsSectionGroup {
                Toggle("Report playback", isOn: Binding(
                    get: { service.playbackConsent != nil },
                    set: { enabled in
                        if enabled {
                            approvedConnection = service.connectionID
                            confirming = true
                        } else {
                            service.disablePlayback()
                        }
                    }
                ))
                .disabled(service.playbackConsent == nil && service.phase != .connected)
                .accessibilityIdentifier(service.playbackConsent == nil ? "publicmetadb.playback.enable" : "publicmetadb.playback.disable")
            } footer: {
                Text("Send movies and episodes you play in this profile on this device to PublicMetaDB.")
            }
            if let issue = service.playbackConsent?.lastFailure {
                SettingsSectionGroup("Last playback") { PublicMetaDBPlaybackFailure(failure: issue) }
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
            Text("PublicMetaDB clears progress at 80% and records a play at 90%, including rewatches. Turn off other reporting tools to avoid duplicates.")
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
            Text("Playback wasn't sent because the account changed.")
        case .unsupportedIdentity:
            Text("Plozz couldn't match the title or episode.")
        case .remoteConflict:
            Text("Not sent: PublicMetaDB has newer progress or a possible matching play.")
        case .unconfirmed:
            Text("Check your PublicMetaDB history. Delivery wasn't confirmed and won't be retried.")
        case .retryAfter:
            Text("Playback couldn't be sent. Plozz will try again.")
        }
    }
}
#endif
