import XCTest
@testable import CoreModels

@MainActor
final class CrashReportingConsentDefaultTests: XCTestCase {
    /// In-memory store whose persisted value we control precisely, so we can
    /// exercise the "unset" vs "explicit choice" branches without UserDefaults.
    private final class MemoryStore: CrashReportingSettingsStoring, @unchecked Sendable {
        private var stored: CrashReportingSettings?
        init(stored: CrashReportingSettings?) { self.stored = stored }
        func load() -> CrashReportingSettings { stored ?? .default }
        func loadStored() -> CrashReportingSettings? { stored }
        func save(_ settings: CrashReportingSettings) { stored = settings }
    }

    func testNewInstallRequiresConsentAndStartsDisabled() {
        let model = CrashReportingSettingsModel(store: MemoryStore(stored: nil))
        XCTAssertTrue(model.needsConsent)
        XCTAssertFalse(model.isEnabled)
    }

    func testEveryLegacyPreferenceRequiresANewChoice() throws {
        for enabled in [false, true] {
            let data = Data("{\"isEnabled\":\(enabled)}".utf8)
            let legacy = try JSONDecoder().decode(CrashReportingSettings.self, from: data)
            let store = MemoryStore(stored: legacy)
            let model = CrashReportingSettingsModel(store: store)
            XCTAssertTrue(model.needsConsent)
            XCTAssertFalse(model.isEnabled, "Legacy beta defaults cannot authorize reporting.")
            XCTAssertEqual(store.loadStored(), legacy, "Merely opening the prompt is not a choice.")
        }
    }

    func testDefaultIsNotPersistedUntilUserChoosesSomething() {
        let store = MemoryStore(stored: nil)
        _ = CrashReportingSettingsModel(store: store)
        XCTAssertNil(store.loadStored())
    }

    func testEitherChoicePersistsAndDoesNotAskAgainAfterRelaunch() {
        for enabled in [false, true] {
            let store = MemoryStore(stored: nil)
            let model = CrashReportingSettingsModel(store: store)
            model.isEnabled = enabled
            XCTAssertEqual(model.isEnabled, enabled)
            XCTAssertFalse(model.needsConsent)
            XCTAssertEqual(store.loadStored(), CrashReportingSettings(
                isEnabled: enabled,
                consentVersion: CrashReportingSettings.currentConsentVersion
            ))

            let relaunched = CrashReportingSettingsModel(store: store)
            XCTAssertFalse(relaunched.needsConsent)
            XCTAssertEqual(relaunched.isEnabled, enabled)
        }
    }

    func testSettingsCanWithdrawAndRestoreConsentWithoutAnotherStartupPrompt() {
        let store = MemoryStore(stored: nil)
        let model = CrashReportingSettingsModel(store: store)
        for enabled in [true, false, true] {
            model.isEnabled = enabled
            let restored = CrashReportingSettingsModel(store: store)
            XCTAssertEqual(restored.isEnabled, enabled)
            XCTAssertFalse(restored.needsConsent)
        }
    }

    func testUnknownConsentVersionsFailClosed() {
        for version in [0, CrashReportingSettings.currentConsentVersion + 1] {
            let model = CrashReportingSettingsModel(store: MemoryStore(stored: .init(
                isEnabled: true, consentVersion: version
            )))
            XCTAssertFalse(model.isEnabled)
            XCTAssertTrue(model.needsConsent)
        }
    }

    func testConsentRoundTripsThroughDeviceStore() throws {
        let name = "CrashReportingConsentDefaultTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = CrashReportingSettingsStore(defaults: defaults)
        let model = CrashReportingSettingsModel(store: store)
        model.isEnabled = false
        let restored = CrashReportingSettingsModel(
            store: CrashReportingSettingsStore(defaults: defaults)
        )
        XCTAssertFalse(restored.isEnabled)
        XCTAssertFalse(restored.needsConsent)
    }

    func testBetaChannelsReportBeta() {
        XCTAssertTrue(AppReleaseChannel.debug.isBeta)
        XCTAssertTrue(AppReleaseChannel.testflight.isBeta)
        XCTAssertFalse(AppReleaseChannel.production.isBeta)
    }

    func testCrashReportEnvironmentMatchesDistributionChannel() {
        XCTAssertEqual(AppReleaseChannel.debug.crashReportEnvironment, "debug")
        XCTAssertEqual(AppReleaseChannel.testflight.crashReportEnvironment, "testflight")
        XCTAssertEqual(AppReleaseChannel.production.crashReportEnvironment, "production")
    }

    func testPromotingTheSameArchiveChangesBetaGatesNotConsent() throws {
        let tester = try XCTUnwrap(InstallChannel(archive: .testflight, receipt: "sandboxReceipt").resolved)
        let storeInstall = try XCTUnwrap(InstallChannel(archive: .testflight, receipt: "receipt").resolved)
        XCTAssertTrue(tester.isBeta)
        XCTAssertFalse(storeInstall.isBeta)
        XCTAssertEqual(storeInstall.crashReportEnvironment, "production")

        for enabled in [false, true] {
            let store = MemoryStore(stored: nil)
            CrashReportingSettingsModel(store: store).isEnabled = enabled
            let promoted = CrashReportingSettingsModel(store: store)
            XCTAssertEqual(promoted.isEnabled, enabled)
            XCTAssertFalse(promoted.needsConsent)
            XCTAssertEqual(tester.isBeta && promoted.isEnabled, enabled)
            XCTAssertFalse(storeInstall.isBeta && promoted.isEnabled)
        }
    }

    func testReceiptlessArchivesUseVerifiedInstallNotBuildLane() {
        for archive in [AppReleaseChannel.testflight, .production] {
            for verified in [AppReleaseChannel.testflight, .production] {
                let install = InstallChannel(archive: archive, receipt: nil)
                XCTAssertNil(install.resolved)
                install.finish(verifiedChannel: verified)
                XCTAssertEqual(install.resolved, verified)
                install.finish(verifiedChannel: nil)
                XCTAssertEqual(install.resolved, verified)
            }
        }
    }

    func testUnavailableInstallEvidenceFailsClosedEvenIfSandboxReplyArrivesLate() {
        let install = InstallChannel(archive: .testflight, receipt: "unrecognized")
        install.finish(verifiedChannel: nil)
        install.finish(verifiedChannel: .testflight)
        XCTAssertEqual(install.resolved, .production)
        XCTAssertEqual(InstallChannel(archive: nil, receipt: nil).resolved, .production)
    }

    func testBakedChannelIsParsedCaseInsensitively() {
        XCTAssertEqual(AppReleaseChannel.baked("testflight"), .testflight)
        XCTAssertEqual(AppReleaseChannel.baked("TestFlight"), .testflight)
        XCTAssertEqual(AppReleaseChannel.baked("  production \n"), .production)
        XCTAssertEqual(AppReleaseChannel.baked("debug"), .debug)
    }

    /// A local build leaves the setting empty, and a project generated without
    /// the bake leaves the literal `$(PLOZZ_RELEASE_CHANNEL)` behind. Neither is
    /// an answer, so both must fall through to runtime detection rather than
    /// being mistaken for a channel name.
    func testAbsentOrUnresolvedBakeYieldsNoAnswer() {
        XCTAssertNil(AppReleaseChannel.baked(nil))
        XCTAssertNil(AppReleaseChannel.baked(""))
        XCTAssertNil(AppReleaseChannel.baked("   "))
        XCTAssertNil(AppReleaseChannel.baked("$(PLOZZ_RELEASE_CHANNEL)"))
        XCTAssertNil(AppReleaseChannel.baked("nonsense"))
    }

    func testLegacySettingsWithoutTheRetiredMarkerStillDecode() throws {
        let legacy = Data(#"{"isEnabled":false}"#.utf8)
        let decoded = try JSONDecoder().decode(CrashReportingSettings.self, from: legacy)
        XCTAssertFalse(decoded.isEnabled, "an explicit opt-out must survive the migration")
        XCTAssertNil(decoded.consentVersion)
    }

    func testLegacyTestingMarkerIsIgnoredWithoutLosingConsent() throws {
        let legacy = Data(#"{"isEnabled":true,"isMaintainerDevice":true}"#.utf8)
        let decoded = try JSONDecoder().decode(CrashReportingSettings.self, from: legacy)
        XCTAssertTrue(decoded.isEnabled)
        XCTAssertNil(decoded.consentVersion)
    }
}
