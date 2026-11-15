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
    @Environment(\.themePalette) private var palette
    @State private var changingAccount = false
    @State private var statusRetryID = UUID()
    @State private var reviewing: SeerAccountConnection?

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
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(spacing: 12) {
                        Text(verbatim: "Seerr").font(.largeTitle.bold())
                            .accessibilityAddTraits(.isHeader)
                        Text("Request movies and shows missing from your library.")
                            .multilineTextAlignment(.center)
                            .plozzForeground(.secondary)
                        ProfileChip(profile: profile)
                    }
                    .frame(maxWidth: .infinity)

                    if profile.id != seer.activeProfileID {
                        Text("Switch to this profile to sign in to Seerr.")
                        continueButton
                    } else if let connection = seer.profileConnections.selected, !changingAccount {
                        SettingsSectionGroup("Request as") {
                            Text(connection.accountName).font(.headline)
                            Text(connection.baseURL.absoluteString)
                                .font(.footnote).plozzForeground(.secondary)
                            if connection.requiresRelink {
                                Text("Choose the request account again.").foregroundStyle(.red)
                                Button("Review account") { reviewing = connection }.settingsActionRow()
                            }
                        }
                        if case let .failed(message) = seer.phase {
                            Text(message).foregroundStyle(.red)
                            Button("Try again") { statusRetryID = UUID() }
                                .plozzPageActionButton(role: .secondary)
                        }
                        continueButton
                        Button("Change account") { changingAccount = true }
                            .plozzPageActionButton(role: .secondary)
                    } else {
                        if let failure = seer.storageFailure { Text(failure).foregroundStyle(.red) }
                        SeerSignInForm(
                            seer: seer,
                            replacing: changingAccount ? seer.profileConnections.selected?.id : nil,
                            onConnected: onContinue
                        )
                        Button {
                            if changingAccount { changingAccount = false }
                            else { onContinue() }
                        } label: {
                            Text(changingAccount ? "Cancel" : "Not now")
                                .frame(maxWidth: .infinity).plozzPageActionLabel()
                        }
                        .plozzPageActionButton(role: .secondary)
                    }
                }
                #if os(tvOS)
                .frame(maxWidth: 840)
                .padding(.horizontal, 48)
                #else
                .frame(maxWidth: 720)
                .padding(.horizontal, 24)
                #endif
                .padding(.vertical, 32)
                .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
            .scrollClipDisabled()
        }
        .background { AppBackground(palette: palette) }
        .sheet(item: $reviewing) { connection in
            SeerConnectionDetail(seer: seer, connectionID: connection.id)
        }
        .onChange(of: seer.activeProfileID) { reviewing = nil; changingAccount = false }
        .task(id: [seer.connectionRevision, statusRetryID]) {
            seer.synchronizeProfile()
            guard profile.id == seer.activeProfileID, seer.isConfigured else { return }
            await seer.refreshStatus()
        }
    }

    private var continueButton: some View {
        Button(action: onContinue) {
            Text("Continue").frame(maxWidth: .infinity).plozzPageActionLabel()
        }
        .plozzPageActionButton()
    }
}
#endif
