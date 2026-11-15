#if canImport(SwiftUI)
import CoreModels
import CoreUI
import FeatureProfiles
import SeerService
import SwiftUI

public struct ProfileSeerrSetupView: View {
    private let seer: SeerService
    private let profile: Profile
    private let onContinue: () -> Void

    public init(
        seer: SeerService, profile: Profile,
        onSelect: @escaping (SeerUser?) -> Void,
        onContinue: @escaping () -> Void
    ) {
        self.seer = seer
        self.profile = profile
        self.onContinue = onContinue
    }

    public var body: some View {
        SeerSettingsPage {
            VStack(alignment: .leading, spacing: 24) {
                ViewThatFits(in: .horizontal) {
                    HStack {
                        Text(verbatim: "Seerr").font(.title.bold())
                        ProfileChip(profile: profile)
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    VStack(alignment: .leading, spacing: 12) {
                        Text(verbatim: "Seerr").font(.title.bold())
                        ProfileChip(profile: profile)
                    }
                }
                if profile.id == seer.activeProfileID {
                    SeerConnectionsContent(seer: seer)
                } else {
                    Text("Switch to this profile to sign in to Seerr.")
                }
                Button(action: onContinue) {
                    if seer.isConfigured {
                        Text("Continue").plozzPageActionLabel()
                    } else {
                        Text("Not now").plozzPageActionLabel()
                    }
                }
                .plozzPageActionButton(role: seer.isConfigured ? .primary : .secondary)
            }
        }
        .onAppear { seer.synchronizeProfile() }
    }
}
#endif
