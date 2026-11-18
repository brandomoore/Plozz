import CoreModels
import CoreUI
import FeatureAuth
import SwiftUI
import UIKit
import XCTest
@testable import AppRuntime

@MainActor
final class PINRequirementPresentationTests: XCTestCase {
    private enum Outcome: CaseIterable, Sendable {
        case unprotected, protected, unknown, failed, rejected
    }

    func testPINContentMountsOnlyAfterConfirmedProtection() async throws {
        try await verifyPINContent(isChangingSelection: false)
    }

    func testProposedSelectionNeverMountsPINBeforeConfirmedProtection() async throws {
        try await verifyPINContent(isChangingSelection: true)
    }

    private func verifyPINContent(isChangingSelection: Bool) async throws {
        for cachedRequirement in [false, true] {
            for outcome in Outcome.allCases {
                let (model, profiles) = try makeModel()
                if !isChangingSelection {
                    profiles.update(profiles.activeProfile.settingHomeUserBinding(
                        .init(
                            homeUserID: "viewer", name: "Viewer", requiresPIN: cachedRequirement,
                            pinRequirementVerified: true
                        ),
                        forPlexAccount: "plex"
                    ))
                }
                let responses = AsyncThrowingStream<[PlexHomeUser], Error>.makeStream()
                defer { responses.continuation.finish() }
                model.plexHomeUsersFetch = { _, _ in
                    for try await users in responses.stream { return users }
                    throw CancellationError()
                }
                model.plexHomeUserSwitch = { _, pin, _, _ in
                    XCTAssertNil(pin, "An unprotected viewer must not need another profile's PIN.")
                    if outcome == .rejected { throw AppError.unauthorized }
                    return "VIEWER-CLOUD"
                }
                model.plexServerTokenResolve = { _, _, _ in "VIEWER-SERVER" }
                if isChangingSelection {
                    model.setPlexHomeUserForActiveProfile(
                        accountID: "plex", user: PlexHomeUser(
                            id: "viewer", name: "Viewer", requiresPIN: cachedRequirement,
                            pinRequirementVerified: nil
                        )
                    )
                } else {
                    model.ensurePlexIdentityForActiveProfile()
                }

                let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
                let previous = scene.windows.first(where: \.isKeyWindow)
                let window = UIWindow(windowScene: scene)
                var pinMounts = 0
                window.rootViewController = UIHostingController(rootView:
                    PINRequirementFixture(model: model) { pinMounts += 1 }
                )
                window.makeKeyAndVisible()
                defer {
                    window.isHidden = true
                    window.rootViewController = nil
                    previous?.makeKeyAndVisible()
                }
                let checkingDeadline = ContinuousClock.now + .milliseconds(300)
                repeat {
                    window.layoutIfNeeded()
                    XCTAssertEqual(model.plexPINEntryAvailability, .checking)
                    XCTAssertEqual(pinMounts, 0, "Even a cached protected flag must not flash PIN content.")
                    try await Task.sleep(for: .milliseconds(20))
                } while ContinuousClock.now < checkingDeadline

                if outcome == .failed {
                    responses.continuation.finish(throwing: URLError(.notConnectedToInternet))
                } else {
                    responses.continuation.yield([PlexHomeUser(
                        id: "viewer", name: "Viewer", requiresPIN: outcome == .protected,
                        pinRequirementVerified: outcome != .unknown
                    )])
                }
                await model.waitForPlexPINRequirementCheck()
                let settlingDeadline = ContinuousClock.now + .milliseconds(500)
                repeat {
                    window.layoutIfNeeded()
                    if outcome != .protected {
                        XCTAssertEqual(pinMounts, 0, "PIN content must also stay absent during completion or errors.")
                        XCTAssertNotEqual(model.plexPINEntryAvailability, .available)
                    }
                    try await Task.sleep(for: .milliseconds(20))
                } while ContinuousClock.now < settlingDeadline
                if outcome == .protected {
                    XCTAssertEqual(model.plexPINEntryAvailability, .available)
                    XCTAssertGreaterThan(pinMounts, 0, "Positive control: a confirmed PIN must mount real PIN content.")
                } else if outcome == .unprotected {
                    XCTAssertNil(model.pendingPlexPINRequest)
                    XCTAssertEqual(model.discoverToken(for: "plex"), "VIEWER-CLOUD")
                } else {
                    XCTAssertEqual(model.plexPINEntryAvailability, .unavailable)
                    XCTAssertNotNil(model.pendingPlexPINRequest, "Unknown authorization must not expose the app.")
                }
                if isChangingSelection, outcome != .unprotected {
                    XCTAssertNil(profiles.activeProfile.homeUserBinding(forPlexAccount: "plex"))
                    model.cancelPlexPIN()
                    XCTAssertNil(model.pendingPlexPINRequest)
                    XCTAssertNil(profiles.activeProfile.homeUserBinding(forPlexAccount: "plex"))
                }
            }
        }
    }

    private func makeModel() throws -> (PlexHomeUsersModel, ProfilesModel) {
        let suite = "PINRequirementPresentationTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let profiles = ProfilesModel(store: ProfileStore(defaults: defaults))
        let accounts = AccountStore(secureStore: InMemorySecureStore())
        try accounts.add(Account(
            id: "plex", server: MediaServer(
                id: "server", name: "Fixture", baseURL: URL(string: "https://plex.example")!, provider: .plex
            ), userID: "owner", userName: "Owner", deviceID: "fixture"
        ), token: "FIXTURE-ADMIN")
        let hub = AccountsProvidersModel(
            accountStore: accounts, registry: ProviderRegistry(), profilesModel: profiles
        )
        hub.reloadAccounts()
        return (
            PlexHomeUsersModel(
                accountsProviders: hub, profilesModel: profiles,
                plexHomeUserTokenCache: PlexHomeUserTokenCache(store: InMemorySecureStore()),
                automaticSignInStore: AutomaticSignInStore(defaults: defaults, secureStore: InMemorySecureStore()),
                offlineSignInStore: .init(secureStore: InMemorySecureStore()),
                switchProfile: { _ in }
            ),
            profiles
        )
    }
}

private struct PINRequirementFixture: View {
    let model: PlexHomeUsersModel
    let pinMounted: () -> Void

    var body: some View {
        PINEntryScaffold(
            title: "Enter your Plex PIN",
            name: Text(verbatim: "Viewer"),
            errorMessage: model.plexPINError,
            isSubmitting: model.isSubmittingPlexPIN,
            availability: model.pendingPlexPINRequest == nil ? .checking : model.plexPINEntryAvailability,
            onRetry: { model.retryPlexPINRequirement() },
            onSubmit: { model.submitPlexPIN($0) },
            onCancel: { model.cancelPlexPIN() }
        ) {
            Image(systemName: "person.fill")
                .onAppear(perform: pinMounted)
        }
    }
}
