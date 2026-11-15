#if os(iOS)
import FeatureSettings
import SwiftUI

struct PlozziOSSeerrSettingsView: View {
    let appModel: PlozziOSAppModel

    var body: some View {
        SeerConnectionsView(seer: appModel.seerService)
    }
}
#endif
