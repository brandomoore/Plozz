#if os(iOS)
import CoreModels
import CoreUI
import FeatureMusic
import FeatureHomeCore
import Observation
import SwiftUI

@MainActor
@Observable
final class PlozziOSMusicRuntime {
    let player = MusicPlayerSession()
    private(set) var availability = MusicAvailabilityModel(store: EphemeralMusicAvailabilityStore())
    private(set) var authorizationID: String?
    private(set) var settings = MusicPlayerSettingsModel()

    func configure(appModel: PlozziOSAppModel) {
        let nextID = Self.authorizationID(appModel: appModel)
        guard nextID != authorizationID else { return }
        player.stop()
        authorizationID = nextID
        availability = MusicAvailabilityModel(
            store: MusicAvailabilityStore(namespace: appModel.profiles.activeNamespace)
        )
        settings = MusicPlayerSettingsModel(store: MusicPlayerSettingsStore(namespace: appModel.profiles.activeNamespace))
        guard let nextID else { return }
        player.configure(accounts: appModel.accountsProviders.homeAccounts, authorizationID: nextID) { [weak appModel] in
            guard let appModel else { return false }
            return Self.authorizationID(appModel: appModel) == nextID
        }
        availability.seedFromCache(
            accounts: appModel.accountsProviders.homeAccounts,
            visibility: appModel.settings.homeVisibility.visibility
        )
    }

    func probe(appModel: PlozziOSAppModel) async {
        guard authorizationID != nil else { return }
        await availability.probe(
            accounts: appModel.accountsProviders.homeAccounts,
            visibility: appModel.settings.homeVisibility.visibility
        )
    }

    static func authorizationID(appModel: PlozziOSAppModel) -> String? {
        guard appModel.isActiveProfileAuthorized, !appModel.isOfflineMode else { return nil }
        return appModel.accountsProviders.liveTVAuthorizationID + "|"
            + appModel.settings.homeVisibility.visibility.disabledKeys.sorted().joined(separator: "|")
    }
}

struct PlozziOSMusicDestination: View {
    let appModel: PlozziOSAppModel
    let music: PlozziOSMusicRuntime
    let onShowSettings: () -> Void
    @Environment(\.plozziOSIsOverflowDestination) private var isOverflow
    @Environment(\.plozziOSOverflowNavigation) private var overflowNavigation

    var body: some View {
        MusicTabView(
            accounts: music.availability.detectedAccounts,
            visibleLibraryIDs: music.availability.visibleLibraryIDs,
            controller: music.player.controller,
            authenticatedHTTPResolver: appModel.authenticatedHTTPResolver,
            musicPlayer: music.settings,
            showNowPlaying: Binding(
                get: { music.player.isPresented },
                set: { music.player.isPresented = $0 }
            ),
            navigation: music.player.navigation,
            namespace: appModel.profiles.activeNamespace,
            onNavigateBack: isOverflow ? { overflowNavigation?.returnToMore() } : nil
        ) {
            PlozziOSSettingsToolbarItem(action: onShowSettings)
        }
        .id(music.authorizationID)
        .navigationTitle("Music")
    }
}

struct PlozziOSMusicLifecycle: View {
    let appModel: PlozziOSAppModel
    @Environment(HeroTrailerController.self) private var trailers
    @Environment(\.plozzArtworkPolicy) private var artworkPolicy
    @Environment(\.scenePhase) private var scenePhase
    @State private var playbackOwner = UUID()
    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: PlozziOSMusicRuntime.authorizationID(appModel: appModel), initial: true) { _, _ in
                appModel.music?.configure(appModel: appModel)
            }
            .task(id: scenePhase == .active ? PlozziOSMusicRuntime.authorizationID(appModel: appModel) : nil) {
                guard scenePhase == .active else { return }
                appModel.music?.configure(appModel: appModel)
                await appModel.music?.probe(appModel: appModel)
            }
            .onChange(of: appModel.music?.player.controller.hasActivePlayback, initial: true) { _, active in
                if active == true {
                    trailers.suspendForPlayback(owner: playbackOwner)
                } else {
                    trailers.resumeAfterPlayback(owner: playbackOwner)
                }
            }
            .onChange(of: artworkPolicy, initial: true) { _, policy in
                appModel.music?.player.controller.updateArtworkPolicy(policy.forArea(.music))
            }
            .onDisappear { trailers.resumeAfterPlayback(owner: playbackOwner) }
    }
}
#endif
