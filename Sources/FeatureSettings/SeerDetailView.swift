#if canImport(SwiftUI)
import CoreModels
import SeerService
import SwiftUI

struct SeerDetailView: View {
    let seer: SeerService
    var knownServerHosts: [String] = []
    var profiles: [Profile] = []
    var onSetSeerrUser: (String, SeerUser?) -> Void = { _, _ in }

    var body: some View {
        SeerConnectionsView(seer: seer)
    }
}
#endif
