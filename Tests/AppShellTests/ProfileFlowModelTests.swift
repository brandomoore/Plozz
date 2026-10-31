import XCTest
import CoreModels
import FeatureAuth
import FeatureMusic
@testable import AppRuntime
@testable import AppShell

/// Unit tests for ``ProfileFlowModel`` — the profile-flow + household facet split
/// out of ``AppState``. Cover the picker-state machine (request / cancel / launch
/// picker / new-profile appearance) deterministically. The full switch/save/remove and
/// household-membership orchestration stays covered end-to-end by ServerToggleTests,
/// which now exercises it through `state.profileFlow.*`.
@MainActor
final class ProfileFlowModelTests: XCTestCase {

    private func makeDefaults() -> UserDefaults {
        let suite = "ProfileFlowModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func makeModel() -> (ProfileFlowModel, ProfilesModel) {
        let store = AccountStore(secureStore: InMemorySecureStore())
        let profiles = ProfilesModel(store: ProfileStore(defaults: makeDefaults()))
        let hub = AccountsProvidersModel(
            accountStore: store,
            registry: ProviderRegistry(),
            profilesModel: profiles
        )
        let plex = PlexHomeUsersModel(
            accountsProviders: hub,
            profilesModel: profiles,
            switchProfile: { _ in }
        )
        let settings = ProfileSettingsModel(namespace: profiles.activeNamespace)
        let model = ProfileFlowModel(
            profilesModel: profiles,
            accountsProviders: hub,
            plexHomeUsers: plex,
            profileSettings: settings,
            audioController: AudioPlaybackController(),
            updateTrackersForActiveProfile: {},
            discardWatchReconciler: { _ in }
        )
        return (model, profiles)
    }

    func testRequestAndCancelSelectionTogglePickerState() {
        let (model, _) = makeModel()
        XCTAssertFalse(model.isChoosingProfile)

        model.requestProfileSelection()
        XCTAssertTrue(model.isChoosingProfile)
        XCTAssertTrue(model.isProfileSelectionCancelable)

        model.cancelProfileSelection()
        XCTAssertFalse(model.isChoosingProfile)
    }

    func testPickerSettingsReturnsToCurrentProfileWithoutReactivatingIt() {
        let (model, profiles) = makeModel()
        let selection = profiles.selectionGeneration
        model.requestProfileSelection()
        model.requestSettingsFromProfileSelection()
        XCTAssertFalse(model.isChoosingProfile)
        XCTAssertEqual(model.pendingSettingsProfileID, profiles.activeProfileID)
        XCTAssertEqual(profiles.selectionGeneration, selection)
        model.consumeSettingsEntry(for: profiles.activeProfileID)
        XCTAssertNil(model.pendingSettingsProfileID)
    }

    func testStartupSettingsRequiresProfilePINAndCancellationDropsIntent() async {
        let (model, profiles) = makeModel()
        var active = profiles.activeProfile
        active.replaceLock(with: ProfileLock.make(pin: "2468", iterations: 1))
        profiles.update(active)
        model.prepareLaunchPicker()
        model.requestSettingsFromProfileSelection()
        XCTAssertTrue(model.isChoosingProfile)
        XCTAssertEqual(model.pendingLockedProfile?.id, active.id)
        XCTAssertNil(model.pendingSettingsProfileID)
        let rejected = await model.submitProfileLockPIN("1111")
        XCTAssertFalse(rejected)
        XCTAssertNil(model.pendingSettingsProfileID)
        model.cancelProfileLockPrompt()
        model.switchProfile(to: active.id)
        let accepted = await model.submitProfileLockPIN("2468")
        XCTAssertTrue(accepted)
        XCTAssertNil(model.pendingSettingsProfileID, "Cancelling Settings must not reroute a later ordinary profile selection.")

        model.forgetUnlock(for: active.id)
        model.prepareLaunchPicker()
        model.requestSettingsFromProfileSelection()
        let settingsAccepted = await model.submitProfileLockPIN("2468")
        XCTAssertTrue(settingsAccepted)
        XCTAssertFalse(model.isChoosingProfile)
        XCTAssertEqual(model.pendingSettingsProfileID, active.id)
    }

    func testForegroundSettingsRequiresFreshPINAndPreservesCurrentProfile() async throws {
        let env = try makeEnv()
        var profile = env.profiles.activeProfile
        profile.lock = Self.lock(pin: "4821")
        env.profiles.update(profile)
        env.profiles.noteProfileUnlocked(profile.id)
        let generation = env.profiles.selectionGeneration
        env.flow.lockForForegroundIfNeeded()
        env.flow.requestSettingsFromProfileSelection()
        XCTAssertEqual(env.flow.pendingLockedProfile?.id, profile.id)
        XCTAssertNil(env.flow.pendingSettingsProfileID)
        env.flow.cancelProfileSelection()
        XCTAssertTrue(env.flow.isChoosingProfile)
        XCTAssertTrue(env.flow.isForegroundLocked)
        XCTAssertFalse(env.flow.canFinishForegroundUnlock)

        let accepted = await env.flow.submitProfileLockPIN("4821")
        XCTAssertTrue(accepted)
        XCTAssertEqual(env.flow.pendingSettingsProfileID, profile.id)
        XCTAssertTrue(env.flow.canFinishForegroundUnlock)
        env.flow.finishForegroundUnlockIfReady()
        XCTAssertFalse(env.flow.isForegroundLocked)
        XCTAssertEqual(env.profiles.selectionGeneration, generation)
        env.flow.consumeSettingsEntry(for: profile.id)
        XCTAssertNil(env.flow.pendingSettingsProfileID)
    }

    func testForegroundSettingsIntentExpiresOnAnotherDeparture() async throws {
        let env = try makeEnv()
        var profile = env.profiles.activeProfile
        profile.lock = Self.lock(pin: "4821")
        env.profiles.update(profile)
        env.profiles.noteProfileUnlocked(profile.id)
        env.flow.lockForForegroundIfNeeded()
        env.flow.requestSettingsFromProfileSelection()
        let accepted = await env.flow.submitProfileLockPIN("4821")
        XCTAssertTrue(accepted)
        env.flow.finishForegroundUnlockIfReady()
        XCTAssertEqual(env.flow.pendingSettingsProfileID, profile.id)

        env.flow.lockForForegroundIfNeeded()
        XCTAssertNil(env.flow.pendingSettingsProfileID)
        env.flow.switchProfile(to: profile.id)
        let acceptedAgain = await env.flow.submitProfileLockPIN("4821")
        XCTAssertTrue(acceptedAgain)
        XCTAssertTrue(env.flow.canFinishForegroundUnlock)
        XCTAssertNil(env.flow.pendingSettingsProfileID, "An ordinary return must not reopen an expired Settings request.")
    }

    func testSettingsIntentCannotCrossProfileSwitchOrParentalFallThrough() {
        let (model, profiles) = makeModel()
        let parent = profiles.activeProfile
        var child = profiles.add(name: "Child")
        child.replaceKidsProfile(with: true)
        profiles.update(child)
        profiles.setParentalPIN(ParentalPIN.make(pin: "1357", iterations: 1))
        XCTAssertTrue(model.enforceLockOnActiveProfile(leaving: child))
        model.requestSettingsFromProfileSelection()
        XCTAssertEqual(model.pendingParentalSwitch?.id, parent.id)
        XCTAssertNil(model.pendingSettingsProfileID)
        XCTAssertFalse(model.submitParentalPIN("0000"))
        XCTAssertTrue(model.isChoosingProfile)
        XCTAssertTrue(model.submitParentalPIN("1357"))
        XCTAssertEqual(model.pendingSettingsProfileID, parent.id)
        model.switchProfile(to: child.id)
        XCTAssertNil(model.pendingSettingsProfileID)
    }

    func testImportedOnboardingSelectionKeepsExistingLocksAndCompletesOnlyAfterActivation() async {
        let (model, profiles) = makeModel()
        let original = profiles.activeProfileID
        var target = profiles.add(name: "Imported", isAwaitingSetup: true)
        target.replaceLock(with: ProfileLock.make(pin: "2468", iterations: 1))
        profiles.update(target)
        var activated = 0
        model.switchProfileForPlexOnboarding(to: target.id) { activated += 1 }
        XCTAssertEqual(profiles.activeProfileID, original)
        XCTAssertEqual(model.pendingLockedProfile?.id, target.id)
        XCTAssertEqual(activated, 0)
        model.cancelProfileLockPrompt()
        XCTAssertEqual(profiles.activeProfileID, original)
        XCTAssertEqual(activated, 0)
        model.switchProfileForPlexOnboarding(to: target.id) { activated += 1 }
        let accepted = await model.submitProfileLockPIN("2468")
        XCTAssertTrue(accepted)
        XCTAssertEqual(profiles.activeProfileID, target.id)
        XCTAssertEqual(activated, 1)
        XCTAssertNil(model.pendingSetupProfile, "The already-open onboarding flow owns its continuation.")
    }

    func testOnboardingSpendsLinkedProfilePINImmediatelyWithoutAskingAgain() async throws {
        let env = try makeEnv(accounts: [("plex", .plex)])
        var target = env.profiles.add(
            name: "Imported", activeAccountIDs: ["plex"],
            plexHomeUserBindings: ["plex": .init(
                homeUserID: "parent", name: "Parent", requiresPIN: true, pinRequirementVerified: true
            )],
            isAwaitingSetup: true
        )
        target.replaceLock(with: ProfileLock.make(pin: "2468", matchesPlexPIN: true, iterations: 1))
        env.profiles.update(target)
        let authenticated = expectation(description: "Linked PIN authenticates exactly once")
        authenticated.assertForOverFulfill = true
        env.plex.plexHomeUsersFetch = { _, _ in
            XCTFail("The just-entered linked PIN should go directly to authentication.")
            return []
        }
        env.plex.plexHomeUserSwitch = { _, pin, _, _ in
            XCTAssertEqual(pin, "2468")
            authenticated.fulfill()
            return "parent-cloud"
        }
        env.plex.plexServerTokenResolve = { _, _, _ in "parent-server" }
        var activated = false
        env.flow.switchProfileForPlexOnboarding(to: target.id) { activated = true }
        let accepted = await env.flow.submitProfileLockPIN("2468")
        XCTAssertTrue(accepted)
        XCTAssertTrue(activated)
        await env.plex.waitForPlexPINRequirementCheck()
        XCTAssertNil(env.plex.pendingPlexPINRequest)
        XCTAssertEqual(env.plex.resolvedToken(for: "plex"), "parent-server")
        env.plex.ensurePlexIdentityForActiveProfile()
        XCTAssertNil(env.plex.pendingPlexPINRequest)
        await fulfillment(of: [authenticated], timeout: 2)
    }

    func testOnboardingRetargetsAnAlreadyRunningSetupWithoutCompletingItsPreviousOwner() {
        let (model, profiles) = makeModel()
        let previous = profiles.add(name: "Previous", isAwaitingSetup: true)
        model.switchProfile(to: previous.id)
        XCTAssertEqual(model.pendingSetupProfile?.id, previous.id)
        let selected = profiles.add(name: "Imported", isAwaitingSetup: true)
        model.switchProfileForPlexOnboarding(to: selected.id) {}
        XCTAssertEqual(model.pendingSetupProfile?.id, selected.id)
        XCTAssertEqual(profiles.activeProfileID, selected.id)
        model.completeLibrariesInsideSetup(for: previous.id)
        XCTAssertTrue(profiles.profiles.first { $0.id == previous.id }?.needsSetup == true)
        model.completeLibrariesInsideSetup(for: selected.id)
        XCTAssertTrue(profiles.profiles.first { $0.id == previous.id }?.needsSetup == true)
        XCTAssertFalse(profiles.activeProfile.needsSetup)
    }

    func testImportedProfileResumesAppearanceIfOnlyItsLibrariesWereCompleted() {
        let (model, profiles) = makeModel()
        let imported = profiles.add(name: "Imported", isAwaitingSetup: true)
        model.switchProfile(to: imported.id)
        model.completeLibrariesInsideSetup(for: imported.id)
        XCTAssertFalse(profiles.activeProfile.needsSetup)
        model.finishSetupFlow()
        XCTAssertTrue(model.hasResumableSetup)
        model.resumeSetupIfNeeded()
        XCTAssertTrue(model.isPickingAppearanceForNewProfile)
        model.completeAppearanceSetup(for: imported.id)
        XCTAssertFalse(model.hasResumableSetup)
    }

    func testPrepareLaunchPickerHiddenForSingleProfile() {
        let (model, _) = makeModel()
        // A brand-new household has one (default) profile → no launch picker,
        // and the launch picker is always mandatory (not cancelable).
        model.prepareLaunchPicker()
        XCTAssertFalse(model.isChoosingProfile)
        XCTAssertFalse(model.isProfileSelectionCancelable)
    }

    func testProfileRemovalInvokesDurableAliasCleanup() {
        let store = AccountStore(secureStore: InMemorySecureStore())
        let profiles = ProfilesModel(store: ProfileStore(defaults: makeDefaults()))
        let removed = profiles.add(name: "Removed", avatarSymbol: "person", colorIndex: 1)
        let hub = AccountsProvidersModel(
            accountStore: store,
            registry: ProviderRegistry(),
            profilesModel: profiles
        )
        let plex = PlexHomeUsersModel(
            accountsProviders: hub,
            profilesModel: profiles,
            switchProfile: { _ in }
        )
        var removedAliasProfileID: String?
        let model = ProfileFlowModel(
            profilesModel: profiles,
            accountsProviders: hub,
            plexHomeUsers: plex,
            profileSettings: ProfileSettingsModel(namespace: profiles.activeNamespace),
            audioController: AudioPlaybackController(),
            updateTrackersForActiveProfile: {},
            discardWatchReconciler: { _ in },
            removeMediaAliases: { removedAliasProfileID = $0 }
        )

        model.removeProfile(id: removed.id)

        XCTAssertEqual(removedAliasProfileID, removed.id)
        XCTAssertFalse(profiles.profiles.contains { $0.id == removed.id })
    }

    func testPrepareLaunchPickerShownWithMultipleProfiles() {
        let (model, profiles) = makeModel()
        _ = profiles.add(name: "Second", avatarSymbol: "person", colorIndex: 1)

        model.prepareLaunchPicker()
        XCTAssertTrue(model.isChoosingProfile)
        XCTAssertFalse(model.isProfileSelectionCancelable)
    }

    func testFinishPickingAppearanceForNewProfileNoOpsWhenNotPicking() {
        let (model, _) = makeModel()
        XCTAssertFalse(model.finishPickingAppearanceForNewProfile())
        XCTAssertFalse(model.isPickingAppearanceForNewProfile)
    }

    func testDismissPickerClearsChoosingState() {
        let (model, _) = makeModel()
        model.requestProfileSelection()
        XCTAssertTrue(model.isChoosingProfile)
        model.dismissPicker()
        XCTAssertFalse(model.isChoosingProfile)
    }

    // MARK: Orchestration (removeProfile / setAccount / switchProfile) unit coverage

    private struct Env {
        let flow: ProfileFlowModel
        let profiles: ProfilesModel
        let hub: AccountsProvidersModel
        let plex: PlexHomeUsersModel
        let store: AccountStore
    }

    @MainActor
    private final class ForegroundPINProbe {
        var submitted: [String?] = []
        var started: XCTestExpectation?
        var continuation: CheckedContinuation<String, Never>?

        func authenticate(_ pin: String?) async throws -> String {
            submitted.append(pin)
            guard pin == "4821" else { throw AppError.unauthorized }
            guard let started else { return "parent-cloud" }
            started.fulfill()
            return await withCheckedContinuation { continuation = $0 }
        }
    }

    private func account(id: String, provider: ProviderKind) -> Account {
        Account(
            id: id,
            server: MediaServer(
                id: "srv-\(id)",
                name: id,
                baseURL: URL(string: "https://\(id).example.com")!,
                provider: provider
            ),
            userID: "user-\(id)",
            userName: "User \(id)",
            deviceID: "device"
        )
    }

    private func makeEnv(
        accounts: [(String, ProviderKind)] = [],
        updateTrackers: @escaping @MainActor () async -> Void = {},
        activateWatchlist: @escaping @MainActor () -> Void = {},
        discardReconciler: @escaping @MainActor (String) -> Void = { _ in }
    ) throws -> Env {
        let store = AccountStore(secureStore: InMemorySecureStore())
        for (id, prov) in accounts {
            try store.add(account(id: id, provider: prov), token: "admin-\(id)")
        }
        let profiles = ProfilesModel(store: ProfileStore(defaults: makeDefaults()))
        let hub = AccountsProvidersModel(
            accountStore: store,
            registry: ProviderRegistry(),
            profilesModel: profiles
        )
        let plex = PlexHomeUsersModel(
            accountsProviders: hub,
            profilesModel: profiles,
            switchProfile: { _ in }
        )
        let settings = ProfileSettingsModel(namespace: profiles.activeNamespace)
        let flow = ProfileFlowModel(
            profilesModel: profiles,
            accountsProviders: hub,
            plexHomeUsers: plex,
            profileSettings: settings,
            audioController: AudioPlaybackController(),
            updateTrackersForActiveProfile: updateTrackers,
            discardWatchReconciler: discardReconciler,
            activateUniversalWatchlist: activateWatchlist
        )
        return Env(flow: flow, profiles: profiles, hub: hub, plex: plex, store: store)
    }

    private func drainMainActor(_ iterations: Int = 200) async {
        for _ in 0..<iterations { await Task.yield() }
    }

    func testForegroundLocalUnlockRetainsProfileAndDoesNotRescopeServices() async throws {
        var trackerUpdates = 0
        var watchlistActivations = 0
        let env = try makeEnv(
            updateTrackers: { trackerUpdates += 1 },
            activateWatchlist: { watchlistActivations += 1 }
        )
        var profile = env.profiles.activeProfile
        profile.lock = Self.lock(pin: "4821")
        env.profiles.update(profile)
        env.profiles.noteProfileUnlocked(profile.id)
        let generation = env.profiles.selectionGeneration

        env.flow.requestProfileSelection()
        XCTAssertTrue(env.flow.isProfileSelectionCancelable)
        env.flow.lockForForegroundIfNeeded()
        XCTAssertTrue(env.flow.isForegroundLocked)
        XCTAssertTrue(env.flow.isChoosingProfile)
        XCTAssertFalse(env.flow.isProfileSelectionCancelable)
        XCTAssertTrue(env.flow.activeProfileAwaitsUnlock)
        env.flow.requestProfileSelection()
        env.flow.cancelProfileSelection()
        env.flow.finishForegroundUnlockIfReady()
        XCTAssertTrue(env.flow.isForegroundLocked)
        XCTAssertTrue(env.flow.isChoosingProfile)

        env.flow.switchProfile(to: profile.id)
        XCTAssertEqual(env.flow.pendingLockedProfile?.id, profile.id)
        let rejected = await env.flow.submitProfileLockPIN("0000")
        XCTAssertFalse(rejected)
        XCTAssertNotNil(env.flow.profileLockError)
        XCTAssertFalse(env.flow.canFinishForegroundUnlock)
        let accepted = await env.flow.submitProfileLockPIN("4821")
        XCTAssertTrue(accepted)
        XCTAssertTrue(env.flow.canFinishForegroundUnlock)
        env.flow.finishForegroundUnlockIfReady()
        await drainMainActor()
        XCTAssertFalse(env.flow.isForegroundLocked)
        XCTAssertEqual(env.profiles.activeProfileID, profile.id)
        XCTAssertEqual(env.profiles.selectionGeneration, generation)
        XCTAssertEqual(trackerUpdates, 0)
        XCTAssertEqual(watchlistActivations, 0)
    }

    func testForegroundCancelAndAnotherBackgroundRequireFreshLocalProof() async throws {
        let env = try makeEnv()
        var profile = env.profiles.activeProfile
        profile.lock = Self.lock(pin: "4821")
        env.profiles.update(profile)
        env.profiles.noteProfileUnlocked(profile.id)
        env.flow.lockForForegroundIfNeeded()
        env.flow.switchProfile(to: profile.id)
        env.flow.cancelForegroundProfileSelection()
        XCTAssertTrue(env.flow.isChoosingProfile)
        XCTAssertTrue(env.flow.isForegroundLocked)
        XCTAssertNil(env.flow.pendingLockedProfile)

        env.flow.switchProfile(to: profile.id)
        let accepted = await env.flow.submitProfileLockPIN("4821")
        XCTAssertTrue(accepted)
        env.flow.lockForForegroundIfNeeded()
        XCTAssertFalse(env.flow.canFinishForegroundUnlock)
        XCTAssertTrue(env.flow.isChoosingProfile)
        XCTAssertFalse(env.profiles.isProfileUnlocked(profile.id))
        env.flow.switchProfile(to: profile.id)
        XCTAssertNotNil(env.flow.pendingLockedProfile)
    }

    func testForegroundDifferentProfileUsesNormalRescope() async throws {
        var trackerUpdates = 0
        let env = try makeEnv(updateTrackers: { trackerUpdates += 1 })
        var profile = env.profiles.activeProfile
        profile.lock = Self.lock(pin: "4821")
        env.profiles.update(profile)
        env.profiles.noteProfileUnlocked(profile.id)
        let other = env.profiles.add(name: "Other viewer")
        env.flow.lockForForegroundIfNeeded()
        env.flow.switchProfile(to: other.id)
        env.flow.finishForegroundUnlockIfReady()
        await drainMainActor()
        XCTAssertFalse(env.flow.isForegroundLocked)
        XCTAssertEqual(env.profiles.activeProfileID, other.id)
        XCTAssertFalse(env.profiles.isProfileUnlocked(profile.id))
        XCTAssertEqual(trackerUpdates, 1)
    }

    func testReturnDefaultUsesConfiguredPINButDisabledPlexSourceDoesNotAskForItsPIN() throws {
        let env = try makeEnv(accounts: [("plex", .plex), ("jellyfin", .jellyfin)])
        env.flow.lockForForegroundIfNeeded()
        XCTAssertFalse(env.flow.isForegroundLocked)
        let profile = env.profiles.activeProfile.settingHomeUserBinding(
            .init(homeUserID: "parent", name: "Parent", requiresPIN: true), forPlexAccount: "plex"
        )
        env.profiles.update(profile)
        env.profiles.setActiveAccountIDs(["jellyfin"], for: profile.id)
        env.hub.reloadAccounts()
        env.flow.lockForForegroundIfNeeded()
        XCTAssertTrue(env.flow.isForegroundLocked, "Any configured profile PIN requires selection on every return.")
        env.flow.switchProfile(to: profile.id)
        XCTAssertNil(env.plex.pendingPlexPINRequest, "Disabled sources still do not participate in authentication.")
        XCTAssertTrue(env.flow.canFinishForegroundUnlock)
    }

    func testUnprotectedHouseholdUsesPickerAfterDelayWithoutRescopingSameProfile() throws {
        var updates = 0
        let env = try makeEnv(updateTrackers: { updates += 1 })
        let profileID = env.profiles.activeProfileID
        _ = env.profiles.add(name: "Other viewer")
        XCTAssertEqual(env.flow.foregroundReturnDelay, 300)
        let generation = env.profiles.selectionGeneration
        env.flow.lockForForegroundIfNeeded()
        XCTAssertTrue(env.flow.isForegroundLocked)
        XCTAssertTrue(env.flow.isChoosingProfile)
        env.flow.cancelProfileSelection()
        XCTAssertTrue(env.flow.isChoosingProfile)
        env.flow.switchProfile(to: profileID)
        XCTAssertNil(env.flow.pendingLockedProfile)
        XCTAssertTrue(env.flow.canFinishForegroundUnlock)
        env.flow.finishForegroundUnlockIfReady()
        XCTAssertFalse(env.flow.isForegroundLocked)
        XCTAssertEqual(env.profiles.selectionGeneration, generation)
        XCTAssertEqual(updates, 0)
    }

    func testReturnDefaultsUpdateWhenProfilesAndPINsChange() throws {
        let env = try makeEnv()
        XCTAssertNil(env.flow.foregroundReturnDelay)
        let other = env.profiles.add(name: "Other viewer")
        XCTAssertEqual(env.flow.foregroundReturnDelay, 300)
        var profile = env.profiles.activeProfile
        profile.lock = Self.lock(pin: "4821")
        env.profiles.update(profile)
        XCTAssertEqual(env.flow.foregroundReturnDelay, 0)
        env.flow.switchProfile(to: other.id)
        XCTAssertEqual(env.flow.foregroundReturnDelay, 0, "A different profile's PIN still requires selection on return.")
        env.flow.switchProfile(to: profile.id)
        XCTAssertEqual(env.flow.pendingLockedProfile?.id, profile.id)
        XCTAssertEqual(env.profiles.activeProfileID, other.id)
        profile.lock = nil
        env.profiles.update(profile)
        XCTAssertEqual(env.flow.foregroundReturnDelay, 300)
    }

    func testForegroundPlexRechecksPINWithoutDiscardingSameViewerIdentity() async throws {
        let env = try makeEnv(accounts: [("plex", .plex)])
        env.hub.reloadAccounts()
        let probe = ForegroundPINProbe()
        env.plex.plexHomeUsersFetch = { _, _ in
            [PlexHomeUser(id: "parent", name: "Parent", requiresPIN: true)]
        }
        env.plex.plexHomeUserSwitch = { _, pin, _, _ in
            try await probe.authenticate(pin)
        }
        env.plex.plexServerTokenResolve = { _, _, _ in "parent-server" }
        env.profiles.update(env.profiles.activeProfile.settingHomeUserBinding(
            .init(homeUserID: "parent", name: "Parent", requiresPIN: true), forPlexAccount: "plex"
        ))
        env.plex.ensurePlexIdentityForActiveProfile()
        await env.plex.waitForPlexPINRequirementCheck()
        env.plex.submitPlexPIN("4821")
        await env.plex.waitForPlexPINRequirementCheck()
        XCTAssertNil(env.plex.pendingPlexPINRequest)
        let generation = env.plex.plexIdentityGeneration
        let profileID = env.profiles.activeProfileID

        env.flow.lockForForegroundIfNeeded()
        XCTAssertTrue(env.flow.isForegroundLocked)
        env.flow.switchProfile(to: profileID)
        await env.plex.waitForPlexPINRequirementCheck()
        XCTAssertNotNil(env.plex.pendingPlexPINRequest)
        XCTAssertFalse(env.flow.canFinishForegroundUnlock)
        XCTAssertEqual(env.plex.resolvedToken(for: "plex"), "parent-server")
        XCTAssertEqual(env.plex.plexIdentityGeneration, generation)
        XCTAssertEqual(probe.submitted.count, 1, "Old credentials must not re-prove PIN access.")

        env.flow.cancelForegroundProfileSelection()
        XCTAssertTrue(env.flow.isChoosingProfile)
        XCTAssertNil(env.plex.pendingPlexPINRequest)
        env.flow.switchProfile(to: profileID)
        await env.plex.waitForPlexPINRequirementCheck()
        env.plex.submitPlexPIN("0000")
        await env.plex.waitForPlexPINRequirementCheck()
        XCTAssertNotNil(env.plex.pendingPlexPINRequest)
        XCTAssertFalse(env.flow.canFinishForegroundUnlock)
        env.plex.submitPlexPIN("4821")
        await env.plex.waitForPlexPINRequirementCheck()
        XCTAssertTrue(env.flow.canFinishForegroundUnlock)
        env.flow.finishForegroundUnlockIfReady()
        XCTAssertFalse(env.flow.isForegroundLocked)
        XCTAssertEqual(env.plex.plexIdentityGeneration, generation)
        XCTAssertEqual(env.profiles.activeProfileID, profileID)
    }

    func testForegroundLinkedPINIsSpentOnceAndCanceledPlexResultCannotUnlock() async throws {
        let env = try makeEnv(accounts: [("plex", .plex)])
        env.hub.reloadAccounts()
        var profile = env.profiles.activeProfile.settingHomeUserBinding(
            .init(homeUserID: "parent", name: "Parent", requiresPIN: true), forPlexAccount: "plex"
        )
        profile.lock = ProfileLock.make(pin: "4821", matchesPlexPIN: true, iterations: 1)
        env.profiles.update(profile)
        env.profiles.noteProfileUnlocked(profile.id)
        env.plex.plexHomeUsersFetch = { _, _ in
            [PlexHomeUser(id: "parent", name: "Parent", requiresPIN: true)]
        }
        let probe = ForegroundPINProbe()
        let started = expectation(description: "Plex verification started")
        probe.started = started
        env.plex.plexHomeUserSwitch = { _, pin, _, _ in
            try await probe.authenticate(pin)
        }
        env.plex.plexServerTokenResolve = { _, _, _ in "parent-server" }
        env.flow.lockForForegroundIfNeeded()
        env.flow.switchProfile(to: profile.id)
        let accepted = await env.flow.submitProfileLockPIN("4821")
        XCTAssertTrue(accepted)
        await fulfillment(of: [started], timeout: 2)
        XCTAssertFalse(env.flow.canFinishForegroundUnlock)
        env.flow.cancelForegroundProfileSelection()
        probe.continuation?.resume(returning: "parent-cloud")
        await drainMainActor()
        XCTAssertEqual(probe.submitted, ["4821"])
        XCTAssertTrue(env.flow.isForegroundLocked)
        XCTAssertTrue(env.flow.isChoosingProfile)
        XCTAssertFalse(env.profiles.isProfileUnlocked(profile.id))
        XCTAssertNil(env.plex.resolvedToken(for: "plex"))
        env.flow.switchProfile(to: profile.id)
        XCTAssertNotNil(env.flow.pendingLockedProfile)
    }

    /// Installs a live unprotected Plex Home-user override for the ACTIVE profile on
    /// `accountID`, so a later re-scope has an override to drop.
    private func installActiveOverride(_ env: Env, accountID: String) async {
        env.plex.plexHomeUsersFetch = { _, _ in
            [PlexHomeUser(id: "hu-\(accountID)", name: "HU", requiresPIN: false)]
        }
        env.plex.plexHomeUserSwitch = { uuid, _, _, _ in "acct-\(uuid)" }
        env.plex.plexServerTokenResolve = { _, _, _ in "override-\(accountID)" }
        env.profiles.update(env.profiles.activeProfile.settingHomeUserBinding(
            .init(homeUserID: "hu-\(accountID)", name: "HU", requiresPIN: false), forPlexAccount: accountID
        ))
        env.plex.ensurePlexIdentityForActiveProfile()
        await drainMainActor()
    }

    /// Regression for the fix: removing the ACTIVE profile must re-apply the
    /// FALLBACK's Plex identity (ensurePlexIdentityForActiveProfile). The removed
    /// profile held a Home-user token override the fallback doesn't want, so after
    /// removal that override must be dropped (proving ensure ran) — without the fix
    /// it would linger on the fallback until the next explicit switch.
    func testRemoveActiveProfileReAppliesFallbackPlexIdentity() async throws {
        let env = try makeEnv(accounts: [("a", .plex)])
        env.store.setActiveAccountIDs(["a"])
        let fallbackID = env.profiles.activeProfileID          // the default profile
        let second = env.profiles.add(name: "Second")
        env.profiles.select(second.id)
        env.hub.reloadAccounts()

        await installActiveOverride(env, accountID: "a")
        XCTAssertEqual(env.plex.resolvedToken(for: "a"), "override-a")

        env.flow.removeProfile(id: second.id)

        // Fallback selected AND its (binding-less) identity re-applied → the removed
        // profile's stale override is gone (resolvedToken falls back to the admin token).
        XCTAssertEqual(env.profiles.activeProfileID, fallbackID)
        XCTAssertEqual(env.plex.resolvedToken(for: "a"), "admin-a")
    }

    /// Removing a NON-active profile must not re-scope the active one: no tracker
    /// re-point, active profile + its settings unchanged, only the target is gone.
    func testRemoveNonActiveProfileDoesNotReScope() throws {
        var trackerReScopes = 0
        let env = try makeEnv(updateTrackers: { trackerReScopes += 1 })
        let activeID = env.profiles.activeProfileID
        let other = env.profiles.add(name: "Other")   // not selected → non-active

        env.flow.removeProfile(id: other.id)

        XCTAssertEqual(env.profiles.activeProfileID, activeID, "active profile unchanged")
        XCTAssertFalse(env.profiles.profiles.contains { $0.id == other.id }, "target removed")
        XCTAssertEqual(trackerReScopes, 0, "non-active removal must not re-scope trackers")
    }

    /// The documented anti-stale logic in `setAccount(_:includedInActiveProfile:)`:
    /// it mutates the RESOLVED active set, not the raw stored set. With a stale
    /// stored set (all stored ids gone → reload fell back to the global set),
    /// toggling a visible account OFF must actually remove it — not no-op on the
    /// stale set and then re-expand to every account on the next reload.
    func testSetAccountTogglesResolvedSetNotStaleStoredSet() throws {
        let env = try makeEnv(accounts: [("a", .jellyfin), ("b", .jellyfin)])
        env.store.setActiveAccountIDs(["a", "b"])                       // global = {a,b}
        // Stored set is entirely stale (references a since-removed account), so
        // reloadAccounts resolves via the global-set fallback to {a,b}.
        env.profiles.setActiveAccountIDs(["stale-removed"], for: env.profiles.activeProfileID)
        env.hub.reloadAccounts()
        XCTAssertTrue(env.flow.isAccountIncludedInActiveProfile("a"))
        XCTAssertTrue(env.flow.isAccountIncludedInActiveProfile("b"))

        env.flow.setAccount("a", includedInActiveProfile: false)

        // Toggling "a" off must stick (operated on the resolved {a,b}); a stored-set
        // implementation would no-op then re-expand to {a,b}, leaving "a" ON.
        XCTAssertFalse(env.flow.isAccountIncludedInActiveProfile("a"))
        XCTAssertTrue(env.flow.isAccountIncludedInActiveProfile("b"))
    }

    /// switchProfile runs the full re-scope: selects the target, re-points trackers,
    /// dismisses the picker, and re-applies the target's Plex identity (dropping the
    /// previous profile's override since the target has no binding).
    ///
    /// The tracker re-point is now awaited rather than fired and forgotten, so the
    /// assertion yields first — see
    /// `testWatchlistIsNotActivatedUntilTrackersArePointedAtTheNewProfile` for why
    /// that ordering matters.
    func testSwitchProfileRunsFullReScopeIncludingPlexEnsure() async throws {
        var trackerReScopes = 0
        let env = try makeEnv(accounts: [("a", .plex)], updateTrackers: { trackerReScopes += 1 })
        env.store.setActiveAccountIDs(["a"])
        let second = env.profiles.add(name: "Second")
        env.hub.reloadAccounts()

        // Install an override under the CURRENT (default) profile.
        await installActiveOverride(env, accountID: "a")
        XCTAssertEqual(env.plex.resolvedToken(for: "a"), "override-a")
        let trackersBefore = trackerReScopes

        env.flow.requestProfileSelection()      // opens the picker
        env.flow.switchProfile(to: second.id)

        XCTAssertEqual(env.profiles.activeProfileID, second.id, "target selected")
        XCTAssertFalse(env.flow.isChoosingProfile, "picker dismissed")
        // ensure ran: the previous profile's override dropped (target has no binding).
        XCTAssertEqual(env.plex.resolvedToken(for: "a"), "admin-a")

        await settle()
        XCTAssertEqual(trackerReScopes, trackersBefore + 1, "trackers re-pointed once")
    }

    /// The regression that put another profile's watchlist on disk.
    ///
    /// The universal watchlist import reads whatever credentials the trackers
    /// currently hold. When the re-point was fire-and-forget, the import could run
    /// first and pull the PREVIOUS profile's Simkl/AniList/MAL/Plex watchlist into
    /// the profile just opened — and persist it. Order is the fix, so the order is
    /// what's asserted.
    func testWatchlistIsNotActivatedUntilTrackersArePointedAtTheNewProfile() async throws {
        var events: [String] = []
        let env = try makeEnv(
            updateTrackers: {
                // Model the real thing: setActiveProfile suspends per service, and
                // those suspension points are exactly where the import used to slip in.
                await Task.yield()
                events.append("trackers")
            },
            activateWatchlist: { events.append("watchlist") }
        )
        let second = env.profiles.add(name: "Second")

        env.flow.switchProfile(to: second.id)
        await settle()

        XCTAssertEqual(events, ["trackers", "watchlist"], "trackers must be re-pointed first")
    }

    /// Switching away again before the re-point finishes must hand the import to the
    /// LATER switch — otherwise the abandoned one imports into a profile nobody is on.
    func testSupersededSwitchDoesNotActivateTheWatchlist() async throws {
        var activations = 0
        let env = try makeEnv(
            updateTrackers: { await Task.yield() },
            activateWatchlist: { activations += 1 }
        )
        let second = env.profiles.add(name: "Second")
        let third = env.profiles.add(name: "Third")

        env.flow.switchProfile(to: second.id)
        env.flow.switchProfile(to: third.id)
        await settle()

        XCTAssertEqual(env.profiles.activeProfileID, third.id)
        XCTAssertEqual(activations, 1, "only the surviving switch prepares the watchlist")
    }

    /// Lets queued MainActor work drain before asserting.
    private func settle() async {
        for _ in 0 ..< 10 { await Task.yield() }
    }
}

// MARK: - Profile Lock gate

extension ProfileFlowModelTests {

    /// Fast rounds keep the suite quick; the derivation is identical.
    private static func lock(pin: String) -> ProfileLock {
        ProfileLock.make(pin: pin, iterations: 64)!
    }

    private func addLockedProfile(
        _ profiles: ProfilesModel,
        name: String = "Dad",
        pin: String = "4821"
    ) -> Profile {
        let added = profiles.add(name: name, avatarSymbol: "star", colorIndex: 0, activeAccountIDs: [])
        var locked = added
        locked.lock = Self.lock(pin: pin)
        profiles.update(locked)
        return locked
    }

    func testSwitchingToALockedProfileRaisesThePromptInsteadOfSwitching() {
        let (model, profiles) = makeModel()
        let original = profiles.activeProfileID
        let locked = addLockedProfile(profiles)
        // `add` activates the new profile, so start from a known-unlocked one.
        model.switchProfile(to: original)
        XCTAssertNil(model.pendingLockedProfile)

        model.switchProfile(to: locked.id)
        XCTAssertEqual(model.pendingLockedProfile?.id, locked.id)
        XCTAssertEqual(profiles.activeProfileID, original, "the switch must not happen before the PIN")
    }

    func testCorrectPINCompletesTheSwitch() async {
        let (model, profiles) = makeModel()
        let original = profiles.activeProfileID
        let locked = addLockedProfile(profiles)
        model.switchProfile(to: original)

        model.switchProfile(to: locked.id)
        let accepted = await model.submitProfileLockPIN("4821")
        XCTAssertTrue(accepted)
        XCTAssertNil(model.pendingLockedProfile)
        XCTAssertEqual(profiles.activeProfileID, locked.id)
    }

    func testWrongPINKeepsThePromptUpAndDoesNotSwitch() async {
        let (model, profiles) = makeModel()
        let original = profiles.activeProfileID
        let locked = addLockedProfile(profiles)
        model.switchProfile(to: original)

        model.switchProfile(to: locked.id)
        let accepted = await model.submitProfileLockPIN("0000")
        XCTAssertFalse(accepted)
        XCTAssertNotNil(model.pendingLockedProfile)
        XCTAssertNotNil(model.profileLockError)
        XCTAssertEqual(profiles.activeProfileID, original)
    }

    func testCancellingLeavesTheActiveProfileUntouched() {
        let (model, profiles) = makeModel()
        let original = profiles.activeProfileID
        let locked = addLockedProfile(profiles)
        model.switchProfile(to: original)

        model.switchProfile(to: locked.id)
        model.cancelProfileLockPrompt()
        XCTAssertNil(model.pendingLockedProfile)
        XCTAssertEqual(profiles.activeProfileID, original)
    }

    func testSwitchingAwayRevokesLocalPINProof() async {
        let (model, profiles) = makeModel()
        let original = profiles.activeProfileID
        let locked = addLockedProfile(profiles)
        model.switchProfile(to: original)

        model.switchProfile(to: locked.id)
        let accepted = await model.submitProfileLockPIN("4821")
        XCTAssertTrue(accepted)
        model.switchProfile(to: locked.id)
        XCTAssertNil(model.pendingLockedProfile, "Remaining in the same activation preserves proof.")

        model.switchProfile(to: original)
        XCTAssertFalse(model.isUnlockedThisRun(locked.id))
        model.switchProfile(to: locked.id)
        XCTAssertEqual(model.pendingLockedProfile?.id, locked.id)
        XCTAssertEqual(profiles.activeProfileID, original)
    }

    func testChangingThePINRevokesTheRunUnlock() async {
        let (model, profiles) = makeModel()
        let original = profiles.activeProfileID
        var locked = addLockedProfile(profiles)
        model.switchProfile(to: original)

        model.switchProfile(to: locked.id)
        let accepted = await model.submitProfileLockPIN("4821")
        XCTAssertTrue(accepted)

        // Simulate Settings changing the PIN.
        locked.lock = Self.lock(pin: "9999")
        profiles.update(locked)
        model.forgetUnlock(for: locked.id)

        model.switchProfile(to: original)
        model.switchProfile(to: locked.id)
        XCTAssertEqual(model.pendingLockedProfile?.id, locked.id, "a new PIN must be proved again")
        let oldAccepted = await model.submitProfileLockPIN("4821")
        XCTAssertFalse(oldAccepted, "the old PIN must not work")
        let newAccepted = await model.submitProfileLockPIN("9999")
        XCTAssertTrue(newAccepted)
    }

    func testInvoluntarySwitchRevokesPreviouslyProvedFallback() async {
        let (model, profiles) = makeModel()
        let original = profiles.activeProfileID
        let locked = addLockedProfile(profiles)
        model.switchProfile(to: locked.id)
        let accepted = await model.submitProfileLockPIN("4821")
        XCTAssertTrue(accepted)
        profiles.select(original)
        profiles.select(locked.id)
        XCTAssertTrue(model.enforceLockOnActiveProfile())
        XCTAssertTrue(model.activeProfileAwaitsUnlock)
    }

    func testCancellationDuringVerificationCannotUnlockAReplacementPrompt() async throws {
        let (model, profiles) = makeModel()
        let original = profiles.activeProfileID
        var locked = addLockedProfile(profiles)
        locked.lock = try XCTUnwrap(ProfileLock.make(pin: "4821"))
        profiles.update(locked)
        model.switchProfile(to: original)
        model.switchProfile(to: locked.id)
        let started = expectation(description: "Verification started")
        let attempt = Task {
            started.fulfill()
            return await model.submitProfileLockPIN("4821")
        }
        await fulfillment(of: [started], timeout: 2)
        model.cancelProfileLockPrompt()
        model.switchProfile(to: locked.id)
        let accepted = await attempt.value
        XCTAssertFalse(accepted)
        XCTAssertEqual(profiles.activeProfileID, original)
        XCTAssertEqual(model.pendingLockedProfile?.id, locked.id)
        XCTAssertFalse(model.isUnlockedThisRun(locked.id))
    }

    /// Regression: deleting your own profile used to drop you straight into the
    /// fallback profile, so a child could delete theirs to get into a locked one.
    func testDeletingTheActiveProfileCannotLandInsideALockedFallback() {
        let (model, profiles) = makeModel()
        // The default profile is `profiles.first` and so is the deletion fallback.
        var fallback = profiles.activeProfile
        fallback.lock = Self.lock(pin: "4821")
        profiles.update(fallback)

        let kid = profiles.add(name: "Kid", avatarSymbol: "star", colorIndex: 1, activeAccountIDs: [])
        model.switchProfile(to: kid.id)
        XCTAssertEqual(profiles.activeProfileID, kid.id)

        model.removeProfile(id: kid.id)
        XCTAssertTrue(model.isChoosingProfile, "must land on the picker, not inside the locked fallback")
        XCTAssertFalse(model.isProfileSelectionCancelable)
    }

    /// A single locked profile still needs a launch gate without trusted sign-in.
    func testLaunchPickerIsForcedWhenTheRestoredProfileIsLocked() {
        let (model, profiles) = makeModel()
        var active = profiles.activeProfile
        active.lock = Self.lock(pin: "4821")
        profiles.update(active)

        model.prepareLaunchPicker()
        XCTAssertTrue(model.isChoosingProfile)
        XCTAssertFalse(model.isProfileSelectionCancelable)
    }

    func testEnforceLockIsANoOpForAnUnlockedActiveProfile() {
        let (model, _) = makeModel()
        XCTAssertFalse(model.enforceLockOnActiveProfile())
        XCTAssertFalse(model.isChoosingProfile)
    }
}
