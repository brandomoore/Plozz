#if canImport(SwiftUI)
import CoreModels
import SwiftUI

struct PublicMetaDBPlaybackFailure: View {
    let failure: TrackerPlaybackDeliveryError
    var body: some View {
        switch failure {
        case .connectionChanged:
            Text("Playback wasn't sent because the account changed.")
        case .unsupportedIdentity:
            Text("Plozz couldn't match the title or episode.")
        case .accessDenied:
            Text("PublicMetaDB denied access. This playback report won't be retried.")
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
