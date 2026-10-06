#if DEBUG
import Foundation
import XCTest
@testable import CoreModels
@testable import FeatureLiveTVCore

@MainActor
final class LiveTVScanCatalogBindingTests: XCTestCase {
    func testLargeCatalogPreparationDoesNotBlockMainActor() async throws {
        let channels = (0..<10_000).map { scanChannel(id: "channel-\($0)") }
        let model = LiveTVPrototypeModel(channels: [])
        let coordinator = LiveTVChannelScanCoordinator(store: ScanMemoryHealthStore())
        let binding = makeBinding(model: model, coordinator: coordinator)
        binding.updateCatalog(configuration(), channels: channels)
        let start = ContinuousClock.now
        binding.setActive(true)
        let activation = start.duration(to: .now)
        XCTAssertLessThan(activation, .milliseconds(100), "Host parsing and stream hashing must not run on the main actor.")
        let deadline = ContinuousClock.now + .seconds(20)
        while coordinator.sourceIDs.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(coordinator.sourceIDs, ["source"])
        let updateStart = ContinuousClock.now
        binding.updateCatalog(configuration(), channels: channels)
        let update = updateStart.duration(to: .now)
        XCTAssertLessThan(update, .milliseconds(100), "Guide-only publications must reuse unchanged scan inputs.")
        print("SCAN_BINDING channels=10000 activation=\(activation) unchanged=\(update)")
        binding.deactivate()
    }

    func testReleasingBindingDeactivatesItsCoordinatorSynchronouslyOnMain() async {
        let model = LiveTVPrototypeModel(channels: [scanChannel()])
        let coordinator = LiveTVChannelScanCoordinator(store: ScanMemoryHealthStore())
        var binding: LiveTVScanCatalogBinding? = makeBinding(model: model, coordinator: coordinator)
        weak var releasedBinding = binding
        binding?.updateCatalog(configuration(), channels: [scanChannel()])
        binding?.setActive(true)
        await binding?.waitUntilPrepared()
        XCTAssertEqual(coordinator.sourceIDs, ["source"])

        binding = nil

        XCTAssertNil(releasedBinding)
        XCTAssertTrue(coordinator.sourceIDs.isEmpty)
    }

    func testReleasingReplacedBindingPreservesTheNewOwner() async {
        let oldModel = LiveTVPrototypeModel(channels: [scanChannel()])
        let oldCoordinator = LiveTVChannelScanCoordinator(store: ScanMemoryHealthStore())
        var old: LiveTVScanCatalogBinding? = makeBinding(model: oldModel, coordinator: oldCoordinator)
        old?.updateCatalog(configuration(), channels: [scanChannel()])
        old?.setActive(true)
        await old?.waitUntilPrepared()
        let newModel = LiveTVPrototypeModel(channels: [scanChannel()])
        let newCoordinator = LiveTVChannelScanCoordinator(store: ScanMemoryHealthStore())
        let new = makeBinding(model: newModel, coordinator: newCoordinator)
        new.updateCatalog(configuration(), channels: [scanChannel()])
        new.setActive(true)
        await new.waitUntilPrepared()

        old = nil

        XCTAssertTrue(oldCoordinator.sourceIDs.isEmpty)
        XCTAssertEqual(newCoordinator.sourceIDs, ["source"])
        new.retry()
        XCTAssertEqual(newCoordinator.sourceIDs, ["source"])
    }

    func testNewPresentationRevokesOldScanAndRejectsItsLateHealthWrite() async throws {
        let store = ScanMemoryHealthStore()
        let probe = ScanSuspendedProbe()
        let oldModel = LiveTVPrototypeModel(channels: [scanChannel()])
        let oldCoordinator = LiveTVChannelScanCoordinator(store: store, probe: probe)
        let oldBinding = makeBinding(model: oldModel, coordinator: oldCoordinator)
        oldBinding.updateCatalog(configuration(), channels: [scanChannel()])
        oldBinding.setActive(true)
        await oldBinding.waitUntilPrepared()
        XCTAssertTrue(oldCoordinator.start(sourceID: "source"))
        await probe.waitForStart()

        let newModel = LiveTVPrototypeModel(channels: [scanChannel()])
        let newCoordinator = LiveTVChannelScanCoordinator(store: store)
        let newBinding = makeBinding(model: newModel, coordinator: newCoordinator)
        newBinding.updateCatalog(configuration(), channels: [scanChannel()])
        newBinding.setActive(true)
        await newBinding.waitUntilPrepared()
        XCTAssertTrue(oldCoordinator.sourceIDs.isEmpty)
        XCTAssertEqual(newCoordinator.sourceIDs, ["source"])
        await probe.complete()
        await probe.waitForReturn()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(try store.load().isEmpty)
        XCTAssertTrue(oldCoordinator.scanHiddenChannelIDs.isEmpty)

        oldBinding.updateCatalog(configuration(), channels: [scanChannel()])
        oldBinding.setActive(true)
        oldBinding.retry()
        XCTAssertTrue(oldCoordinator.sourceIDs.isEmpty)
        XCTAssertEqual(newCoordinator.sourceIDs, ["source"])
        oldBinding.setActive(false)
        oldBinding.setActive(true)
        await oldBinding.waitUntilPrepared()
        XCTAssertEqual(oldCoordinator.sourceIDs, ["source"])
        XCTAssertTrue(newCoordinator.sourceIDs.isEmpty)
    }

    func testDifferentProfilesDoNotRevokeOneAnothersScan() async {
        let firstModel = LiveTVPrototypeModel(channels: [scanChannel()])
        let first = makeBinding(
            model: firstModel, coordinator: LiveTVChannelScanCoordinator(store: ScanMemoryHealthStore())
        )
        let secondModel = LiveTVPrototypeModel(channels: [scanChannel()])
        let second = makeBinding(
            model: secondModel, coordinator: LiveTVChannelScanCoordinator(store: ScanMemoryHealthStore()),
            profileID: "another-profile"
        )
        first.updateCatalog(configuration(), channels: [scanChannel()])
        second.updateCatalog(configuration(), channels: [scanChannel()])
        first.setActive(true)
        second.setActive(true)
        await first.waitUntilPrepared()
        await second.waitUntilPrepared()
        XCTAssertEqual(first.coordinator.sourceIDs, ["source"])
        XCTAssertEqual(second.coordinator.sourceIDs, ["source"])
    }

    func testCatalogBindsOnlyWhileActiveAndRefreshInvalidatesImmediately() async throws {
        let model = LiveTVPrototypeModel(channels: [scanChannel()])
        let coordinator = LiveTVChannelScanCoordinator(store: ScanMemoryHealthStore())
        let binding = makeBinding(model: model, coordinator: coordinator)
        binding.updateCatalog(configuration(), channels: [scanChannel()])
        XCTAssertTrue(coordinator.sourceIDs.isEmpty)
        binding.setActive(true)
        await binding.waitUntilPrepared()
        XCTAssertEqual(coordinator.sourceIDs, ["source"])
        binding.invalidate(["source"])
        XCTAssertTrue(coordinator.sourceIDs.isEmpty)
        binding.updateCatalog(configuration(), channels: [scanChannel()])
        await binding.waitUntilPrepared()
        XCTAssertEqual(coordinator.sourceIDs, ["source"])
        binding.deactivate()
        XCTAssertTrue(coordinator.sourceIDs.isEmpty)
    }

    func testScanRestorationAndDeactivationDoNotChangeManualHides() async throws {
        let channels = [scanChannel(id: "missing"), scanChannel(id: "manual")]
        let model = LiveTVPrototypeModel(channels: channels)
        model.hideChannel(channels[1])
        let transport = ScanFixtureTransport(responses: [
            "/master.m3u8": [.init(statusCode: 404)]
        ])
        let coordinator = LiveTVChannelScanCoordinator(
            store: ScanMemoryHealthStore(),
            probe: LiveTVChannelProbe(transport: transport, limits: .init(retryDelay: .zero))
        )
        let binding = makeBinding(model: model, coordinator: coordinator)
        binding.updateCatalog(configuration(), channels: channels)
        binding.setActive(true)
        await binding.waitUntilPrepared()
        XCTAssertTrue(coordinator.start(sourceID: "source"))
        await coordinator.waitUntilFinished()
        binding.synchronizeVisibility()
        XCTAssertTrue(model.visibleChannels.isEmpty)
        XCTAssertEqual(model.hiddenChannelIDs, ["manual"])
        coordinator.restore(channelID: "missing")
        binding.synchronizeVisibility()
        XCTAssertEqual(model.visibleChannels.map(\.id), ["missing"])
        binding.deactivate()
        XCTAssertEqual(model.hiddenChannelIDs, ["manual"])
        XCTAssertEqual(model.visibleChannels.map(\.id), ["missing"])
    }

    func testWrongProfileCannotBindOrStartRequests() {
        let model = LiveTVPrototypeModel(channels: [scanChannel()])
        let coordinator = LiveTVChannelScanCoordinator(store: ScanMemoryHealthStore())
        let binding = LiveTVScanCatalogBinding(
            profileID: "profile", model: model, coordinator: coordinator,
            authorization: { _ in
                LiveTVSourceAuthorization(profileID: "other", identity: "other", allowedPlaylistIDs: ["source"])
            }
        )
        binding.updateCatalog(configuration(), channels: [scanChannel()])
        binding.setActive(true)
        XCTAssertEqual(binding.issue, .sourceUnavailable)
        XCTAssertTrue(coordinator.sourceIDs.isEmpty)
        XCTAssertEqual(model.visibleChannels.map(\.id), ["channel"])
    }

    func testUnreadableHealthLeavesBrowsingAvailable() async {
        let model = LiveTVPrototypeModel(channels: [scanChannel()])
        let coordinator = LiveTVChannelScanCoordinator(store: ScanUnreadableHealthStore())
        let binding = makeBinding(model: model, coordinator: coordinator)
        binding.updateCatalog(configuration(), channels: [scanChannel()])
        binding.setActive(true)
        await binding.waitUntilPrepared()
        XCTAssertEqual(binding.issue, .healthLoadFailed)
        XCTAssertFalse(coordinator.canScan(sourceID: "source"))
        XCTAssertEqual(model.visibleChannels.map(\.id), ["channel"])
    }

    func testCatalogEditImmediatelyRevokesScanAndPublishesOnlyLatestInputs() async throws {
        let model = LiveTVPrototypeModel(channels: [])
        let coordinator = LiveTVChannelScanCoordinator(
            store: ScanMemoryHealthStore(),
            probe: LiveTVChannelProbe(
                transport: ScanFixtureTransport(responses: ["/master.m3u8": [.init(statusCode: 404)]]),
                limits: .init(retryDelay: .zero)
            )
        )
        let binding = makeBinding(model: model, coordinator: coordinator)
        binding.updateCatalog(configuration(), channels: [scanChannel(id: "old")])
        binding.setActive(true)
        await binding.waitUntilPrepared()
        XCTAssertTrue(coordinator.canScan(sourceID: "source"))
        binding.updateCatalog(configuration(), channels: [scanChannel(id: "intermediate")])
        XCTAssertFalse(coordinator.canScan(sourceID: "source"))
        XCTAssertTrue(coordinator.isPreparingCatalog)
        binding.updateCatalog(configuration(), channels: [scanChannel(id: "latest")])
        await binding.waitUntilPrepared()
        XCTAssertTrue(coordinator.canScan(sourceID: "source"))
        XCTAssertFalse(coordinator.isPreparingCatalog)
        XCTAssertTrue(coordinator.start(sourceID: "source"))
        await coordinator.waitUntilFinished()
        XCTAssertEqual(coordinator.results(sourceID: "source").map(\.id), ["latest"])
    }

    func testPreparationRechecksAuthorityAfterAwaitAndNeverStartsNetworkRequests() async {
        let model = LiveTVPrototypeModel(channels: [])
        let coordinator = LiveTVChannelScanCoordinator(store: ScanMemoryHealthStore())
        var allowed = true
        let binding = LiveTVScanCatalogBinding(
            profileID: "profile", model: model, coordinator: coordinator,
            authorization: { _ in
                LiveTVSourceAuthorization(
                    profileID: "profile", identity: allowed ? "allowed" : "revoked",
                    allowedPlaylistIDs: allowed ? ["source"] : []
                )
            }
        )
        binding.updateCatalog(configuration(), channels: [scanChannel()])
        binding.setActive(true)
        allowed = false
        await binding.waitUntilPrepared()
        XCTAssertTrue(coordinator.sourceIDs.isEmpty)
        XCTAssertFalse(coordinator.isPreparingCatalog)
        XCTAssertFalse(coordinator.isScanning)
        XCTAssertEqual(binding.issue, .sourceUnavailable)
    }

    func testInvalidationDuringPreparationCannotRestoreStaleSource() async {
        let model = LiveTVPrototypeModel(channels: [])
        let coordinator = LiveTVChannelScanCoordinator(store: ScanMemoryHealthStore())
        let binding = makeBinding(model: model, coordinator: coordinator)
        binding.updateCatalog(configuration(), channels: [scanChannel()])
        binding.setActive(true)
        XCTAssertTrue(coordinator.isPreparingCatalog)
        binding.invalidate(["source"])
        await binding.waitUntilPrepared()
        XCTAssertTrue(coordinator.sourceIDs.isEmpty)
        XCTAssertFalse(coordinator.isPreparingCatalog)
        binding.updateCatalog(configuration(), channels: [scanChannel()])
        await binding.waitUntilPrepared()
        XCTAssertEqual(coordinator.sourceIDs, ["source"])
    }

    func testSameChannelIDWithChangedCredentialsOrURLDoesNotReusePreparedPolicy() async {
        let model = LiveTVPrototypeModel(channels: [])
        let coordinator = LiveTVChannelScanCoordinator(store: ScanMemoryHealthStore())
        let binding = makeBinding(model: model, coordinator: coordinator)
        binding.updateCatalog(configuration(), channels: [scanChannel()])
        binding.setActive(true)
        await binding.waitUntilPrepared()
        for channel in [
            scanChannel(headers: ["Authorization": "fixture-only"]),
            scanChannel(url: "https://different.test/master.m3u8")
        ] {
            binding.updateCatalog(configuration(), channels: [channel])
            XCTAssertFalse(coordinator.canScan(sourceID: "source"))
            XCTAssertTrue(coordinator.isPreparingCatalog)
            await binding.waitUntilPrepared()
            XCTAssertTrue(coordinator.canScan(sourceID: "source"))
        }
    }

    func testReleasingPendingBindingCannotPublishOrRetainIt() async {
        let model = LiveTVPrototypeModel(channels: [])
        let coordinator = LiveTVChannelScanCoordinator(store: ScanMemoryHealthStore())
        var binding: LiveTVScanCatalogBinding? = makeBinding(model: model, coordinator: coordinator)
        weak var released = binding
        binding?.updateCatalog(configuration(), channels: [scanChannel()])
        binding?.setActive(true)
        binding = nil
        XCTAssertNil(released)
        XCTAssertFalse(coordinator.isPreparingCatalog)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(coordinator.sourceIDs.isEmpty)
    }

    func testNewOwnerRevokesPendingPreparationBeforeItCanBind() async {
        let oldModel = LiveTVPrototypeModel(channels: [])
        let oldCoordinator = LiveTVChannelScanCoordinator(store: ScanMemoryHealthStore())
        let old = makeBinding(model: oldModel, coordinator: oldCoordinator)
        old.updateCatalog(configuration(), channels: [scanChannel()])
        old.setActive(true)
        let newModel = LiveTVPrototypeModel(channels: [])
        let newCoordinator = LiveTVChannelScanCoordinator(store: ScanMemoryHealthStore())
        let new = makeBinding(model: newModel, coordinator: newCoordinator)
        new.updateCatalog(configuration(), channels: [scanChannel()])
        new.setActive(true)
        await new.waitUntilPrepared()
        await old.waitUntilPrepared()
        XCTAssertTrue(oldCoordinator.sourceIDs.isEmpty)
        XCTAssertFalse(oldCoordinator.isPreparingCatalog)
        XCTAssertEqual(newCoordinator.sourceIDs, ["source"])
    }

    private func makeBinding(
        model: LiveTVPrototypeModel, coordinator: LiveTVChannelScanCoordinator,
        profileID: String = "profile"
    ) -> LiveTVScanCatalogBinding {
        LiveTVScanCatalogBinding(
            profileID: profileID, model: model, coordinator: coordinator,
            authorization: { _ in
                LiveTVSourceAuthorization(profileID: profileID, identity: "allowed", allowedPlaylistIDs: ["source"])
            }
        )
    }

    private func configuration() -> LiveTVSourcesConfiguration {
        LiveTVSourcesConfiguration(playlists: [
            LiveTVPlaylistSource(
                id: "source", name: "Fixture", playlistURL: URL(string: "https://fixture.test/channels.m3u")!
            )
        ])
    }
}
#endif
