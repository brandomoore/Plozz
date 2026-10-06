#if DEBUG && canImport(SwiftUI)
import FeatureLiveTVCore
import CoreModels
import XCTest
@testable import FeatureLiveTV

@MainActor
final class LiveTVPlaylistEditorTests: XCTestCase {
    func testOptionalGuideStartsAbsentAndSavedGuidesRemainVisible() {
        XCTAssertTrue(LiveTVPlaylistEditorModel().guideAddresses.isEmpty)
        let guide = URL(string: "https://example.test/guide.xml")!
        let model = LiveTVPlaylistEditorModel(guideURLs: [guide])
        XCTAssertEqual(model.guideAddresses.map(\.address), [guide.absoluteString])
    }

    func testCheckingPlaylistAllowsNoGuideAndKeepsCredentialsInTheURL() async throws {
        let loader = PlaylistEditorLoader(channels: [LiveTVPrototypeModel().channels[0]])
        let model = LiveTVPlaylistEditorModel(loader: loader)
        model.playlistAddress = " https://example.test/channels.m3u?token=test-only "
        await model.check()

        let review = try XCTUnwrap(model.currentReview)
        XCTAssertEqual(review.channelCount, 1)
        XCTAssertEqual(review.input.name, "example.test")
        XCTAssertEqual(review.input.playlistURL.query, "token=test-only")
        XCTAssertTrue(review.input.guideURLs.isEmpty)
        var saved: LiveTVPlaylistEditorModel.ValidatedInput?
        XCTAssertTrue(model.save { saved = $0 })
        XCTAssertEqual(saved, review.input)
        let guideRequests = await loader.guideRequests
        XCTAssertEqual(guideRequests, 0)
    }

    func testInvalidSourceAddressesNeverStartANetworkRequest() async {
        let loader = PlaylistEditorLoader(channels: [])
        let model = LiveTVPlaylistEditorModel(loader: loader)
        for address in ["", "example.test/list", "file:///tmp/list.m3u", "ftp://example.test/list", "https://user:password@example.test/list"] {
            model.playlistAddress = address
            await model.check()
            XCTAssertEqual(model.issue, .invalidPlaylistAddress)
            XCTAssertFalse(model.isChecking)
        }
        model.playlistAddress = "https://example.test/list"
        model.guideAddresses.append(.init(address: "not a guide URL"))
        await model.check()
        XCTAssertEqual(model.issue, .invalidGuideAddress)
        let requests = await loader.playlistRequests
        XCTAssertEqual(requests, 0)
    }

    func testNameAndOptionalGuideCanChangeWithoutDownloadingPlaylistAgain() async throws {
        let loader = PlaylistEditorLoader(channels: [LiveTVPrototypeModel().channels[0]])
        let model = LiveTVPlaylistEditorModel(
            playlistURL: URL(string: "https://example.test/list"), loader: loader
        )
        await model.check()
        model.name = "My channels"
        model.guideAddresses.append(.init(address: "https://example.test/guide.xml.gz"))
        let review = try XCTUnwrap(model.currentReview)
        XCTAssertEqual(review.input.name, "My channels")
        XCTAssertEqual(review.input.guideURLs.count, 1)
        let requests = await loader.playlistRequests
        XCTAssertEqual(requests, 1)

        model.playlistAddress = "https://example.test/other"
        XCTAssertNil(model.currentReview)
        XCTAssertFalse(model.save { _ in XCTFail("Changed playlist must be checked again") })
        XCTAssertEqual(model.issue, .checkRequired)
    }

    func testEmptyPlaylistCannotBeSavedAsWorkingSetup() async {
        let diagnostics = IPTVSetupDiagnostics()
        let buffer = PlaylistSetupBuffer()
        diagnostics.start { buffer.append($0) }
        let model = LiveTVPlaylistEditorModel(
            playlistURL: URL(string: "https://example.test/empty"),
            setupDiagnostics: diagnostics,
            loader: PlaylistEditorLoader(channels: [])
        )
        await model.check()
        XCTAssertEqual(model.issue, .noChannels)
        XCTAssertNil(model.currentReview)
        XCTAssertFalse(model.save { _ in XCTFail("Empty playlist must not be saved") })
        XCTAssertTrue(buffer.values.contains { $0.failure?.reason == .empty && $0.entries == 0 })
    }

    func testInvalidNameAndDuplicateGuidesFailBeforeDownloading() async {
        let loader = PlaylistEditorLoader(channels: [])
        let model = LiveTVPlaylistEditorModel(
            playlistURL: URL(string: "https://example.test/list"), loader: loader
        )
        model.name = String(repeating: "x", count: 513)
        await model.check()
        XCTAssertEqual(model.issue, .invalidName)
        model.name = "Channels"
        model.guideAddresses = [
            .init(address: "https://example.test/guide.xml"),
            .init(address: "https://example.test/guide.xml")
        ]
        await model.check()
        XCTAssertEqual(model.issue, .invalidGuideList)
        let requests = await loader.playlistRequests
        XCTAssertEqual(requests, 0)
    }

    func testGuideOrderKeepsFieldIdentityAndUsesTheNewPriority() async throws {
        let model = LiveTVPlaylistEditorModel(
            playlistURL: URL(string: "https://example.test/list"),
            guideURLs: [
                URL(string: "https://example.test/first.xml")!,
                URL(string: "https://example.test/second.xml")!
            ],
            loader: PlaylistEditorLoader(channels: [LiveTVPrototypeModel().channels[0]])
        )
        await model.check()
        let originalIDs = model.guideAddresses.map(\.id)
        model.moveGuide(originalIDs[1], by: -1)
        XCTAssertEqual(model.guideAddresses.map(\.id), Array(originalIDs.reversed()))
        let review = try XCTUnwrap(model.currentReview)
        XCTAssertEqual(review.input.guideURLs.first?.lastPathComponent, "second.xml")
    }

    func testHTTPWarningCoversPlaylistAndGuideLinks() {
        let model = LiveTVPlaylistEditorModel(playlistURL: URL(string: "https://example.test/list"))
        XCTAssertFalse(model.usesUnencryptedAddresses)
        model.guideAddresses.append(.init(address: "http://example.test/guide.xml"))
        XCTAssertTrue(model.usesUnencryptedAddresses)
        model.guideAddresses[0].address = ""
        model.playlistAddress = "http://example.test/list"
        XCTAssertTrue(model.usesUnencryptedAddresses)
    }

    func testSaveFailureKeepsTheCheckedSourceAvailableForRetry() async {
        enum Failure: Error { case storage }
        let diagnostics = IPTVSetupDiagnostics()
        let buffer = PlaylistSetupBuffer()
        diagnostics.start { buffer.append($0) }
        let model = LiveTVPlaylistEditorModel(
            playlistURL: URL(string: "https://example.test/list"),
            setupDiagnostics: diagnostics,
            loader: PlaylistEditorLoader(channels: [LiveTVPrototypeModel().channels[0]])
        )
        await model.check()
        XCTAssertFalse(model.save { _ in throw Failure.storage })
        XCTAssertEqual(model.issue, .saveFailed)
        XCTAssertEqual(buffer.values.last?.failure?.reason, .storage)
        XCTAssertEqual(buffer.values.last?.stage, .persistence)
        XCTAssertNotNil(model.currentReview)
        XCTAssertTrue(model.save { _ in })
        XCTAssertNil(model.issue)
        XCTAssertEqual(buffer.values.last?.outcome, .succeeded)
    }

    func testCancelledCheckCannotPublishAReadySource() async {
        let diagnostics = IPTVSetupDiagnostics()
        let buffer = PlaylistSetupBuffer()
        diagnostics.start { buffer.append($0) }
        let loader = PlaylistEditorLoader(channels: [LiveTVPrototypeModel().channels[0]], pauses: true)
        let model = LiveTVPlaylistEditorModel(
            playlistURL: URL(string: "https://example.test/list"), setupDiagnostics: diagnostics, loader: loader
        )
        let task = Task { await model.check() }
        await loader.waitForRequest()
        model.cancelCheck()
        await loader.finishRequest()
        await task.value
        XCTAssertFalse(model.isChecking)
        XCTAssertNil(model.currentReview)
        XCTAssertNil(model.issue)
        XCTAssertEqual(buffer.values.last?.outcome, .cancelled)
        XCTAssertFalse(buffer.values.contains { $0.outcome == .failed })
    }

    private final class PlaylistSetupBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [IPTVSetupDiagnostic] = []
        var values: [IPTVSetupDiagnostic] { lock.withLock { storage } }
        func append(_ value: IPTVSetupDiagnostic) { lock.withLock { storage.append(value) } }
    }

    func testChangedAddressCannotReuseAnInFlightCheck() async {
        let loader = PlaylistEditorLoader(channels: [LiveTVPrototypeModel().channels[0]], pauses: true)
        let model = LiveTVPlaylistEditorModel(
            playlistURL: URL(string: "https://example.test/old"), loader: loader
        )
        let task = Task { await model.check() }
        await loader.waitForRequest()
        model.playlistAddress = "https://example.test/new"
        await loader.finishRequest()
        await task.value
        XCTAssertFalse(model.isChecking)
        XCTAssertNil(model.currentReview)
    }
}

private actor PlaylistEditorLoader: LiveTVSourceLoading {
    let channels: [LiveTVPrototypeChannel]
    let pauses: Bool
    private var pending: CheckedContinuation<Void, Never>?
    private var requestWaiter: CheckedContinuation<Void, Never>?
    private(set) var playlistRequests = 0
    private(set) var guideRequests = 0

    init(channels: [LiveTVPrototypeChannel], pauses: Bool = false) {
        self.channels = channels
        self.pauses = pauses
    }

    func loadPlaylist(from url: URL) async throws -> LiveTVPlaylistImport {
        playlistRequests += 1
        requestWaiter?.resume()
        requestWaiter = nil
        if pauses { await withCheckedContinuation { pending = $0 } }
        return LiveTVPlaylistImport(channels: channels, entryCount: channels.count, skippedEntryCount: 0)
    }

    func loadGuide(from url: URL, channels: [LiveTVPrototypeChannel], now: Date) async throws -> LiveTVGuideImport {
        guideRequests += 1
        throw LiveTVSourceImportError.invalidGuide
    }

    func waitForRequest() async {
        if playlistRequests == 0 { await withCheckedContinuation { requestWaiter = $0 } }
    }

    func finishRequest() {
        pending?.resume()
        pending = nil
    }
}
#endif
