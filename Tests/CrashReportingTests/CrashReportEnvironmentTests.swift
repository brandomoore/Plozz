import XCTest
import CoreModels
@testable import CrashReporting

/// Covers automatic build-channel tagging and the reporter lifecycle.
final class CrashReportEnvironmentTests: XCTestCase {
    // MARK: - Context

    func testContextUsesTheSuppliedBuildChannel() {
        let context = CrashReportContext.make(
            bundleIdentifier: "com.thatcube.Plozz",
            version: "2026.8.26",
            build: "3322",
            providers: ["Plex"],
            environment: "testflight"
        )
        XCTAssertEqual(context.environment, "testflight")
    }

    /// The release name is what separates a per-branch sideload from the real app
    /// in Sentry, so it must keep carrying the bundle id.
    func testReleaseNameIdentifiesTheBundle() {
        let context = CrashReportContext.make(
            bundleIdentifier: "com.thatcube.Plozz.my-branch",
            version: "2026.8.26",
            build: "3322",
            providers: [],
            environment: "debug"
        )
        XCTAssertEqual(context.releaseName, "com.thatcube.Plozz.my-branch@2026.8.26+3322")
        XCTAssertEqual(context.build, "3322")
    }

    func testScreenCategoryNeverIncludesLibraryIdentityOrFreeFormContext() {
        XCTAssertEqual(CrashReportScreen(context: "library:server-id#Movies"), .library)
        XCTAssertEqual(CrashReportScreen(context: "allLibraries"), .allLibraries)
        XCTAssertEqual(CrashReportScreen(context: "detail"), .detail)
        XCTAssertEqual(CrashReportScreen(context: "Watching a private title"), .unknown)
    }

    // MARK: - Reporter lifecycle

    private final class ConsentStore: CrashReportingSettingsStoring, @unchecked Sendable {
        var value: CrashReportingSettings?
        init(_ value: CrashReportingSettings?) { self.value = value }
        func load() -> CrashReportingSettings { value ?? .default }
        func loadStored() -> CrashReportingSettings? { value }
        func save(_ settings: CrashReportingSettings) { value = settings }
    }

    @MainActor
    func testNewAndLegacyInstallsNeverStartReporterBeforeConsent() {
        for previous: CrashReportingSettings? in [nil, .init(isEnabled: true), .init(isEnabled: false)] {
            let consent = CrashReportingSettingsModel(store: ConsentStore(previous))
            let spy = SpyReporter()
            let controller = CrashReportingController(reporter: spy, isConfigured: true)
            for channel in ["debug", "testflight", "production"] {
                controller.apply(enabled: consent.isEnabled, context: context(channel))
            }
            XCTAssertTrue(spy.starts.isEmpty)
            consent.isEnabled = false
            controller.apply(enabled: consent.isEnabled, context: context("testflight"))
            XCTAssertTrue(spy.starts.isEmpty)
            consent.isEnabled = true
            controller.apply(enabled: consent.isEnabled, context: context("testflight"))
            XCTAssertEqual(spy.starts, ["testflight"])
            consent.isEnabled = false
            controller.apply(enabled: consent.isEnabled, context: context("testflight"))
            XCTAssertEqual(spy.stops, 1)
        }
    }

    @MainActor
    private final class SpyReporter: CrashReporter {
        var isActive = false
        var starts: [String] = []
        var updates: [String] = []
        var screens: [CrashReportScreen] = []
        var stops = 0

        func start(context: CrashReportContext) {
            isActive = true
            starts.append(context.environment)
        }
        func update(context: CrashReportContext) { updates.append(context.environment) }
        func setScreen(_ screen: CrashReportScreen) { screens.append(screen) }
        func stop() {
            isActive = false
            stops += 1
        }
    }

    @MainActor
    private func context(_ environment: String) -> CrashReportContext {
        CrashReportContext(
            releaseName: "com.thatcube.Plozz@1+1",
            version: "1",
            build: "1",
            environment: environment,
            systemVersion: "tvOS 26.6",
            deviceModel: "AppleTV14,1",
            providers: ["Plex"]
        )
    }

    @MainActor
    func testActiveReporterOnlyUpdates() {
        let spy = SpyReporter()
        let controller = CrashReportingController(reporter: spy, isConfigured: true)

        controller.apply(enabled: true, context: context("testflight"))
        controller.apply(enabled: true, context: context("testflight"))

        XCTAssertEqual(spy.starts, ["testflight"])
        XCTAssertEqual(spy.updates, ["testflight"])
        XCTAssertEqual(spy.stops, 0)
        XCTAssertEqual(spy.screens, [.startup])
    }

    @MainActor
    func testOptOutStopsAndAllowsACleanRestart() {
        let spy = SpyReporter()
        let controller = CrashReportingController(reporter: spy, isConfigured: true)

        controller.apply(enabled: true, context: context("production"))
        controller.apply(enabled: false, context: context("production"))
        XCTAssertEqual(spy.stops, 1)

        controller.apply(enabled: true, context: context("production"))
        XCTAssertEqual(spy.starts, ["production", "production"])
        XCTAssertEqual(spy.screens, [.startup, .startup])
    }

    /// A build with no DSN must stay inert no matter what consent says.
    @MainActor
    func testUnconfiguredBuildNeverStarts() {
        let spy = SpyReporter()
        let controller = CrashReportingController(reporter: spy, isConfigured: false)
        controller.apply(enabled: true, context: context("production"))
        XCTAssertTrue(spy.starts.isEmpty)
        XCTAssertFalse(spy.isActive)
        XCTAssertTrue(spy.screens.isEmpty)
    }

    @MainActor
    func testScreenChangesAreOptInAndLatestCategoryIsRestoredOnRestart() {
        let spy = SpyReporter()
        let controller = CrashReportingController(reporter: spy, isConfigured: true)

        controller.setScreen(.home)
        controller.apply(enabled: false, context: context("testflight"))
        XCTAssertTrue(spy.screens.isEmpty)
        controller.apply(enabled: true, context: context("testflight"))
        controller.setScreen(.library)
        controller.setScreen(.library)
        controller.apply(enabled: false, context: context("testflight"))
        controller.setScreen(.detail)
        controller.apply(enabled: true, context: context("testflight"))

        XCTAssertEqual(spy.screens, [.home, .library, .detail])
    }
}
