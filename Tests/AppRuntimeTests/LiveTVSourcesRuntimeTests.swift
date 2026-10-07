#if DEBUG
import CoreModels
import FeatureLiveTVCore
import Foundation
import XCTest
@testable import AppRuntime

@MainActor
final class LiveTVSourcesRuntimeTests: XCTestCase {
    func testSettingsRegistersIPTVWithoutFirstOpeningLiveTVOrRefreshingTheGuide() async throws {
        let fixture = try SourcesRuntimeFixture()
        defer { fixture.removeOwnedFiles() }
        try fixture.addIPTVChoice()
        let runtime = fixture.runtime()

        await runtime.restore()

        let source = try XCTUnwrap(fixture.store.load().servers.first)
        XCTAssertEqual(source.accountID, "iptv")
        XCTAssertEqual(source.name, "Live playlist")
        XCTAssertTrue(source.isEnabled)
        XCTAssertEqual(runtime.catalog.imports.configuration.servers, [source])
        XCTAssertNil(runtime.catalog.issue)
        XCTAssertTrue(runtime.isCurrent)
        await runtime.restore()
        let checks = await fixture.provider.checks
        let loads = await fixture.loader.loads
        XCTAssertEqual(checks, 1, "Opening an already configured source must remain cache-only.")
        XCTAssertEqual(loads, 0)
    }

    func testSettingsRetriesFailedIPTVRegistrationAndPublishesItsChannels() async throws {
        let fixture = try SourcesRuntimeFixture()
        defer { fixture.removeOwnedFiles() }
        try fixture.addIPTVChoice()
        fixture.secure.failWrites = true
        let runtime = fixture.runtime()

        await runtime.restore()
        XCTAssertEqual(runtime.catalog.issue, .enrollment(.configurationNotSaved))
        XCTAssertTrue(try fixture.store.load().servers.isEmpty)
        fixture.secure.failWrites = false
        await runtime.catalog.refresh()

        XCTAssertNil(runtime.catalog.issue)
        XCTAssertEqual(try fixture.store.load().servers.map(\.accountID), ["iptv"])
        XCTAssertEqual(runtime.catalog.catalog.channels.map(\.name), ["IPTV channel"])
    }

    func testSettingsDoesNotRestoreSuppressedOrDisabledIPTV() async throws {
        let fixture = try SourcesRuntimeFixture()
        defer { fixture.removeOwnedFiles() }
        try fixture.addIPTVChoice()
        fixture.suppressed = ["iptv"]
        let runtime = fixture.runtime()

        await runtime.restore()
        XCTAssertTrue(try fixture.store.load().servers.isEmpty)
        fixture.suppressed = []
        let disabled = LiveTVServerSource(
            id: "disabled", name: "Disabled playlist", accountID: "iptv", isEnabled: false
        )
        try fixture.store.save(.init(servers: [disabled]))
        await runtime.restore()

        XCTAssertEqual(try fixture.store.load().servers, [disabled])
        let checks = await fixture.provider.checks
        XCTAssertEqual(checks, 0)
    }

    func testLateIPTVRegistrationCannotSaveAfterProfileAccessChanges() async throws {
        let gate = SourcesRuntimeLoadGate()
        let fixture = try SourcesRuntimeFixture(providerGate: gate)
        defer { fixture.removeOwnedFiles() }
        try fixture.addIPTVChoice()
        let runtime = fixture.runtime()
        let restore = Task { await runtime.restore() }
        await gate.waitUntilStarted()

        fixture.hasAccess = false
        runtime.invalidate()
        await gate.release()
        await restore.value

        XCTAssertTrue(try fixture.store.load().servers.isEmpty)
        XCTAssertTrue(runtime.catalog.imports.configuration.servers.isEmpty)
        XCTAssertFalse(runtime.isCurrent)
    }

    func testRemovalDuringIPTVRegistrationWinsOverAutomaticEnrollment() async throws {
        let gate = SourcesRuntimeLoadGate()
        let fixture = try SourcesRuntimeFixture(providerGate: gate)
        defer { fixture.removeOwnedFiles() }
        try fixture.addIPTVChoice()
        let runtime = fixture.runtime()
        let restore = Task { await runtime.restore() }
        await gate.waitUntilStarted()

        fixture.suppressed = ["iptv"]
        await gate.release()
        await restore.value

        XCTAssertTrue(try fixture.store.load().servers.isEmpty)
        XCTAssertNil(runtime.catalog.issue)
    }

    func testPresentationStateDoesNotReadSourcesButOperationsStillRevalidateThem() async throws {
        let fixture = try SourcesRuntimeFixture()
        defer { fixture.removeOwnedFiles() }
        let runtime = fixture.runtime()
        await runtime.restore()
        let reads = fixture.secure.reads
        for _ in 0..<20 { XCTAssertTrue(runtime.isPresentationCurrent) }
        XCTAssertEqual(fixture.secure.reads, reads)

        fixture.accountIdentity = "new-account-generation"
        XCTAssertFalse(runtime.isPresentationCurrent)
        XCTAssertEqual(fixture.secure.reads, reads)
        fixture.accountIdentity = "account-generation"
        try fixture.store.save(.empty)
        XCTAssertFalse(runtime.isCurrent, "Operations must reject the obsolete durable configuration")
        runtime.invalidate()
        XCTAssertFalse(runtime.isPresentationCurrent)
    }

    func testLoaderIsSharedOnlyForTheExactProfileAndNamespace() {
        let profileID = UUID().uuidString
        let root = LiveTVCatalogStorage.loader(profileID: profileID, namespace: nil)
        XCTAssertTrue(root === LiveTVCatalogStorage.loader(profileID: profileID, namespace: nil))
        XCTAssertFalse(root === LiveTVCatalogStorage.loader(profileID: profileID, namespace: profileID))
        XCTAssertFalse(root === LiveTVCatalogStorage.loader(profileID: UUID().uuidString, namespace: nil))
        XCTAssertNil(LiveTVCatalogStorage.existingCache(profileID: profileID))
    }

    func testInitialRestoreUsesSharedCacheWithoutNetworkAndBindsScanning() async throws {
        let fixture = try SourcesRuntimeFixture()
        defer { fixture.removeOwnedFiles() }
        try await fixture.seed()
        let runtime = fixture.runtime()

        await runtime.restore()

        XCTAssertTrue(runtime.isCurrent)
        XCTAssertTrue(runtime.catalog.imports.supportsDurableCatalog)
        XCTAssertEqual(runtime.catalog.catalog.channels.map(\.name), ["Cached channel"])
        XCTAssertEqual(runtime.scanBinding.coordinator.sourceIDs, ["source"])
        let loads = await fixture.loader.loads
        XCTAssertEqual(loads, 0)
    }

    func testExplicitRefreshUpdatesRetainedCatalogAndPreservesPreferences() async throws {
        let fixture = try SourcesRuntimeFixture()
        defer { fixture.removeOwnedFiles() }
        try fixture.preferences.save(.init(favoriteIDs: ["unrelated-favorite"]))
        let runtime = fixture.runtime()
        await runtime.restore()
        let imports = runtime.catalog.imports

        await runtime.catalog.refresh()
        await runtime.scanBinding.waitUntilPrepared()

        XCTAssertTrue(imports === runtime.catalog.imports)
        XCTAssertTrue(runtime.isCurrent)
        XCTAssertEqual(runtime.catalog.catalog.channels.map(\.name), ["Refreshed channel"])
        XCTAssertEqual(runtime.scanBinding.coordinator.sourceIDs, ["source"])
        XCTAssertEqual(try fixture.preferences.load().favoriteIDs, ["unrelated-favorite"])
        let loads = await fixture.loader.loads
        XCTAssertEqual(loads, 1)
    }

    func testReappearingAfterAnEditorKeepsTheAdmissionAndImporter() async throws {
        let fixture = try SourcesRuntimeFixture()
        defer { fixture.removeOwnedFiles() }
        try await fixture.seed()
        let runtime = fixture.runtime()
        await runtime.restore()
        let imports = runtime.catalog.imports
        let channels = runtime.catalog.catalog.channels.map(\.id)

        runtime.activate()

        XCTAssertTrue(runtime.isCurrent)
        XCTAssertTrue(imports === runtime.catalog.imports)
        XCTAssertEqual(runtime.catalog.catalog.channels.map(\.id), channels)
        XCTAssertEqual(runtime.scanBinding.coordinator.sourceIDs, ["source"])
    }

    func testLeavingPresentationClearsCatalogAndStopsOldScanAdmission() async throws {
        let fixture = try SourcesRuntimeFixture()
        defer { fixture.removeOwnedFiles() }
        try await fixture.seed()
        let runtime = fixture.runtime()
        await runtime.restore()

        runtime.invalidate()

        XCTAssertFalse(runtime.isCurrent)
        XCTAssertTrue(runtime.catalog.catalog.channels.isEmpty)
        XCTAssertTrue(runtime.scanBinding.coordinator.sourceIDs.isEmpty)
        XCTAssertFalse(runtime.scanBinding.coordinator.start(sourceID: "source"))
        await runtime.catalog.refresh()
        XCTAssertEqual(runtime.catalog.issue, .authorization)
        let loads = await fixture.loader.loads
        XCTAssertEqual(loads, 0)
    }

    func testAccountGenerationFailsClosedBeforeReadmission() async throws {
        let fixture = try SourcesRuntimeFixture()
        defer { fixture.removeOwnedFiles() }
        try await fixture.seed()
        let runtime = fixture.runtime()
        await runtime.restore()

        fixture.accountIdentity = "new-account-generation"
        XCTAssertFalse(runtime.isCurrent)
        runtime.activate()
        XCTAssertTrue(runtime.scanBinding.coordinator.sourceIDs.isEmpty)
        XCTAssertTrue(runtime.catalog.catalog.channels.isEmpty)
        await runtime.restore()

        XCTAssertTrue(runtime.isCurrent)
        XCTAssertEqual(runtime.catalog.catalog.channels.count, 1)
        let loads = await fixture.loader.loads
        XCTAssertEqual(loads, 0)
    }

    func testLockedOrDifferentProfileCannotRestoreCachedChannels() async throws {
        let fixture = try SourcesRuntimeFixture()
        defer { fixture.removeOwnedFiles() }
        try await fixture.seed()
        let runtime = fixture.runtime()
        await runtime.restore()

        fixture.hasAccess = false
        runtime.activate()
        await runtime.restore()
        XCTAssertEqual(runtime.catalog.issue, .authorization)
        XCTAssertTrue(runtime.catalog.catalog.channels.isEmpty)
        XCTAssertTrue(runtime.scanBinding.coordinator.sourceIDs.isEmpty)

        fixture.hasAccess = true
        fixture.profile = Profile(id: "different-profile", name: "Other")
        await runtime.restore()
        XCTAssertEqual(runtime.catalog.issue, .authorization)
        XCTAssertTrue(runtime.catalog.catalog.channels.isEmpty)
        let loads = await fixture.loader.loads
        XCTAssertEqual(loads, 0)
    }

    func testSourceEditsAreReadFreshRatherThanUsingCapturedConfiguration() async throws {
        let fixture = try SourcesRuntimeFixture()
        defer { fixture.removeOwnedFiles() }
        try await fixture.seed()
        let runtime = fixture.runtime()
        await runtime.restore()

        try fixture.store.save(.empty)
        XCTAssertFalse(runtime.isCurrent)
        await runtime.catalog.refresh()

        XCTAssertTrue(runtime.isCurrent)
        XCTAssertTrue(runtime.catalog.catalog.channels.isEmpty)
        XCTAssertTrue(runtime.scanBinding.coordinator.sourceIDs.isEmpty)
        let loads = await fixture.loader.loads
        XCTAssertEqual(loads, 0)
    }

    func testRevokedRootNamespaceReceiptCannotRestoreThePreviouslyApprovedCache() async throws {
        let fixture = try SourcesRuntimeFixture()
        defer { fixture.removeOwnedFiles() }
        fixture.profile.isKids = true
        fixture.parentalPIN = try XCTUnwrap(ParentalPIN.make(pin: "1234", iterations: 1))
        let context = LiveTVSourceApprovalContext(
            profile: fixture.profile, parentalPIN: fixture.parentalPIN, activeAccountIDs: []
        )
        let approvals = LiveTVSourceApprovalStore(
            defaults: fixture.defaults, profileID: fixture.profile.id, namespace: nil
        )
        try approvals.approve(
            source: fixture.source, context: context,
            permit: try XCTUnwrap(context.authorize(parentalPIN: "1234"))
        )
        try await fixture.seed()
        let runtime = fixture.runtime()
        await runtime.restore()
        XCTAssertEqual(runtime.catalog.catalog.channels.count, 1)

        try approvals.revoke(sourceID: fixture.source.id)
        XCTAssertFalse(runtime.isCurrent)
        await runtime.catalog.restore()

        XCTAssertTrue(runtime.isCurrent)
        XCTAssertTrue(runtime.catalog.catalog.channels.isEmpty)
        XCTAssertTrue(runtime.scanBinding.coordinator.sourceIDs.isEmpty)
        let loads = await fixture.loader.loads
        XCTAssertEqual(loads, 0)
    }

    func testLateRefreshCannotPublishAfterPresentationRetirement() async throws {
        let gate = SourcesRuntimeLoadGate()
        let fixture = try SourcesRuntimeFixture(gate: gate)
        defer { fixture.removeOwnedFiles() }
        let runtime = fixture.runtime()
        runtime.activate()
        let refresh = Task { await runtime.catalog.refresh() }
        await gate.waitUntilStarted()

        runtime.invalidate()
        await gate.release()
        await refresh.value

        XCTAssertFalse(runtime.isCurrent)
        XCTAssertTrue(runtime.catalog.catalog.channels.isEmpty)
        XCTAssertTrue(runtime.scanBinding.coordinator.sourceIDs.isEmpty)
    }

    func testUnreadableConfigurationIsNotTreatedAsEmptySuccess() async throws {
        let fixture = try SourcesRuntimeFixture()
        defer { fixture.removeOwnedFiles() }
        fixture.secure.failReads = true
        let runtime = fixture.runtime()

        await runtime.restore()

        XCTAssertFalse(runtime.isCurrent)
        XCTAssertEqual(runtime.catalog.issue, .configuration)
        XCTAssertTrue(runtime.scanBinding.coordinator.sourceIDs.isEmpty)
        let loads = await fixture.loader.loads
        XCTAssertEqual(loads, 0)
    }
}

@MainActor
private final class SourcesRuntimeFixture {
    let domain = "LiveTVSourcesRuntimeTests-" + UUID().uuidString
    let defaults: UserDefaults
    let directory: URL
    let cache: LiveTVIndexedCache
    let secure = SourcesRuntimeSecureStore()
    let loader: SourcesRuntimeLoader
    let provider: SourcesRuntimeProvider
    let store: LiveTVSourcesStore
    let preferences: LiveTVPreferencesStore
    let source: LiveTVPlaylistSource
    var profile = Profile(id: "actual-root-owner", name: "Owner")
    var hasAccess = true
    var accountIdentity = "account-generation"
    var parentalPIN: ParentalPIN?
    var choices: [LiveTVServerChoice] = []
    var suppressed: Set<String> = []

    init(gate: SourcesRuntimeLoadGate? = nil, providerGate: SourcesRuntimeLoadGate? = nil) throws {
        loader = SourcesRuntimeLoader(gate: gate)
        provider = SourcesRuntimeProvider(gate: providerGate)
        defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        let root = try FileManager.default.url(
            for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        directory = root.appendingPathComponent(domain, isDirectory: true)
        cache = LiveTVIndexedCache(
            url: directory.appendingPathComponent("catalog.sqlite"),
            namespace: "actual-root-owner", authorizationScope: "iptv-profile-v1", secureStore: secure
        )
        store = LiveTVSourcesStore(secureStore: secure, namespace: nil)
        preferences = LiveTVPreferencesStore(defaults: defaults, namespace: nil)
        source = LiveTVPlaylistSource(
            id: "source", name: "Playlist",
            playlistURL: try XCTUnwrap(URL(string: "https://example.test/channels.m3u"))
        )
        try store.save(.init(playlists: [source]))
    }

    func runtime() -> LiveTVSourcesRuntime {
        LiveTVSourcesRuntime(
            profileID: "actual-root-owner", store: store,
            approvals: LiveTVSourceApprovalStore(
                defaults: defaults, profileID: "actual-root-owner", namespace: nil
            ),
            cache: cache, loader: loader, preferencesStore: preferences,
            scanCoordinator: LiveTVChannelScanCoordinator(
                store: LiveTVChannelHealthStore(defaults: defaults, namespace: "actual-root-owner")
            ),
            context: { [weak self] in
                guard let self, self.hasAccess else { return nil }
                return .init(
                    profile: self.profile, parentalPIN: self.parentalPIN,
                    activeAccountIDs: self.choices.map(\.id)
                )
            },
            accountAuthorizationID: { [weak self] in self?.accountIdentity ?? "" },
            serverProviderResolver: { [weak self] id in
                guard let self, self.hasAccess, self.choices.contains(where: { $0.id == id }) else { return nil }
                return .init(
                    accountID: id, authorizationID: self.accountIdentity, kind: .iptv, provider: self.provider
                )
            },
            serverChoices: { [weak self] in self?.choices ?? [] },
            suppressedAccountIDs: { [weak self] in self?.suppressed ?? [] }
        )
    }

    func addIPTVChoice() throws {
        try store.save(.empty)
        choices = [.init(id: "iptv", name: "Live playlist", userName: "IPTV", kind: .iptv)]
    }

    func seed() async throws {
        let playlist = try LiveTVPlaylistParser().parse("""
        #EXTM3U
        #EXTINF:-1 tvg-id="channel",Cached channel
        https://example.test/live.m3u8
        """)
        let resolved = try await cache.reconcile(playlist, sourceID: source.id)
        try await cache.storePlaylist(resolved.playlist, source: source, now: Date())
    }

    func removeOwnedFiles() {
        defaults.removePersistentDomain(forName: domain)
        if FileManager.default.fileExists(atPath: directory.path) {
            do { try FileManager.default.removeItem(at: directory) }
            catch { XCTFail("Could not remove this test's catalog.") }
        }
    }
}

private actor SourcesRuntimeProvider: ServerLiveTVProviding {
    let gate: SourcesRuntimeLoadGate?
    private(set) var checks = 0

    init(gate: SourcesRuntimeLoadGate?) { self.gate = gate }

    func liveTVAvailability() async throws -> ServerLiveTVAvailability {
        checks += 1
        await gate?.suspend()
        return .init(status: .available, channelCount: 1)
    }

    func liveTVChannels() async throws -> [ServerLiveTVChannel] {
        [.init(id: "channel", name: "IPTV channel")]
    }

    func liveTVGuide(channelIDs: [String], from: Date, to: Date) async throws -> [ServerLiveTVProgramme] { [] }
    func openLiveTVChannel(id: String) async throws -> any LiveTVStreamLease {
        throw ServerLiveTVError.tunerUnavailable
    }
}

private actor SourcesRuntimeLoader: LiveTVSourceLoading {
    private(set) var loads = 0
    let gate: SourcesRuntimeLoadGate?

    init(gate: SourcesRuntimeLoadGate? = nil) { self.gate = gate }

    func loadPlaylist(from url: URL) async throws -> LiveTVPlaylistImport {
        loads += 1
        await gate?.suspend()
        return try LiveTVPlaylistParser(baseURL: url).parse("""
        #EXTM3U
        #EXTINF:-1 tvg-id="channel",Refreshed channel
        https://example.test/live.m3u8
        """)
    }

    func loadGuide(
        from url: URL, channels: [LiveTVPrototypeChannel], now: Date
    ) async throws -> LiveTVGuideImport {
        throw LiveTVSourceImportError.invalidResponse
    }
}

private actor SourcesRuntimeLoadGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var observers: [CheckedContinuation<Void, Never>] = []
    private var started = false

    func suspend() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            started = true
            observers.forEach { $0.resume() }
            observers.removeAll()
        }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { observers.append($0) }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private final class SourcesRuntimeSecureStore: SecureStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    private var readFailure = false
    private var writeFailure = false
    private var readCount = 0
    var reads: Int { lock.withLock { readCount } }
    var failReads: Bool {
        get { lock.withLock { readFailure } }
        set { lock.withLock { readFailure = newValue } }
    }
    var failWrites: Bool {
        get { lock.withLock { writeFailure } }
        set { lock.withLock { writeFailure = newValue } }
    }

    func readString(for key: String) throws -> String? {
        try lock.withLock {
            readCount += 1
            if readFailure { throw LiveTVSourcesStoreError.loadFailed }
            return values[key]
        }
    }
    func string(for key: String) -> String? { try? readString(for: key) }
    func setString(_ value: String, for key: String) throws {
        try lock.withLock {
            if writeFailure { throw LiveTVSourcesStoreError.saveFailed }
            values[key] = value
        }
    }
    func removeValue(for key: String) throws { _ = lock.withLock { values.removeValue(forKey: key) } }
}
#endif
