#if os(iOS)
import AppRuntime
import CoreModels
import CoreUI
import CrashReporting
import FeatureHomeCore
import FeatureProfiles
import FeatureSettings
import FeatureSyncSetup
import Foundation
import SwiftUI
import UIKit

@MainActor
private enum PlozziOSProcessComposition {
    static let appModel = PlozziOSAppModel()
}

public struct PlozziOSRootView: View {
    @Environment(\.colorScheme) private var systemColorScheme
    /// The reader's text size. Feeds `PlozzMetrics` so the shared type/geometry
    /// table rebuilds when it changes (see where the metrics are injected below).
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceTransparency)
    private var systemReduceTransparency
    @State private var appModel = PlozziOSProcessComposition.appModel
    @State private var homeViewModelBox = LazyViewState<HomeViewModel>()
    @State private var heroTrailerController = HeroTrailerController()
    @State private var themeMusicController = ThemeMusicController()
    @State private var isLiveTVSelected = false
    @State private var sidebarGeometry = PlozziOSSidebarGeometryModel()
    @State private var showingAddServer = false
    @State private var providerSetupRouter = ManagedProviderSetupRouter()
    @State private var iptvSetup: ManagedProviderSetupRouter.Request?
    @State private var showingSettings = false
    /// Owned here rather than in the tab shell so `receivePairingURL` can see
    /// whether it is up before asking for another sheet.
    @State private var showingProfileSwitcher = false
    @State private var isSelectingLaunchProfile = false
    /// A pairing link that arrived while a sheet was open — see
    /// `receivePairingURL`.
    @State private var deferredPairingURL: URL?
    @State private var downloadNotifications = PlozziOSDownloadNotificationNavigation.shared
    @State private var notificationDismissals: Set<NotificationPresentation> = []
    /// A synced server the user tapped "Set Up" on, used to pre-fill the Add Server
    /// sheet so they only have to sign in.
    @State private var serverSetupSeed: SyncedAccountDescriptor?
    /// Action chosen in the new-server prompt, run after the prompt sheet dismisses so
    /// we never stack two sheets in the same runloop.
    @State private var serverPromptFollowUp: ServerPromptFollowUp?
    /// Drives the "set up from another device" pairing flow launched from the prompt,
    /// carrying which server the user wants signed in (nil = not pairing).
    @State private var pairingServer: SyncedAccountDescriptor?
    /// Cold-launch offers exclude servers explicitly deferred to Settings.
    @State private var showDetectedCover = false
    @State private var detectedSetupServers: [SyncedAccountDescriptor] = []
    /// Set true once we've decided about the detected cover for this launch (shown it,
    /// or the short cold-launch window elapsed), so it never re-pops mid-session.
    @State private var coldLaunchDetectionHandled = false
    /// Defer launching the receive/pairing flow until the detected cover has fully
    /// dismissed, so two full-screen covers never race in the same runloop.
    @State private var detectedFollowUpReceive = false
    /// Drives the unrestricted receive/pairing flow launched from the detected-setup
    /// page (brings the whole household over from the detected device).
    @State private var showReceiveFromDetected = false
    @State private var settingsShellIdentity: (profileID: String, value: String)?
    private var releaseNotes: ReleaseNotesModel { .shared }

    public init() {}

    public var body: some View {
        Group {
            if needsDiagnosticConsent {
                CrashReportingConsentView { enabled in
                    appModel.crashReporting.isEnabled = enabled
                    appModel.applyCrashReportingPreference()
                }
                .environment(\.themePalette, resolvedPalette)
                .environment(\.colorScheme, resolvedPalette.isLight ? .light : .dark)
            } else {
                appContent
                    .task { consumeDeferredPairingURL() }
            }
        }
        .onOpenURL { url in
            if ExternalPlaybackRuntime.shared.receive(url) { return }
            receivePairingURL(url)
        }
        .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
            if let url = activity.webpageURL {
                receivePairingURL(url)
            }
        }
    }

    private var themeMusicAuthorization: ThemeMusicPlaybackAuthorization {
        let scope = appModel.accountsProviders.liveTVAuthorizationID
        return ThemeMusicPlaybackAuthorization(
            id: appModel.isActiveProfileAuthorized ? scope : nil,
            provider: { accountID in
                guard appModel.isActiveProfileAuthorized,
                      appModel.accountsProviders.liveTVAuthorizationID == scope else { return nil }
                return appModel.accountsProviders.homeAccounts.first { $0.account.id == accountID }?.provider
            }
        )
    }

    private var needsDiagnosticConsent: Bool {
        appModel.crashReportingController.isConfigured && appModel.crashReporting.needsConsent
    }

    private var appContent: some View {
        Group {
            if !appModel.canEnterApp {
                PlozziOSOnboardingView(appModel: appModel)
            } else if showsLaunchProfilePicker {
                PlozziOSProfileSelectionView(
                    appModel: appModel,
                    onSelectionStarted: { isSelectingLaunchProfile = true },
                    onComplete: { isSelectingLaunchProfile = false }
                )
            } else if usesInlineStandaloneFirstRun, appModel.pendingFirstRunStep != nil {
                PlozziOSFirstRunView(
                    step: appModel.pendingFirstRunStep,
                    appModel: appModel,
                    systemColorScheme: systemColorScheme
                )
            } else {
                PlozziOSTabShell(
                    appModel: appModel,
                    homeViewModelBox: homeViewModelBox,
                    onLiveTVActivityChanged: { isLiveTVSelected = $0 },
                    onAddServer: showAddServer,
                    showingSettings: $showingSettings,
                    showingProfileSwitcher: $showingProfileSwitcher,
                    deferredPairingURL: $deferredPairingURL,
                    onNotificationPresentationDismissed: { notificationDismissals.remove($0) },
                    systemColorScheme: systemColorScheme
                )
            }
        }
        .scrollContentBackground(.hidden)
        .environment(\.managedProviderSetupRouter, providerSetupRouter)
        .plozzSheet(item: $providerSetupRouter.reauthenticationAccount) { account in
            PlozziOSAccountReauthenticationView(appModel: appModel, account: account)
                .presentationSizing(.page)
        }
        .onChange(of: appModel.profiles.activeProfileID) { _, _ in
            providerSetupRouter.reauthenticationAccount = nil
        }
        .onChange(of: providerSetupRouter.request?.id) { _, _ in
            guard let request = providerSetupRouter.request else { return }
            iptvSetup = request
            providerSetupRouter.request = nil
            showAddServer()
        }
        // One opaque cover for profile PIN then Plex PIN. Separate presentations
        // briefly exposed the tab shell between them.
        .plozzFullScreenCover(isPresented: profileAccessGateBinding) {
            PlozziOSProfileAccessGateView(
                appModel: appModel, onCancel: downloadNotifications.cancelPending
            )
        }
        // Setup that was abandoned part-way — quit mid-flow, or arrived over sync
        // from a device where it was never finished. The gate is persisted, so a
        // profile left behind it never imports a watchlist at all; resuming asks
        // the question that was never answered.
        //
        // Only the launch-origin case presents here. Creating a profile happens
        // inside the Settings sheet and is presented from there instead — a cover
        // asked for from this view while Settings is up would never appear. See
        // `ProfileOnboardingOrigin`.
        .plozzFullScreenCover(isPresented: Binding(
            get: { appModel.isPresentingProfileOnboarding(from: .launch) },
            set: { if !$0 { appModel.cancelProfileOnboarding() } }
        )) {
            PlozziOSProfileOnboardingCover(appModel: appModel)
        }
        .task { appModel.resumeProfileOnboardingIfNeeded() }
        .liveChannelSystemOverlays()
        .onAppear { PlozziOSScreenshotSeed.applyIfRequested(to: appModel) }
        .background(PlozziOSCrashScreenObserver(controller: appModel.crashReportingController))
        .task {
            // Detect on cold launch: fire immediately if the pending set is already
            // warm, and close the cold-launch window after a short grace period so a
            // later (mid-session) detection uses the drawer instead of this cover.
            considerColdLaunchDetection()
            try? await Task.sleep(for: .seconds(8))
            coldLaunchDetectionHandled = true
        }
        .onChange(of: appModel.pendingServersNeedingSetup.map(\.id)) { _, _ in
            considerColdLaunchDetection()
        }
        .plozzFullScreenCover(isPresented: $showDetectedCover, onDismiss: {
            if detectedFollowUpReceive {
                detectedFollowUpReceive = false
                showReceiveFromDetected = true
            }
        }) {
            PlozziOSDetectedSetupView(
                appModel: appModel,
                servers: detectedSetupServers,
                onSetUpFromDevice: {
                    detectedFollowUpReceive = true
                    showDetectedCover = false
                },
                onSetUpLater: {
                    appModel.deferDetectedSetup(detectedSetupServers.map(\.id))
                    showDetectedCover = false
                }
            )
        }
        .background {
            PlozziOSScenePhaseEffects(appModel: appModel)
        }
        .modifier(PlozziOSSyncSetupOfferPresenter(
            appModel: appModel,
            canPresent: setupPresentationReady && !releaseNotes.hasPendingStartupNotes
                && appModel.isActiveProfileAuthorized && !appModel.managementRequiresParentalPIN
        ))
        .plozzSheet(item: serverPromptBinding, onDismiss: consumeServerPromptFollowUp) { descriptor in
            SyncedServerSetupPrompt(
                descriptor: descriptor,
                palette: resolvedPalette,
                onSignIn: {
                    serverPromptFollowUp = .signIn(descriptor)
                    appModel.clearPendingSyncedServerPrompt()
                },
                onUseOtherDevice: {
                    serverPromptFollowUp = .pairDevice(descriptor)
                    appModel.clearPendingSyncedServerPrompt()
                },
                onNotNow: {
                    serverPromptFollowUp = nil
                    appModel.clearPendingSyncedServerPrompt()
                }
            )
        }
        .plozzFullScreenCover(item: $pairingServer) { descriptor in
            PlozziOSSyncSetupReceiveView(appModel: appModel, requestedServer: descriptor) {
                pairingServer = nil
            }
        }
        .plozzFullScreenCover(isPresented: $showReceiveFromDetected) {
            PlozziOSSyncSetupReceiveView(appModel: appModel) {
                showReceiveFromDetected = false
            }
        }
        .background { AppBackground(palette: resolvedPalette) }
        .id(presentationShellIdentity)
        .onChange(of: appModel.isSettingsPresented) { _, presented in
            if presented {
                themeMusicController.stop()
                heroTrailerController.stop()
            }
            settingsShellIdentity = presented
                ? (appModel.profiles.activeProfileID, shellIdentity) : nil
        }
        .onChange(of: shellIdentity) {
            heroTrailerController.stop()
            themeMusicController.stop()
        }
        // A successful Plex selection changes shellIdentity, not the sheet collecting it.
        // Libraries owns the same question while Settings is presented.
        .plozzSheet(item: Binding(
            get: { appModel.isSettingsPresented ? nil : appModel.pendingIdentityAccount },
            set: { if $0 == nil { appModel.resolveIdentityPromptForPending() } }
        )) { account in
            PlozziOSServerIdentityPromptView(
                appModel: appModel,
                account: account,
                onFinish: { appModel.concludeIdentityPrompt(for: account.id) },
                onDecline: { appModel.declineIdentityPrompt(for: account.id) }
            )
        }
        // Outside the profile-scoped identity, inside its shared environment:
        // changing accounts must not tear down the surface collecting their PIN.
        .plozzFullScreenCover(isPresented: $showingProfileSwitcher, onDismiss: {
            consumeDeferredPairingURL()
            notificationDismissals.remove(.profileSwitcher)
        }) {
            PlozziOSProfileSelectionView(
                appModel: appModel,
                onComplete: { showingProfileSwitcher = false },
                onCancel: { showingProfileSwitcher = false }
            )
        }
        .environment(\.familyGuidanceProvider, appModel.familyGuidance)
        .environment(\.plozzShowsContentRatings, appModel.settings.contentRatings.showsRatings)
        .environment(
            \.versionPickerAudioLanguage,
            appModel.settings.playback.settings.audioLanguagePreference.explicitLanguageCode
        )
        // See the tvOS root: reading `dynamicTypeSize` is what rebuilds the metrics
        // when the reader's text size changes, rather than only on relaunch.
        .environment(
            \.plozzMetrics,
            PlozzMetrics.touch(
                density: appModel.settings.density.density,
                dynamicTypeSize: dynamicTypeSize
            )
        )
        .mediaItemActionHandler(appModel.mediaItemActionHandler)
        .environment(\.plozzCardCaptionSettings, appModel.settings.cardStyle.captions)
        .environment(\.plozzContinueWatchingPlaybackDetails, appModel.settings.homeVisibility.continueWatchingPlaybackDetails)
        .environment(\.plozzArtworkSettings, appModel.settings.cardStyle.artwork)
        .environment(\.plozzArtworkProviders, appModel.metadataProviderSettingsModel.settings)
        .environment(
            \.plozzCardStyle,
            appModel.settings.cardStyle.style
        )
        .environment(
            \.plozzWatchStatusIndicator,
            appModel.settings.watchIndicator.indicator
        )
        .environment(\.plozzShowsUnwatchedEpisodeCount, appModel.settings.watchIndicator.showsUnwatchedEpisodeCount)
        .environment(\.plozzShowsProgressBars, appModel.settings.watchIndicator.showsProgressBars)
        .environment(\.plozzEpisodeCountBadgeStyle, appModel.settings.watchIndicator.episodeCountStyle)
        .environment(\.plozzWatchIndicatorColor, appModel.settings.watchIndicator.color)
        // See the note in RootView: drives whether an unowned title's corner mark
        // reads as information or as an invitation to request it.
        .environment(\.plozzSeerConnected, appModel.seerService.isConfigured)
        .environment(
            \.plozzReduceTransparency,
            appModel.settings.transparency.preference.reducesTransparency(
                systemReduceTransparency: systemReduceTransparency
            )
        )
        .environment(
            \.colorScheme,
            resolvedPalette.isLight ? .light : .dark
        )
        .transientStatusOverlay(
            presenter: appModel.transientStatusPresenter,
            bottomPadding: 72,
            palette: resolvedPalette
        )
        .environment(appModel)
        .environment(heroTrailerController)
        .themeMusicScope(
            controller: themeMusicController,
            model: appModel.settings.themeMusic,
            background: appModel.settings.heroBackground.settings,
            isBlocked: heroTrailerController.isPlaying || heroTrailerController.isPlaybackSuppressed
                || isLiveTVSelected,
            detailAllowed: !appModel.isSettingsPresented && !showingProfileSwitcher
                && appModel.isActiveProfileAuthorized,
            authorization: themeMusicAuthorization,
            authenticatedHTTPResolver: appModel.authenticatedHTTPResolver
        )
        .environment(sidebarGeometry)
        .syncsWindowInterfaceStyle(appModel.settings.theme.theme.preferredColorScheme)
        .modifier(PlozziOSDownloadNotificationRouting(
            navigation: downloadNotifications,
            context: downloadNotificationContext,
            preparePresentation: prepareDownloadNotificationPresentation,
            selectProfile: appModel.selectProfile,
            resolve: {
                appModel.downloads.initializationError == nil
                    ? .resolve($0, records: appModel.downloads.records) : .library
            }
        ))
        .plozzSheet(
            isPresented: $showingAddServer,
            onDismiss: {
                serverSetupSeed = nil
                iptvSetup = nil
                appModel.finishManagedServerPresentation()
                consumeDeferredPairingURL()
                notificationDismissals.remove(.addServer)
            }
        ) {
            AddServerView(
                appModel: appModel,
                initialProvider: iptvSetup == nil ? serverSetupSeed?.provider ?? .jellyfin : .iptv,
                initialAddress: serverSetupSeed?.candidateBaseURLs.first?.absoluteString ?? "",
                initialIPTVPlaylist: iptvSetup?.playlist, initialIPTVAccount: iptvSetup?.account,
                initialIPTVMode: iptvSetup?.mode ?? .playlist
            )
                .presentationSizing(.page)
        }
        .plozzSheet(
            item: plexUserSelectionBinding
        ) { selection in
            PlozziOSPlexUserSelectionView(
                appModel: appModel,
                selection: selection,
                onImportAll: appModel.importPlexHomeProfilesDuringOnboarding,
                onSelect: appModel.selectPlexUserDuringOnboarding
            )
        }
        .plozzSheet(
            item: librarySelectionBinding
        ) { selection in
            PlozziOSLibrarySelectionView(
                appModel: appModel, accountIDs: selection.accountIDs
            )
        }
        // Presented ONCE for the whole first-run flow, not per step. Keyed by
        // `item:` the cover tore down and rebuilt on every step change — because
        // FirstRunStep is its own Identifiable id — so the flow dismissed to
        // Home and re-presented between screens. Steps now cross-fade inside it.
        .plozzFullScreenCover(isPresented: firstRunPresentedBinding) {
            PlozziOSFirstRunView(
                step: appModel.pendingFirstRunStep,
                appModel: appModel,
                systemColorScheme: systemColorScheme
            )
        }
        .task(id: releaseNotesStartupReady) {
            if releaseNotesStartupReady {
                releaseNotes.prepareForStartup()
            }
        }
        .plozzSheet(
            isPresented: Binding(
                get: { releaseNotes.hasPendingStartupNotes },
                set: { presented in
                    if !presented {
                        releaseNotes.dismissStartupNotes()
                    }
                }
            ),
            onDismiss: { releaseNotes.dismissStartupNotes() }
        ) {
            ReleaseNotesStartupView(model: releaseNotes)
                .presentationSizing(.page)
        }
        .installNightShiftOverlay(appModel.settings.nightShift)
        .externalPlayerSupport(
            context: { appModel.externalPlaybackContext() },
            legacySettings: { appModel.settings.playback.settings.externalPlayer },
            onProgress: { try await appModel.finishExternalPlayback($0) }
        )
        .plozzSheet(item: pendingPairingBinding) { pairing in
            Group {
                if let invite = SyncSetupSourceInvite.decode(pairing.invite) {
                    PlozziOSSyncSetupReceiveView(
                        appModel: appModel, sourceInvite: invite,
                        onClose: { appModel.pendingPairingInvite = nil }
                    )
                } else {
                    PlozziOSSyncSetupSendFlow(
                        appModel: appModel,
                        request: .link(pairing.invite),
                        onClose: { appModel.pendingPairingInvite = nil }
                    )
                }
            }
        }
        .environment(\.themePalette, resolvedPalette)
        .environment(\.gradientBackgroundsEnabled, appModel.settings.theme.gradientEnabled)
    }

    private struct PlozziOSCrashScreenObserver: View {
        let controller: CrashReportingController

        var body: some View {
            Color.clear
                .frame(width: 0, height: 0)
                .onReceive(NotificationCenter.default.publisher(for: MainThreadStallProbe.contextDidChange)) { _ in
                    controller.setScreen(CrashReportScreen(context: MainThreadStallProbe.context))
                }
        }
    }

    private var resolvedPalette: ThemePalette {
        ThemePalette.palette(
            for: appModel.settings.theme.theme,
            systemColorScheme: systemColorScheme
        )
    }

    private var releaseNotesStartupReady: Bool {
        setupPresentationReady && appModel.pendingSyncSetupOffer == nil
    }

    private var setupPresentationReady: Bool {
        appModel.canEnterApp
            && !appModel.pendingStandaloneLiveTVEntry
            && !appModel.mustChooseProfile
            && (!appModel.requiresLaunchProfileSelection
                || appModel.didCompleteLaunchProfileSelection)
            && appModel.pendingFirstRunStep == nil
            && !showDetectedCover
            && coldLaunchDetectionHandled
            && !showingSettings
            && !showingProfileSwitcher
            && !showingAddServer
            && pairingServer == nil
            && !showReceiveFromDetected
            && appModel.lockedSwitch == nil
            && appModel.parentalSwitch == nil
            && appModel.plexHomeUsers.pendingPlexPINRequest == nil
            && appModel.pendingIdentityAccount == nil
            && appModel.pendingLibrarySelection == nil
            && appModel.pendingSyncedServerPrompt == nil
            && appModel.pendingPairingInvite == nil
    }

    private var showsLaunchProfilePicker: Bool {
        isSelectingLaunchProfile || appModel.mustChooseProfile
            || (!appModel.didCompleteLaunchProfileSelection
                && (appModel.requiresLaunchProfileSelection
                    || appModel.plexHomeUsers.pendingPlexPINRequest != nil))
    }

    private var shellIdentity: String {
        if showsLaunchProfilePicker {
            return "profile-picker"
        }
        let profile = appModel.profiles.activeProfile
        return "\(profile.id)#"
            + profile.plexPlaybackIdentityKey(
                for: appModel.accountsProviders.homeAccounts.map(\.account)
            )
    }

    private var presentationShellIdentity: String {
        // Settings owns its navigation and nested identity chooser. Rebuild the
        // covered content after dismissal, but never retain a different profile.
        if appModel.isSettingsPresented, let settingsShellIdentity,
           settingsShellIdentity.profileID == appModel.profiles.activeProfileID {
            return settingsShellIdentity.value
        }
        return shellIdentity
    }

    private var plexUserSelectionBinding:
        Binding<PlexHomeUsersModel.PendingPlexUserSelection?>
    {
        Binding(
            get: {
                // Suppressed during first run: the flow cover renders this step
                // inline, so presenting it here too would stack a sheet on the
                // cover (and reintroduce the dismiss-to-Home hand-off).
                showingSettings || appModel.pendingFirstRunStep != nil
                    ? nil
                    : appModel.plexHomeUsers.pendingPlexUserSelection
            },
            set: { selection in
                if selection == nil {
                    appModel.cancelPlexUserSelectionDuringOnboarding()
                }
            }
        )
    }

    private var profileAccessGateBinding: Binding<Bool> {
        Binding(
            get: {
                guard !showsLaunchProfilePicker, !showingProfileSwitcher,
                      appModel.plexHomeUsers.pendingPlexUserSelection == nil else { return false }
                if appModel.lockedSwitch != nil { return true }
                if appModel.parentalSwitch != nil { return true }
                guard !showingSettings,
                      appModel.profileOnboardingStep != .libraries
                else { return false }
                return appModel.plexPINRequestForAppPresentation != nil
            },
            set: { presented in
                if !presented {
                    appModel.cancelProfileLockPrompt()
                    appModel.cancelParentalSwitch()
                    appModel.plexHomeUsers.dismissPlexPINIfPresented()
                }
            }
        )
    }

    private var librarySelectionBinding:
        Binding<PlozziOSAppModel.PendingLibrarySelection?>
    {
        Binding(
            get: {
                // Same as the Plex-user step: inline during first run, its own
                // sheet when adding a server later.
                showingSettings || appModel.pendingFirstRunStep != nil
                    ? nil
                    : appModel.pendingLibrarySelection
            },
            set: { selection in
                if selection == nil {
                    appModel.completeLibrarySelection()
                }
            }
        )
    }

    /// True while ANY first-run step is pending. The specific step is read inside
    /// the cover so changing it animates in place instead of re-presenting.
    private var firstRunPresentedBinding: Binding<Bool> {
        Binding(
            get: {
                appModel.pendingFirstRunStep != nil
                    && !usesInlineStandaloneFirstRun
            },
            set: { _ in }
        )
    }

    /// Keep standalone setup in the root, behind its ordinary profile picker
    /// and access-gate cover, instead of mounting tabs beneath a new cover.
    private var usesInlineStandaloneFirstRun: Bool {
        appModel.allowsStandalonePlayback && !appModel.admissionContext.hasMediaAccounts
    }

    /// Takes a pairing link, waiting for an open sheet to close first.
    ///
    /// A link can arrive while the app is already foreground with Settings or the
    /// profile picker up. The pairing sheet lives on the root, and one requested
    /// from under an open sheet is the arrangement SwiftUI drops — silently, and
    /// with `pendingPairingInvite` left set so it is never re-requested, which
    /// means the link simply does nothing until relaunch.
    private func receivePairingURL(_ url: URL) {
        guard !needsDiagnosticConsent else {
            deferredPairingURL = url
            return
        }
        guard showingSettings || showingProfileSwitcher || showingAddServer else {
            appModel.handleIncomingURL(url)
            return
        }
        deferredPairingURL = url
        showingSettings = false
        showingProfileSwitcher = false
        showingAddServer = false
    }

    /// Raises a link parked by `receivePairingURL` now that the sheet that was
    /// covering the root has actually gone.
    private func consumeDeferredPairingURL() {
        guard let url = deferredPairingURL else { return }
        deferredPairingURL = nil
        appModel.handleIncomingURL(url)
    }

    enum NotificationPresentation: Hashable {
        case settings, profileSwitcher, addServer
    }

    private func prepareDownloadNotificationPresentation() {
        guard downloadNotifications.pending != nil else { return }
        if showingSettings || appModel.isSettingsPresented {
            notificationDismissals.insert(.settings)
            showingSettings = false
        }
        if showingProfileSwitcher {
            notificationDismissals.insert(.profileSwitcher)
            showingProfileSwitcher = false
        }
        if showingAddServer {
            notificationDismissals.insert(.addServer)
            showingAddServer = false
        }
    }

    private var downloadNotificationContext: PlozziOSDownloadNotificationNavigation.Context {
        let request = downloadNotifications.pending
        let targetProfileID = request?.target.profileID
        let downloads = appModel.downloads
        return .init(
            requestID: request?.id,
            targetExists: appModel.profiles.profiles.contains { $0.id == targetProfileID },
            activeProfileID: appModel.profiles.activeProfileID,
            canEnterApp: appModel.canEnterApp,
            profileIsAuthorized: appModel.isActiveProfileAuthorized,
            profileGateIsPresented: profileAccessGateBinding.wrappedValue,
            downloadsAreReady: downloads.profileID == targetProfileID
                && (downloads.hasLoadedRecords || downloads.initializationError != nil),
            presentationIsAvailable: notificationDismissals.isEmpty
                && !showingSettings && !appModel.isSettingsPresented
                && !showingProfileSwitcher && !showingAddServer
                && !showDetectedCover && !showReceiveFromDetected && pairingServer == nil
                && appModel.pendingPairingInvite == nil
                && !releaseNotes.hasPendingStartupNotes
                && appModel.pendingSyncedServerPrompt == nil
        )
    }

    private var pendingPairingBinding: Binding<PendingPairing?> {
        Binding(
            get: { appModel.pendingPairingInvite.map(PendingPairing.init(invite:)) },
            set: { newValue in
                if newValue == nil { appModel.pendingPairingInvite = nil }
            }
        )
    }

    private func showAddServer() {
        appModel.beginManagedServerPresentation()
        showingAddServer = true
    }

    /// Adopt a server synced from another device: open the Add Server sheet pre-filled
    /// with its provider + address, so the user only has to sign in.
    private func setUpPendingSyncedServer(_ descriptor: SyncedAccountDescriptor) {
        serverSetupSeed = descriptor
        showAddServer()
    }

    /// Presentation binding for the one-time new-server prompt. Clearing it (a button
    /// tap or a swipe-down) dismisses the sheet.
    private var serverPromptBinding: Binding<SyncedAccountDescriptor?> {
        Binding(
            // Suppress the mid-session drawer while the full-page "we found your setup"
            // cover is (or is about to be) presented at cold launch, so the two don't
            // fight over the same server.
            get: {
                (appModel.isSettingsPresented || showDetectedCover || detectedFollowUpReceive)
                    ? nil : appModel.pendingSyncedServerPrompt
            },
            set: { if $0 == nil { appModel.clearPendingSyncedServerPrompt() } }
        )
    }

    private func considerColdLaunchDetection() {
        guard !coldLaunchDetectionHandled else { return }
        let offers = appModel.pendingSetupOffers
        guard !offers.isEmpty else { return }
        coldLaunchDetectionHandled = true
        detectedSetupServers = offers
        // The cover supersedes the drawer for these servers this launch.
        appModel.clearPendingSyncedServerPrompt()
        showDetectedCover = true
    }

    /// Run the action chosen in the prompt once its sheet has fully dismissed. A
    /// swipe-to-dismiss leaves `serverPromptFollowUp == nil`, which behaves like
    /// "Not Now" (the server still lives under Settings ▸ iCloud Sync).
    private func consumeServerPromptFollowUp() {
        guard let follow = serverPromptFollowUp else { return }
        serverPromptFollowUp = nil
        switch follow {
        case .signIn(let descriptor):
            setUpPendingSyncedServer(descriptor)
        case .pairDevice(let descriptor):
            pairingServer = descriptor
        }
    }
}

/// Keeps scene-environment invalidation out of the full app root. Process
/// lifecycle admission is driven independently by UIKit scene notifications.
private struct PlozziOSScenePhaseEffects: View {
    @Environment(\.scenePhase) private var scenePhase
    let appModel: PlozziOSAppModel

    var body: some View {
        Color.clear
            .onChange(of: scenePhase, initial: true) { _, newPhase in
                if newPhase == .active {
                    appModel.accountsProviders.retryUnconfirmedCredentials()
                    appModel.syncCloudOnForeground()
                }
            }
    }
}

private struct PendingPairing: Identifiable {
    let invite: String
    var id: String { invite }
}

enum PlozziOSDestination: Identifiable, Hashable {
    case home
    case watchlist
    case liveTV
    case downloads
    case search
    case settings
    case allLibraries
    case library(String)

    var id: Self { self }

    var rawValue: String {
        switch self {
        case .home: "home"
        case .watchlist: "watchlist"
        case .liveTV: "liveTV"
        case .downloads: "downloads"
        case .search: "search"
        case .settings: "settings"
        case .allLibraries: "allLibraries"
        case let .library(key): "library:\(key)"
        }
    }

    init?(rawValue: String) {
        switch rawValue {
        case "home": self = .home
        case "watchlist": self = .watchlist
        case "liveTV": self = .liveTV
        case "downloads": self = .downloads
        case "search": self = .search
        case "settings": self = .settings
        case "allLibraries": self = .allLibraries
        default:
            guard rawValue.hasPrefix("library:") else { return nil }
            self = .library(String(rawValue.dropFirst("library:".count)))
        }
    }

    var diagnosticCategory: String {
        if case .library = self { return "library" }
        if self == .allLibraries { return "library" }
        return rawValue
    }

    var title: LocalizedStringResource {
        switch self {
        case .home: "Home"
        case .watchlist: "Watchlist"
        case .liveTV: "Live TV"
        case .downloads: "Downloads"
        case .search: "Search"
        case .settings: "Settings"
        case .allLibraries: AllLibrariesBrowse.title
        case .library: "Libraries"
        }
    }

    var systemImage: String {
        switch self {
        case .home: "house"
        case .watchlist: "bookmark"
        case .liveTV: "antenna.radiowaves.left.and.right"
        case .downloads: "arrow.down.circle"
        case .search: "magnifyingglass"
        case .settings: "gearshape"
        case .allLibraries: "square.stack.3d.up"
        case .library: "rectangle.stack"
        }
    }
}

/// Performs the capture rig's tab requests. See ``PlozziOSScreenshotDirector``.
private struct PlozziOSScreenshotTabRouter: View {
    let director: PlozziOSScreenshotDirector
    let onSelect: (String) -> Void

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .task(id: director.tab) {
                guard let tab = director.tab else { return }
                director.tab = nil
                onSelect(tab)
                director.finish(.ok)
            }
    }
}

struct PlozziOSTabShell: View {
    @Environment(\.themePalette) private var palette
    @Environment(\.plozziOSUsesVerticalToolbar) private var usesVerticalToolbar
    @Environment(PlozziOSSidebarGeometryModel.self)
    private var sidebarGeometry
    @Environment(HeroTrailerController.self)
    private var heroTrailerController
    @State private var selectedDestination: PlozziOSDestination = .home
    @State private var isShowingMorePage = false
    @State private var overflowNavigation = PlozziOSOverflowNavigation()
    @State private var hasVisibleSettingsNavigationEntry = false
    @State private var lastContentDestination: PlozziOSDestination = .home
    @State private var retainsExplicitLiveTVEntry = false
    @State private var retainsExplicitHomeEntry = false
    @State private var retainsExplicitWatchlistEntry = false
    @State private var retainsExplicitDownloadEntry = false
    @State private var downloadNavigationID: UUID?
    @State private var hasChosenNavigationDestination = false
    let homeViewModelBox: LazyViewState<HomeViewModel>
    var sharedHomeViewModel: HomeViewModel {
        homeViewModelBox.value(forKey: homeContentIdentity) {
            Self.makeHomeViewModel(appModel: appModel)
        }
    }
    /// The profile picker opened deliberately (from Settings) rather than at
    /// launch. Presented from the ROOT so the Parental PIN and profile-lock gates
    /// it can raise aren't asked for from underneath the Settings sheet — the
    /// arrangement that fails silently.
    /// Set while Settings is closing, so the picker can be raised from its
    /// `onDismiss` rather than in the same turn as the dismissal.
    @State private var wantsProfileSwitcher = false
    /// A direct Settings selection waits for that sheet to finish dismissing.
    @State private var pendingSwitchProfileID: String?

    /// Raises a link parked by `PlozziOSRootView.receivePairingURL` now that the
    /// sheet that was covering the root has actually gone.
    private func consumeDeferredPairingURL() {
        guard let url = deferredPairingURL else { return }
        deferredPairingURL = nil
        appModel.handleIncomingURL(url)
    }
    let appModel: PlozziOSAppModel
    let onAddServer: () -> Void
    @Binding var showingSettings: Bool
    @Binding var showingProfileSwitcher: Bool
    /// A pairing link parked until this shell's sheets have closed — see
    /// `PlozziOSRootView.receivePairingURL`.
    @Binding var deferredPairingURL: URL?
    let onNotificationPresentationDismissed: (PlozziOSRootView.NotificationPresentation) -> Void
    let systemColorScheme: ColorScheme
    let onLiveTVActivityChanged: (Bool) -> Void

    init(
        appModel: PlozziOSAppModel,
        homeViewModelBox: LazyViewState<HomeViewModel>,
        onLiveTVActivityChanged: @escaping (Bool) -> Void = { _ in },
        onAddServer: @escaping () -> Void,
        showingSettings: Binding<Bool>,
        showingProfileSwitcher: Binding<Bool>,
        deferredPairingURL: Binding<URL?>,
        onNotificationPresentationDismissed:
            @escaping (PlozziOSRootView.NotificationPresentation) -> Void = { _ in },
        systemColorScheme: ColorScheme
    ) {
        self.appModel = appModel
        self.homeViewModelBox = homeViewModelBox
        self.onLiveTVActivityChanged = onLiveTVActivityChanged
        self.onAddServer = onAddServer
        _showingSettings = showingSettings
        _showingProfileSwitcher = showingProfileSwitcher
        _deferredPairingURL = deferredPairingURL
        self.onNotificationPresentationDismissed = onNotificationPresentationDismissed
        self.systemColorScheme = systemColorScheme
        let visible = Self.configuredDestinations(appModel: appModel)
        let initial: PlozziOSDestination
        initial = AppAdmissionNavigation.initialSelection(
            current: .home,
            visible: visible,
            liveTV: .liveTV,
            fallback: .settings,
            admission: appModel.admissionContext,
            hasPendingLiveTVEntry: appModel.pendingStandaloneLiveTVEntry,
            prefersLiveTV: Self.navigationAvailability(appModel: appModel).prefersLiveTV
        )
        _selectedDestination = State(initialValue: initial)
        _lastContentDestination = State(initialValue: initial)
    }

    static func configuredDestinations(appModel: PlozziOSAppModel) -> [PlozziOSDestination] {
        let navigation = appModel.settings.navigation
        let libraries = appModel.visibleNavigationLibraries
        let libraryKeys = Set(libraries.map(\.key))
        return navigation.libraryLayout.resolvingAutomaticVisibility(
            hidden: NavigationDestinationDefaults.iOSAutomaticallyHiddenKeys(
                available: NavigationDestinationDefaults.iOS(visibleLibraries: libraries)
            )
        )
            .sections(
                available: NavigationDestinationDefaults.iOS(visibleLibraries: libraries),
                requiredEnabled: navigation.requiredNavigationKeys
            ).enabled
            .compactMap { key -> PlozziOSDestination? in
                switch key {
                case NavigationLibraryLayout.homeKey: return .home
                case NavigationLibraryLayout.watchlistKey: return .watchlist
                case NavigationLibraryLayout.liveTVKey: return .liveTV
                case NavigationLibraryLayout.searchKey: return .search
                case NavigationLibraryLayout.downloadsKey: return .downloads
                case NavigationLibraryLayout.settingsKey: return .settings
                case NavigationLibraryLayout.allLibrariesKey: return .allLibraries
                default: return libraryKeys.contains(key) ? .library(key) : nil
                }
            }
    }

    private static func navigationAvailability(appModel: PlozziOSAppModel) -> NavigationContentAvailability {
        let navigation = appModel.settings.navigation
        return NavigationContentAvailability(
            accounts: appModel.accountsProviders.navigationAccounts,
            libraries: navigation.contentLibraries,
            discoveredAccountIDs: navigation.discoveredAccountIDs,
            disabledLibraryKeys: appModel.settings.homeVisibility.visibility.disabledKeys,
            hasDiscoverySearch: appModel.seerService.isConfigured,
            hasWatchlistItems: navigation.hasWatchlistItems
        )
    }

    private func refreshWatchlistNavigation() {
        if let hasItems = appModel.navigationWatchlistHasItems {
            appModel.settings.navigation.hasWatchlistItems = hasItems
        }
    }

    private var tabDestinations: [PlozziOSDestination] {
        var configured = Self.configuredDestinations(appModel: appModel)
        if retainsExplicitHomeEntry, !configured.contains(.home) {
            configured.insert(.home, at: 0)
        }
        if retainsExplicitDownloadEntry, !configured.contains(.downloads) {
            configured.append(.downloads)
        }
        if retainsExplicitWatchlistEntry, !configured.contains(.watchlist) {
            configured.append(.watchlist)
        }
        return AppAdmissionNavigation.destinations(
            configured,
            liveTV: .liveTV,
            includesExplicitEntry: (appModel.allowsStandalonePlayback && appModel.pendingStandaloneLiveTVEntry)
                || retainsExplicitLiveTVEntry
        )
    }

    private var effectiveSelectedDestination: PlozziOSDestination {
        if appModel.pendingStandaloneLiveTVEntry && appModel.allowsStandalonePlayback {
            return .liveTV
        }
        return resolvedDestination(selectedDestination)
    }

    private var destinationSelection: Binding<PlozziOSDestination> {
        Binding(
            get: { effectiveSelectedDestination },
            set: openDestination
        )
    }

    private func openDestination(_ destination: PlozziOSDestination) {
        hasChosenNavigationDestination = true
        if destination == .settings {
            showSettings()
        } else {
            selectDestination(destination)
        }
    }

    private func selectDestination(_ destination: PlozziOSDestination) {
        isShowingMorePage = false
        selectedDestination = resolvedDestination(destination)
    }

    private func consumeStandaloneEntryIfNeeded() {
        guard appModel.pendingStandaloneLiveTVEntry, appModel.allowsStandalonePlayback else { return }
        retainsExplicitLiveTVEntry = true
        selectDestination(.liveTV)
        lastContentDestination = .liveTV
        appModel.consumeStandaloneLiveTVEntryIntent()
    }

    private var tabDestinationKey: String {
        tabDestinations.map(\.rawValue).joined(separator: "|")
    }

    private func resolvedDestination(
        _ destination: PlozziOSDestination
    ) -> PlozziOSDestination {
        tabDestinations.contains(destination)
            ? destination
            : (tabDestinations.first ?? .settings)
    }

    private func tabContent(for destination: PlozziOSDestination) -> some View {
        let isOverflow = overflowNavigation.destinationIndex.map {
            tabDestinations.indices.contains($0) && tabDestinations[$0] == destination
        } ?? false
        return NavigationStack {
            destinationContent(for: destination, keepsNavigationBar: isOverflow)
                .toolbar {
                    if isOverflow, destination != .downloads {
                        PlozziOSOverflowBackToolbarItem(action: overflowNavigation.returnToMore)
                    }
                }
                .environment(\.plozziOSIsOverflowDestination, isOverflow)
                .environment(\.plozziOSOverflowNavigation, overflowNavigation)
        }
        .id(destination == .downloads ? downloadNavigationID : nil)
    }

    @ViewBuilder
    private func destinationContent(
        for destination: PlozziOSDestination, keepsNavigationBar: Bool = false
    ) -> some View {
        switch destination {
        case .home:
            PlozziOSDestinationView(
                destination: .home,
                appModel: appModel,
                sharedHomeViewModel: sharedHomeViewModel,
                onAddServer: onAddServer,
                onShowSettings: showSettings
            )
            .environment(
                \.plozziOSHomeIsFrontmost,
                effectiveSelectedDestination == .home && !isShowingMorePage && !showingSettings
            )
            .environment(\.openWatchlist, {
                retainsExplicitWatchlistEntry = true
                openDestination(.watchlist)
            })
            .plozziOSLibraryDestination(appModel: appModel)
            .plozziOSItemNavigation(appModel: appModel, registersScreenshotRouting: true)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbarBackground(.hidden, for: .tabBar)
            .background { AppBackground(palette: palette) }
        case .watchlist:
            PlozziOSDestinationView(
                destination: .watchlist,
                appModel: appModel,
                sharedHomeViewModel: sharedHomeViewModel,
                onAddServer: onAddServer,
                onShowSettings: showSettings
            )
            .plozziOSItemNavigation(appModel: appModel)
            .toolbarBackground(.hidden, for: .navigationBar)
            .background { AppBackground(palette: palette) }
        case .liveTV:
            PlozziOSLiveTVDestination(
                isActive: effectiveSelectedDestination == .liveTV && !isShowingMorePage,
                profileID: appModel.profiles.activeProfileID,
                preferencesNamespace: appModel.profiles.activeNamespace,
                playbackOrientation: appModel.settings.playback.settings.orientation,
                accountsProviders: appModel.accountsProviders,
                authenticatedHTTPResolver: appModel.authenticatedHTTPResolver,
                connectServer: onAddServer,
                onShowSettings: showSettings,
                didConfigurePlaylist: {
                    _ = appModel.recordSuccessfulIPTVSetup()
                },
                completeLibraryChannelPlayback: { [appModel,
                    profileID = appModel.profiles.activeProfileID,
                    namespace = appModel.profiles.activeNamespace] item, token in
                    try Task.checkCancellation()
                    guard appModel.profiles.activeProfileID == profileID,
                          appModel.profiles.activeNamespace == namespace,
                          LibraryChannelHistorySettings.shared(namespace: namespace).authorizationID == token,
                          let accountID = item.sourceAccountID,
                          appModel.accountsProviders.resolvedActiveAccounts.contains(where: {
                              $0.account.id == accountID
                          }) else { throw LibraryChannelError.authorizationChanged }
                    try appModel.completeLibraryChannelPlayback(for: item, authorizationID: token)
                },
                isProfileAuthorized: { [appModel] in appModel.isLiveTVProfileAuthorized },
                restoreDestination: { [profileID = appModel.profiles.activeProfileID] in
                    guard appModel.isLiveTVProfileAuthorized,
                          appModel.profiles.activeProfileID == profileID,
                          tabDestinations.contains(.liveTV) else { return false }
                    selectDestination(.liveTV)
                    return effectiveSelectedDestination == .liveTV && !isShowingMorePage
                }
            )
            .environment(appModel.profiles)
            .plozziOSItemNavigation(appModel: appModel)
        case .downloads:
            PlozziOSDestinationView(
                destination: .downloads,
                appModel: appModel,
                sharedHomeViewModel: sharedHomeViewModel,
                onAddServer: onAddServer,
                onShowSettings: showSettings,
                downloadNotificationID: downloadNavigationID
            )
            .toolbarBackground(.hidden, for: .navigationBar)
            .background { AppBackground(palette: palette) }
        case .search:
            PlozziOSDestinationView(
                destination: .search,
                appModel: appModel,
                sharedHomeViewModel: sharedHomeViewModel,
                onAddServer: onAddServer,
                onShowSettings: showSettings,
                keepsNavigationBar: keepsNavigationBar
            )
            .plozziOSItemNavigation(appModel: appModel)
            .toolbarBackground(.hidden, for: .navigationBar)
            .background { AppBackground(palette: palette) }
        case .allLibraries:
            PlozziOSAllLibrariesDestinationView(appModel: appModel)
                .id(homeContentIdentity + "|" + allLibrariesSourceSignature(appModel.visibleNavigationLibraries))
                .plozziOSItemNavigation(appModel: appModel)
                .plozziOSLibraryDestination(appModel: appModel)
                .toolbar {
                    if usesVerticalToolbar || !hasVisibleSettingsNavigationEntry {
                        PlozziOSSettingsToolbarItem(horizontalPlacement: .primaryAction, action: showSettings)
                    }
                }
                .background { AppBackground(palette: palette) }
        case let .library(key):
            if let library = appModel.visibleNavigationLibraries.first(where: { $0.key == key }) {
                PlozziOSLibraryDestinationView(
                    appModel: appModel,
                    route: PlozziOSLibraryRoute(library: library.library, accountID: library.accountID)
                )
                .id(homeContentIdentity)
                .plozziOSItemNavigation(appModel: appModel)
                .toolbar {
                    if usesVerticalToolbar || !hasVisibleSettingsNavigationEntry {
                        PlozziOSSettingsToolbarItem(horizontalPlacement: .primaryAction, action: showSettings)
                    }
                }
                .background { AppBackground(palette: palette) }
            }
        case .settings:
            VStack(spacing: 24) {
                Label("Settings", systemImage: "gearshape")
                    .font(.largeTitle)
                Button("Open Settings", action: showSettings)
                    .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background { AppBackground(palette: palette) }
        }
    }

    private func destinationTitle(_ destination: PlozziOSDestination) -> Text {
        guard case let .library(key) = destination,
              let library = appModel.visibleNavigationLibraries.first(where: { $0.key == key }) else {
            return Text(destination.title)
        }
        return library.library.displayName
    }

    func destinationSystemImage(_ destination: PlozziOSDestination) -> String {
        guard case let .library(key) = destination,
              let library = appModel.visibleNavigationLibraries.first(where: { $0.key == key }) else {
            return destination.systemImage
        }
        return library.library.navigationSymbolName
    }

    private static func makeHomeViewModel(
        appModel: PlozziOSAppModel
    ) -> HomeViewModel {
        HomeViewModel(
            accounts: appModel.accountsProviders.homeAccounts,
            profileNamespace: appModel.profiles.activeNamespace,
            contentStore: HomeContentStore(
                namespace: appModel.profiles.activeNamespace
            ),
            identitySources: appModel.identityIndex.identitySourcesProvider,
            currentVisibility: { [weak appModel] in
                appModel?.settings.homeVisibility.visibility ?? .default
            },
            prepareVisibility: { [weak appModel] in
                guard let appModel else { return }
                await appModel.settings.homeVisibility.prepareServerDefaults(
                    accounts: appModel.accountsProviders.homeAccounts
                )
            },
            sectionDiagnostics: appModel.settings.homeVisibility.sectionDiagnostics,
            pendingWatchMutations: { [weak appModel] in
                await appModel?.pendingWatchMutations() ?? []
            },
            recentlyAppliedRecency: { [weak appModel] in
                await appModel?.appliedWatchRecency() ?? [:]
            },
            mediaItemActionHandler: appModel.mediaItemActionHandler
        )
    }

    private var contentAwareTabs: some View {
        TabView(selection: destinationSelection) {
            ForEach(tabDestinations) { destination in
                if destination == .search && tabDestinations.last == .search {
                    // Preserve native trailing Search until the viewer moves it.
                    Tab(
                        "Search",
                        systemImage: "magnifyingglass",
                        value: PlozziOSDestination.search,
                        role: .search
                    ) {
                        tabContent(for: destination)
                    }
                } else if destination == .downloads {
                    Tab(value: destination) {
                        tabContent(for: destination)
                    } label: {
                        PlozziOSDownloadsTabLabel(model: appModel.downloads)
                    }
                } else {
                    Tab(value: destination) {
                        tabContent(for: destination)
                    } label: {
                        Label {
                            destinationTitle(destination)
                        } icon: {
                            if destination == .settings {
                                ProfileAvatarView(
                                    profile: appModel.profiles.activeProfile, size: 28, rendersAsImage: true
                                )
                            } else {
                                Image(systemName: destinationSystemImage(destination))
                            }
                        }
                    }
                }
            }
        }

        .tabViewStyle(.sidebarAdaptable)
        .background {
            PlozziOSSettingsTabAction(
                tabIndex: tabDestinations.firstIndex(of: .settings),
                action: showSettings,
                onOverflowVisibilityChange: { isShowingMorePage = $0 },
                onSettingsVisibilityChange: { hasVisibleSettingsNavigationEntry = $0 },
                overflowNavigation: overflowNavigation
            )
            .frame(width: 0, height: 0)
        }
        .environment(sharedHomeViewModel)
        .environment(\.hasVisibleSettingsNavigationEntry, hasVisibleSettingsNavigationEntry)
        .onAppear { refreshWatchlistNavigation() }
        .onReceive(NotificationCenter.default.publisher(for: .universalWatchlistDidChange)) { _ in
            refreshWatchlistNavigation()
        }
        .onReceive(NotificationCenter.default.publisher(for: .universalWatchlistCacheDidLoad)) { _ in
            refreshWatchlistNavigation()
        }
        .onChange(of: NavigationDestinationDefaults.iOS(visibleLibraries: appModel.visibleNavigationLibraries),
                  initial: true) { _, available in
            appModel.settings.navigation.automaticallyHiddenKeys =
                NavigationDestinationDefaults.iOSAutomaticallyHiddenKeys(available: available)
        }
        .task(id: homeContentIdentity, priority: .utility) {
            await refreshNavigationLibraries()
        }
    }

    private func refreshNavigationLibraries() async {
        let navigation = appModel.settings.navigation
        let accounts = appModel.accountsProviders.homeAccounts
        let accountIDs = Set(accounts.map(\.account.id))
        let resolvesInitialCatalogue = !accountIDs.isEmpty
            && accounts.allSatisfy { $0.account.server.provider == .iptv }
            && !navigation.discoveredAccountIDs.isSuperset(of: accountIDs)
        guard await appModel.refreshNavigationLibraries(),
              appModel.settings.navigation === navigation else { return }
        if resolvesInitialCatalogue, !hasChosenNavigationDestination,
           navigation.discoveredAccountIDs.isSuperset(of: accountIDs) {
            selectDestination(AppAdmissionNavigation.initialSelection(
                current: .home, visible: tabDestinations, liveTV: .liveTV, fallback: .settings,
                admission: appModel.admissionContext,
                hasPendingLiveTVEntry: appModel.pendingStandaloneLiveTVEntry,
                prefersLiveTV: Self.navigationAvailability(appModel: appModel).prefersLiveTV
            ))
        }
    }

    var body: some View {
        contentAwareTabs
        .homeLiveTVScope(
            profileID: appModel.profiles.activeProfileID,
            namespace: appModel.profiles.activeNamespace,
            accounts: appModel.accountsProviders,
            isAuthorized: { appModel.isLiveTVProfileAuthorized },
            navigate: {
                guard appModel.isLiveTVProfileAuthorized else { return false }
                retainsExplicitLiveTVEntry = true
                openDestination(.liveTV)
                return true
            }
        )
        .environment(appModel.profiles)
        .onChange(
            of: PlozziOSDownloadNotificationNavigation.shared.presentation?.id, initial: true
        ) { _, _ in
            let navigation = PlozziOSDownloadNotificationNavigation.shared
            guard appModel.isActiveProfileAuthorized,
                  navigation.claimTabSelection(profileID: appModel.profiles.activeProfileID) else { return }
            retainsExplicitDownloadEntry = true
            downloadNavigationID = navigation.presentation?.id
            _ = appModel.consumeStandaloneLiveTVEntryIntent()
            openDestination(.downloads)
        }
        .onChange(of: appModel.pendingStandaloneLiveTVEntry, initial: true) { _, _ in
            consumeStandaloneEntryIfNeeded()
        }
        .onChange(of: tabDestinationKey, initial: true) { _, _ in
            selectDestination(selectedDestination)
        }
        .onChange(of: isShowingMorePage) { _, showingMore in
            if showingMore { heroTrailerController.stop() }
        }
        .onChange(of: effectiveSelectedDestination == .liveTV && !isShowingMorePage, initial: true) { _, active in
            onLiveTVActivityChanged(active)
        }
        .onDisappear { onLiveTVActivityChanged(false) }
        .onChange(of: selectedDestination, initial: true) { _, destination in
            MainThreadStallProbe.context = destination.diagnosticCategory
            if destination == .settings {
                showSettings()
            } else {
                lastContentDestination = destination
            }
            if destination == .liveTV {
                heroTrailerController.stop()
            } else {
                retainsExplicitLiveTVEntry = false
            }
            if destination != .home { retainsExplicitHomeEntry = false }
            if destination != .watchlist { retainsExplicitWatchlistEntry = false }
            if destination != .downloads { retainsExplicitDownloadEntry = false }
        }
        .background { AppBackground(palette: palette) }
        .background(alignment: .topLeading) {
            PlozziOSHomeSidebarOverlapProbe(
                enabled: effectiveSelectedDestination == .home && !isShowingMorePage,
                geometryModel: sidebarGeometry
            )
            .frame(width: 0, height: 0)
        }
        .background {
            // Switching tabs is the shell's job, so the capture rig's tab requests
            // are consumed here rather than in the Home stack. A zero-size leaf, so
            // reading the request never invalidates the tab view.
            PlozziOSScreenshotTabRouter(
                director: appModel.screenshotDirector,
                onSelect: { name in
                    guard let destination = PlozziOSDestination(rawValue: name) else { return }
                    openDestination(destination)
                }
            )
            #if DEBUG
            // The push seams live on the Home stack, so the router brings this tab
            // forward before it navigates. Registered here because only the shell
            // owns the tab selection.
            .onAppear {
                appModel.screenshotDirector.selectHomeTab = {
                    retainsExplicitHomeEntry = true
                    selectDestination(.home)
                }
            }
            #endif
        }
        .background {
            // Every other request — detail, person, library, play — is performed
            // here too, OUTSIDE the navigation stacks. On the Home screen the
            // router's `.task` was cancelled the moment a pushed page covered it,
            // so only the first request of a run was ever acked; out here nothing
            // covers it, and it reaches the pushes and player through the seams the
            // Home stack and Home view register on the director.
            PlozziOSScreenshotRouter(appModel: appModel)
        }
        // The setup cover is presented from inside Settings when Settings is up,
        // and from the root when it isn't — see `ProfileOnboardingOrigin`. That
        // decision reads this.
        .onChange(of: showingSettings) { _, presented in
            MainThreadStallProbe.context = presented ? "settings" : selectedDestination.diagnosticCategory
            // Only the RISING edge here. Dismissal is animated, and publishing
            // false the moment Close is tapped lets the root ask for the identity
            // sheet while Settings is still covering it — SwiftUI drops that, and
            // nothing re-triggers it. The falling edge is `onDismiss`, which runs
            // when the sheet is actually gone.
            if presented { appModel.noteSettingsPresented(true) }
        }
        .plozzSheet(isPresented: $showingSettings, onDismiss: {
            appModel.noteSettingsPresented(false)
            if wantsProfileSwitcher {
                wantsProfileSwitcher = false
                showingProfileSwitcher = true
            } else if let id = pendingSwitchProfileID {
                // This direct Settings action uses the root's authorization
                // cover, so it waits until Settings is actually gone.
                pendingSwitchProfileID = nil
                appModel.selectProfile(id)
            }
            if selectedDestination == .settings {
                let fallback = tabDestinations.first {
                    $0 != .settings
                } ?? .settings
                selectDestination(tabDestinations.contains(lastContentDestination)
                    && lastContentDestination != .settings
                    ? lastContentDestination
                    : fallback)
            }
            consumeDeferredPairingURL()
            onNotificationPresentationDismissed(.settings)
        }) {
            PlozziOSSettingsView(
                appModel: appModel,
                onClose: { showingSettings = false },
                onSwitchProfile: {
                    // Requested, not presented here. Dismissing Settings and
                    // presenting the picker in the SAME turn is the arrangement
                    // SwiftUI drops — and this is the only way to switch profiles
                    // on iOS, so losing it strands the user. The sheet's
                    // `onDismiss` raises the picker once Settings is actually gone.
                    wantsProfileSwitcher = true
                    showingSettings = false
                },
                onSwitchTo: { pendingSwitchProfileID = $0 },
                systemColorScheme: systemColorScheme
            )
            .environment(\.themeMusicPreviewResolver, {
                try await ThemeMusicPreviewResolver.resolve(
                    content: homeViewModelBox.existingValue(forKey: homeContentIdentity)?.state.value,
                    accounts: appModel.accountsProviders.homeAccounts
                )
            })
            .presentationSizing(.page)
            // Elevation edge for the all-black theme: without it the sheet's
            // dark surface blends straight into the dark page behind it, so the
            // drawer doesn't read as a layer above the content. Reuse the exact
            // hairline the settings group cards use (`cardOpaqueBorder`), pin the
            // sheet corner radius so the stroke traces the card's rounded top
            // corners precisely, and mask it to the top so only the floating top
            // rim shows — the sides/bottom sit at the screen edge where a border
            // adds nothing. Dark themes only; a light sheet already separates
            // itself from the page behind it.
            .presentationCornerRadius(Self.settingsSheetCornerRadius)
            .overlay {
                if !settingsPalette.isLight {
                    RoundedRectangle(
                        cornerRadius: Self.settingsSheetCornerRadius,
                        style: .continuous
                    )
                    .strokeBorder(settingsPalette.overlay.border ?? .clear, lineWidth: settingsPalette.overlay.borderWidth)
                    .mask {
                        LinearGradient(
                            stops: [
                                .init(color: .white, location: 0),
                                .init(color: .white, location: 0.04),
                                .init(color: .clear, location: 0.12),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    }
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                }
            }
        }
    }

    /// Corner radius pinned on the Settings sheet so the elevation border can
    /// trace the card's rounded edge exactly (SwiftUI's default sheet radius is
    /// unspecified, which would leave the overlay stroke and the real corner
    /// slightly misaligned).
    private static let settingsSheetCornerRadius: CGFloat = 20

    private var settingsPalette: ThemePalette {
        ThemePalette.palette(
            for: appModel.settings.theme.theme,
            systemColorScheme: systemColorScheme
        )
    }

    /// The retained Home model is profile/account scoped. Watchlist shares it
    /// within that scope, then a real profile or credential change replaces it.
    private var homeContentIdentity: String {
        appModel.navigationLibrariesScopeKey
    }

    private func showSettings() {
        hasChosenNavigationDestination = true
        showingSettings = true
    }

}

struct PlozziOSDownloadsTabLabel: View {
    let model: PlozziOSDownloadsModel

    var body: some View {
        Label {
            Text("Downloads")
        } icon: {
            downloadsTabIcon
        }
    }

    /// Overall progress for work that is actively transferring. Completed
    /// siblings in the same season batch remain in the denominator so the tab
    /// ring advances monotonically instead of resetting each time an episode
    /// finishes and the next queued episode starts.
    private var downloadsNavigationProgress: Double? {
        let active = model.records.filter {
            $0.status == .queued
                || $0.status == .preparing
                || $0.status == .downloading
        }
        guard !active.isEmpty else { return nil }

        let activeKeys = Set(active.map(\.identityKey))
        let activeBatchIDs = Set(active.compactMap(\.batchID))
        let tracked = model.records.filter {
            activeKeys.contains($0.identityKey)
                || $0.batchID.map(activeBatchIDs.contains) == true
        }

        // Keep one aggregation strategy for the lifetime of the cohort. Total
        // byte counts arrive only after each transfer starts; switching from
        // item-average to byte-weighted progress at that point makes the ring
        // visibly jump backward.
        let progress = tracked.reduce(0.0) {
            $0 + ($1.fractionCompleted
                ?? ($1.status == .completed ? 1 : 0))
        } / Double(tracked.count)
        return min(max(progress, 0), 1)
    }

    private var downloadsTabIcon: Image {
        guard let progress = downloadsNavigationProgress else {
            return Image(systemName: "arrow.down.circle")
        }
        return Image(uiImage: Self.downloadsProgressImage(progress: progress))
    }

    private static func downloadsProgressImage(progress: Double) -> UIImage {
        let size = CGSize(width: 21, height: 21)
        let lineWidth = 2.5
        let inset = lineWidth / 2
        let bounds = CGRect(origin: .zero, size: size).insetBy(dx: inset, dy: inset)
        let renderer = UIGraphicsImageRenderer(size: size)

        return renderer.image { _ in
            UIColor.black.withAlphaComponent(0.25).setStroke()
            let track = UIBezierPath(ovalIn: bounds)
            track.lineWidth = lineWidth
            track.stroke()

            UIColor.black.setStroke()
            let ring = UIBezierPath(
                arcCenter: CGPoint(x: size.width / 2, y: size.height / 2),
                radius: (size.width - lineWidth) / 2,
                startAngle: -.pi / 2,
                endAngle: (-.pi / 2) + (2 * .pi * max(progress, 0.02)),
                clockwise: true
            )
            ring.lineWidth = lineWidth
            ring.lineCapStyle = .round
            ring.stroke()
        }
        .withRenderingMode(.alwaysTemplate)
    }

}

// Reject the native transition before it changes navigation insets or scroll position.
// Rejecting only the SwiftUI selection binding is too late for an action-only tab.
struct PlozziOSSettingsTabAction: UIViewControllerRepresentable {
    let tabIndex: Int?
    let action: () -> Void
    var onOverflowVisibilityChange: ((Bool) -> Void)?
    var onSettingsVisibilityChange: ((Bool) -> Void)?
    var overflowNavigation: PlozziOSOverflowNavigation?

    func makeUIViewController(context: Context) -> Controller { Controller() }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.tabIndex = tabIndex
        controller.action = action
        controller.onOverflowVisibilityChange = onOverflowVisibilityChange
        controller.onSettingsVisibilityChange = onSettingsVisibilityChange
        controller.overflowNavigation = overflowNavigation
        controller.install()
    }

    static func dismantleUIViewController(_ controller: Controller, coordinator: ()) {
        controller.restore()
        controller.action = nil
        controller.onOverflowVisibilityChange = nil
        controller.onSettingsVisibilityChange = nil
        controller.overflowNavigation = nil
    }

    final class Controller: UIViewController, UITabBarControllerDelegate, UITableViewDelegate, UINavigationControllerDelegate {
        var tabIndex: Int?
        var action: (() -> Void)?
        var onOverflowVisibilityChange: ((Bool) -> Void)?
        var onSettingsVisibilityChange: ((Bool) -> Void)?
        var overflowNavigation: PlozziOSOverflowNavigation?
        private var reportedSettingsVisibility: Bool?
        private var reportedOverflowVisibility: Bool?
        private weak var owner: UITabBarController?
        private weak var previousDelegate: (any UITabBarControllerDelegate)?
        private weak var overflowTable: UITableView?
        private weak var previousOverflowDelegate: (any UITableViewDelegate)?
        private weak var previousMoreDelegate: (any UINavigationControllerDelegate)?
        private var previousMoreNavigationBarHidden: Bool?

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            if parent == nil {
                restore()
            } else {
                Task { @MainActor [weak self] in self?.install() }
            }
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            install()
            reportOverflowVisibility()
            reportSettingsVisibility()
        }

        func install() {
            guard tabIndex != nil || onOverflowVisibilityChange != nil else {
                restore()
                return
            }
            var ancestor = parent
            while let container = ancestor {
                if let tabs = findTabs(in: container) {
                    if owner !== tabs {
                        restore()
                        owner = tabs
                    }
                    if tabs.delegate !== self {
                        // SwiftUI can overlap old and replacement bridges. Never
                        // chain them: a later layout would link the old one back.
                        if let previous = tabs.delegate as? Controller {
                            previous.restore()
                        }
                        previousDelegate = tabs.delegate
                        tabs.delegate = self
                    }
                    installOverflowAction(in: tabs)
                    reportSettingsVisibility()
                    return
                }
                ancestor = container.parent
            }
        }

        private func findTabs(in controller: UIViewController) -> UITabBarController? {
            if let tabs = controller as? UITabBarController { return tabs }
            for child in controller.children where child !== self {
                if let tabs = findTabs(in: child) { return tabs }
            }
            return nil
        }

        private func tabControllers(in tabs: UITabBarController) -> [UIViewController?] {
            // Native UITab-backed controllers need not populate the legacy array.
            tabs.tabs.isEmpty ? (tabs.viewControllers ?? []) : tabs.tabs.map(\.viewController)
        }

        func restore() {
            if owner?.moreNavigationController.delegate === self {
                owner?.moreNavigationController.delegate = previousMoreDelegate
                if let previousMoreNavigationBarHidden {
                    owner?.moreNavigationController.setNavigationBarHidden(previousMoreNavigationBarHidden, animated: false)
                }
            }
            previousMoreDelegate = nil
            previousMoreNavigationBarHidden = nil
            if overflowTable?.delegate === self { overflowTable?.delegate = previousOverflowDelegate }
            overflowTable = nil
            previousOverflowDelegate = nil
            if owner?.delegate === self { owner?.delegate = previousDelegate }
            owner = nil
            previousDelegate = nil
            reportedOverflowVisibility = nil
            reportedSettingsVisibility = nil
        }

        private func reportSettingsVisibility() {
            guard let owner else { return }
            let tab = tabIndex.flatMap { owner.tabs.indices.contains($0) ? owner.tabs[$0] : nil }
            let controller = tab?.viewController
            let inTabBar = controller.map { controller in
                !owner.isTabBarHidden && (
                    tab?.hasVisiblePlacement == true
                        || (owner.tabBar.items ?? []).contains { $0 === controller.tabBarItem }
                )
            } ?? false
            let visible = tab?.isHidden == false && (inTabBar || !owner.sidebar.isHidden)
            guard reportedSettingsVisibility != visible else { return }
            reportedSettingsVisibility = visible
            Task { @MainActor [weak self, weak owner] in
                guard let self, let owner, self.owner === owner,
                      self.reportedSettingsVisibility == visible else { return }
                self.onSettingsVisibilityChange?(visible)
            }
        }

        private func installOverflowAction(in tabs: UITabBarController) {
            let more = tabs.moreNavigationController
            if more.delegate !== self {
                previousMoreDelegate = more.delegate
                previousMoreNavigationBarHidden = more.isNavigationBarHidden
                more.delegate = self
            }
            if let shown = more.topViewController {
                updateOverflowNavigation(in: more, showing: shown, animated: false)
            }
            func findTable(in view: UIView) -> UITableView? {
                if let table = view as? UITableView { return table }
                return view.subviews.lazy.compactMap(findTable).first
            }
            guard let root = tabs.moreNavigationController.viewControllers.first?.viewIfLoaded,
                  let table = findTable(in: root) else { return }
            if overflowTable !== table {
                if overflowTable?.delegate === self { overflowTable?.delegate = previousOverflowDelegate }
                overflowTable = table
                previousOverflowDelegate = table.delegate
            }
            if table.delegate !== self {
                previousOverflowDelegate = table.delegate
                table.delegate = self
            }
        }

        func navigationController(
            _ navigationController: UINavigationController,
            willShow viewController: UIViewController, animated: Bool
        ) {
            previousMoreDelegate?.navigationController?(
                navigationController, willShow: viewController, animated: animated
            )
            updateOverflowNavigation(in: navigationController, showing: viewController, animated: animated)
        }

        private func updateOverflowNavigation(
            in navigationController: UINavigationController,
            showing viewController: UIViewController,
            animated: Bool
        ) {
            guard let owner, let overflowNavigation,
                  navigationController === owner.moreNavigationController else { return }
            let index = tabControllers(in: owner).firstIndex { $0 === viewController }
            // More wraps the tab's existing SwiftUI NavigationStack. Only the
            // inner bar should draw chrome while a destination is on screen.
            let hidesOuterBar = index != nil || previousMoreNavigationBarHidden == true
            if navigationController.isNavigationBarHidden != hidesOuterBar {
                navigationController.setNavigationBarHidden(hidesOuterBar, animated: animated)
            }
            guard overflowNavigation.destinationIndex != index
                    || overflowNavigation.navigationController !== navigationController else { return }
            Task { @MainActor [weak self, weak owner, weak navigationController, weak viewController] in
                guard let self, let owner, let navigationController, let viewController,
                      self.owner === owner, navigationController.topViewController === viewController else { return }
                overflowNavigation.update(destinationIndex: index, navigationController: navigationController)
            }
        }

        func navigationController(
            _ navigationController: UINavigationController,
            didShow viewController: UIViewController, animated: Bool
        ) {
            previousMoreDelegate?.navigationController?(
                navigationController, didShow: viewController, animated: animated
            )
            if let owner { installOverflowAction(in: owner) }
            reportOverflowVisibility()
        }

        func tableView(_ tableView: UITableView, willSelectRowAt indexPath: IndexPath) -> IndexPath? {
            // Native More bypasses the tab-selection delegate when it pushes a row.
            if let owner, let tabIndex, indexPath.section == 0 {
                let controllers = tabControllers(in: owner)
                let visibleItems = owner.tabBar.items ?? []
                let overflow = controllers.indices.filter { index in
                    guard let controller = controllers[index] else { return true }
                    return !visibleItems.contains { $0 === controller.tabBarItem }
                }
                if overflow.count == tableView.numberOfRows(inSection: 0),
                   controllers.indices.contains(tabIndex),
                   overflow.indices.contains(indexPath.row),
                   overflow[indexPath.row] == tabIndex {
                    action?()
                    return nil
                }
            }
            if previousOverflowDelegate?.responds(to: #selector(UITableViewDelegate.tableView(_:willSelectRowAt:))) == true {
                return previousOverflowDelegate?.tableView?(tableView, willSelectRowAt: indexPath)
            }
            return indexPath
        }

        private func reportOverflowVisibility() {
            guard let owner else { return }
            let more = owner.moreNavigationController
            let visible = owner.selectedViewController === more && more.viewControllers.count == 1
            guard reportedOverflowVisibility != visible else { return }
            reportedOverflowVisibility = visible
            Task { @MainActor [weak self, weak owner] in
                guard let self, let owner, self.owner === owner,
                      self.reportedOverflowVisibility == visible else { return }
                self.onOverflowVisibilityChange?(visible)
            }
        }

        func tabBarController(_ tabBarController: UITabBarController, didSelectTab selectedTab: UITab, previousTab: UITab?) {
            previousDelegate?.tabBarController?(tabBarController, didSelectTab: selectedTab, previousTab: previousTab)
            reportOverflowVisibility()
        }

        func tabBarController(_ tabBarController: UITabBarController, didSelect viewController: UIViewController) {
            previousDelegate?.tabBarController?(tabBarController, didSelect: viewController)
            installOverflowAction(in: tabBarController)
            reportOverflowVisibility()
        }

        func tabBarController(_ tabBarController: UITabBarController, shouldSelectTab tab: UITab) -> Bool {
            if let tabIndex, tabBarController.tabs.indices.contains(tabIndex),
               tabBarController.tabs[tabIndex] === tab {
                action?()
                return false
            }
            return previousDelegate?.tabBarController?(tabBarController, shouldSelectTab: tab) ?? true
        }

        func tabBarController(_ tabBarController: UITabBarController, shouldSelect viewController: UIViewController) -> Bool {
            let controllers = tabControllers(in: tabBarController)
            if let tabIndex, controllers.indices.contains(tabIndex), controllers[tabIndex] === viewController {
                action?()
                return false
            }
            return previousDelegate?.tabBarController?(tabBarController, shouldSelect: viewController) ?? true
        }

        override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || previousDelegate?.responds(to: selector) == true
                || previousOverflowDelegate?.responds(to: selector) == true
                || previousMoreDelegate?.responds(to: selector) == true
        }

        override func forwardingTarget(for selector: Selector!) -> Any? {
            if previousDelegate?.responds(to: selector) == true { return previousDelegate }
            if previousOverflowDelegate?.responds(to: selector) == true { return previousOverflowDelegate }
            if previousMoreDelegate?.responds(to: selector) == true { return previousMoreDelegate }
            return super.forwardingTarget(for: selector)
        }
    }
}

private struct PlozziOSDestinationView: View {
    @Environment(\.themePalette) private var palette
    let destination: PlozziOSDestination
    let appModel: PlozziOSAppModel
    let sharedHomeViewModel: HomeViewModel
    let onAddServer: () -> Void
    let onShowSettings: () -> Void
    var keepsNavigationBar = false
    var downloadNotificationID: UUID?

    var body: some View {
        ZStack {
            AppBackground(palette: palette)
            destinationContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var destinationContent: some View {
        switch destination {
        case .home:
            PlozziOSHomeLandingView(
                appModel: appModel,
                viewModel: sharedHomeViewModel,
                onAddServer: onAddServer,
                onShowSettings: onShowSettings
            )
            .id(activeAccountsIdentity)
        case .watchlist:
            PlozziOSWatchlistLandingView(
                appModel: appModel,
                viewModel: sharedHomeViewModel,
                onShowSettings: onShowSettings
            )
        case .liveTV, .library, .allLibraries:
            EmptyView()
        case .search:
            PlozziOSSearchView(
                appModel: appModel,
                onShowSettings: onShowSettings,
                keepsNavigationBar: keepsNavigationBar
            )
                .id(activeAccountsIdentity)
        case .downloads:
            PlozziOSDownloadsView(
                model: appModel.downloads,
                appModel: appModel,
                onShowSettings: onShowSettings,
                notificationPresentationID: downloadNotificationID
            )
                .id(appModel.profiles.activeProfileID)
        case .settings:
            EmptyView()
        }
    }

    private var activeAccountsIdentity: String {
        let credentials = appModel.accounts
            .map(\.connectionScopeKey)
            .joined(separator: "|")
        let active = appModel.accountsProviders.activeAccountIDs
            .sorted()
            .joined(separator: ",")
        return "\(credentials)#\(active)"
    }
}

struct PlozziOSWatchlistLandingView: View {
    @Environment(\.mediaItemNavigator) private var navigateToItem
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.plozziOSIsOverflowDestination) private var isOverflowDestination
    let appModel: PlozziOSAppModel
    let viewModel: HomeViewModel
    let onShowSettings: () -> Void
    @State private var watchlistIntentRevision = 0

    var body: some View {
        @Bindable var browse = viewModel.watchlistBrowse
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 16) {
                ContentStateView(
                    state: viewModel.state,
                    emptyMessage: "Your Watchlist is empty.",
                    onRetry: { Task { await viewModel.load() } },
                    loadingContent: {
                        watchlistContent(
                            [],
                            loadingPlaceholderCount: horizontalSizeClass == .regular ? 12 : 6
                        )
                    }
                ) { content in
                    watchlistContent(
                        content.watchlist,
                        loadingPlaceholderCount: viewModel.watchlistLoadingPlaceholderCount
                    )
                }
            }
            .padding(.vertical)
        }
        .onScrollGeometryChange(for: CGFloat.self) {
            $0.contentOffset.y
        } action: { oldOffset, newOffset in
            guard oldOffset != newOffset else { return }
            viewModel.noteHomeNavigationInteraction()
        }
        .task(
            id: PlozziOSHomeLoadID(
                visibility: appModel.settings.homeVisibility.visibility,
                viewModel: viewModel
            )
        ) {
            await viewModel.loadIfNeeded(
                for: appModel.settings.homeVisibility.visibility
            )
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: .universalWatchlistDidChange
            )
        ) { _ in
            viewModel.scheduleDurableWatchlistRefresh()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: .universalWatchlistCacheDidLoad
            )
        ) { _ in
            viewModel.scheduleDurableWatchlistRefresh()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: .universalWatchlistLoadingProgressDidChange
            )
        ) { _ in
            viewModel.refreshWatchlistLoadingProgress()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: .watchlistIntentDidChange
            )
        ) { _ in
            watchlistIntentRevision &+= 1
        }
        .navigationTitle("Watchlist")
        .environment(\.plozzCardCaptionView, .watchlist)
        .toolbarTitleDisplayMode(isOverflowDestination ? .inline : .large)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                WatchlistSortMenu(sort: $browse.preferences.sort)
                    .labelStyle(.iconOnly)
                WatchlistFilterMenu(filter: $browse.preferences.filter)
                    .labelStyle(.iconOnly)
            }
            PlozziOSSettingsToolbarItem(action: onShowSettings)
        }
    }

    @ViewBuilder
    private func watchlistContent(
        _ items: [MediaItem],
        loadingPlaceholderCount: Int
    ) -> some View {
        let filteredItems = viewModel.watchlistBrowse.preferences.items(from: items)
        if filteredItems.isEmpty, loadingPlaceholderCount == 0 {
            WatchlistEmptyStateView(isFiltered: !items.isEmpty) {
                viewModel.watchlistBrowse.preferences.filter = .all
            }
        } else {
            LazyVGrid(
                columns: appModel.settings.density.density.iOSPosterGridColumns(
                    horizontalSizeClass: horizontalSizeClass
                ),
                spacing: 18
            ) {
                ForEach(MediaRowView.presentationElements(
                    items: filteredItems,
                    loadingPlaceholderCount: loadingPlaceholderCount
                )) { element in
                    switch element {
                    case .item(let item):
                        Button {
                            navigateToItem?(item)
                        } label: {
                            PlozziOSPosterCard(
                                item: item,
                                spoilerSettings: appModel.settings.spoilers.settings,
                                isPendingRemoval: isPendingRemoval(item)
                            )
                        }
                        .buttonStyle(.plain)
                    case .loadingPlaceholder:
                        PlozziOSPosterCard(
                            item: nil,
                            spoilerSettings: appModel.settings.spoilers.settings
                        )
                    }
                }
            }
            .padding(.horizontal)
            .accessibilityIdentifier("watchlist-grid")
        }
    }

    private func isPendingRemoval(_ item: MediaItem) -> Bool {
        _ = watchlistIntentRevision
        return appModel.mediaItemActionHandler
            .isActivelyRemovingFromWatchlist(item)
    }
}

private struct PlozziOSHomeLandingView: View {
    @Environment(\.plozziOSIsOverflowDestination) private var isOverflowDestination
    let appModel: PlozziOSAppModel
    let viewModel: HomeViewModel
    let onAddServer: () -> Void
    let onShowSettings: () -> Void
    @State private var showingReceive = false

    var body: some View {
        if appModel.accounts.isEmpty {
            ContentUnavailableView {
                Label("Build your library", systemImage: "play.rectangle.on.rectangle")
            } description: {
                Text("Connect a media server or an NFS network share to start watching.")
            } actions: {
                Button("Add Server", action: onAddServer)
                    .buttonStyle(.borderedProminent)
                Button("Set Up from Another Device") { showingReceive = true }
                NavigationLink("Add Network Share") {
                    PlozziOSAddShareView(appModel: appModel)
                }
            }
            .navigationTitle("Home")
            .toolbarTitleDisplayMode(isOverflowDestination ? .inline : .large)
            .toolbar {
                PlozziOSSettingsToolbarItem(action: onShowSettings)
            }
            .plozzFullScreenCover(isPresented: $showingReceive) {
                PlozziOSSyncSetupReceiveView(appModel: appModel) { showingReceive = false }
            }
        } else {
            PlozziOSHomeView(
                appModel: appModel,
                viewModel: viewModel,
                onAddServer: onAddServer,
                onShowSettings: onShowSettings
            )
            .id(ObjectIdentifier(viewModel))
        }
    }
}

/// iPhone/iPad counterpart of tvOS's persistent profile-entry gate.
struct PlozziOSProfileAccessGateView: View {
    let appModel: PlozziOSAppModel
    let profile: Profile?
    let onCancel: () -> Void

    @Environment(\.themePalette) private var palette
    @Environment(\.pinProfileTransition) private var profileTransition
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expectsTwoPINs: Bool
    @State private var retainedStep: Step?

    private enum Step: Equatable {
        case parental(ParentalSwitchRequest)
        case profile(ParentalSwitchRequest)
        case plex(PlexHomeUsersModel.PlexPINRequest)
    }

    private static func pendingStep(_ app: PlozziOSAppModel) -> Step? {
        if let request = app.parentalSwitch { return .parental(request) }
        if let request = app.lockedSwitch { return .profile(request) }
        return app.plexHomeUsers.pendingPlexPINRequest.map(Step.plex)
    }

    private var displayedStep: Step? {
        let pending = Self.pendingStep(appModel)
        // Keep the entered local PIN in place until Plex actually needs another
        // PIN, rather than replacing it with a blank verification page.
        if case .profile = retainedStep, case .plex = pending,
           appModel.plexHomeUsers.plexPINEntryAvailability == .checking {
            return retainedStep
        }
        return pending ?? retainedStep
    }

    init(appModel: PlozziOSAppModel, profile: Profile? = nil, onCancel: @escaping () -> Void) {
        self.appModel = appModel
        self.profile = profile
        self.onCancel = onCancel
        _retainedStep = State(initialValue: Self.pendingStep(appModel))
        let profile = appModel.lockedSwitch?.target
        _expectsTwoPINs = State(initialValue:
            profile?.isLocked == true
                && profile?.lock?.matchesPlexPIN != true
                && profile?.playsAsPINProtectedPlexUser == true
        )
    }

    var body: some View {
        ZStack {
            AppBackground(palette: palette).ignoresSafeArea()
                .opacity(profileTransition == nil ? 1 : 0)

            switch displayedStep {
            case let .parental(request):
                // First: may you leave the child's profile at all?
                ParentalPINView(
                    destination: request.target,
                    errorMessage: request.error,
                    onSubmit: { appModel.submitParentalPIN($0) },
                    onCancel: cancel
                )
                .id("parental-pin")
                .transition(profileTransition == nil ? .opacity : .identity)
            case let .profile(lockRequest):
                ProfileLockPINView(
                    profile: lockRequest.target,
                    errorMessage: lockRequest.error,
                    isSyncEnabled: SyncSetupFeatureFlag().isEnabled,
                    sequenceStep: expectsTwoPINs
                        ? .init(current: 1, total: 2)
                        : nil,
                    isSubmitting: appModel.lockedSwitch == nil,
                    onSubmit: { await appModel.submitProfileLockPIN($0) },
                    onCancel: cancel
                )
                .id("profile-pin")
                .transition(profileTransition == nil ? .opacity : .identity)
            case let .plex(request):
                PlozziOSPlexPINView(
                    model: appModel.plexHomeUsers,
                    request: request,
                    profile: profile,
                    sequenceStep: expectsTwoPINs
                        ? .init(current: 2, total: 2)
                        : nil,
                    dismissOnSuccess: false,
                    onCancel: onCancel
                )
                .id("plex-pin")
                .transition(profileTransition == nil ? .opacity : .identity)
            case nil:
                EmptyView()
            }
        }
        .disabled(Self.pendingStep(appModel) == nil)
        .onChange(of: displayedStep, initial: true) { _, step in
            if let step { retainedStep = step }
        }
        .animation(
            reduceMotion ? nil : .easeInOut(duration: 0.25),
            value: profileTransition != nil ? [] : [
                    appModel.parentalSwitch?.target.id, appModel.lockedSwitch?.target.id,
                    appModel.plexHomeUsers.pendingPlexPINRequest?.id]
        )
    }

    private func cancel() {
        onCancel()
        if appModel.parentalSwitch != nil {
            appModel.cancelParentalSwitch()
        } else if appModel.lockedSwitch != nil {
            appModel.cancelProfileLockPrompt()
        } else {
            appModel.plexHomeUsers.cancelPlexPIN()
        }
    }
}
#endif
