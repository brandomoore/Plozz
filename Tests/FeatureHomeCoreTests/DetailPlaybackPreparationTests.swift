import CoreModels
import XCTest
@testable import FeatureHomeCore

@MainActor
final class DetailPlaybackPreparationTests: XCTestCase {
    func testCandidateRequiresKnownExactFileAndUnambiguousOwnership() throws {
        var item = movie()
        item.versions = []
        XCTAssertNil(DetailPlaybackPreparationCandidate(item))
        item.versions = [.synthesized(from: item)]
        XCTAssertNil(DetailPlaybackPreparationCandidate(item))
        item = movie()
        item.locallyValidatedPlayableSource = false
        XCTAssertNil(DetailPlaybackPreparationCandidate(item))
        item = movie()
        item.sources = [
            MediaSourceRef(accountID: "account", itemID: "movie"),
            MediaSourceRef(accountID: "other", itemID: "movie")
        ]
        XCTAssertNil(DetailPlaybackPreparationCandidate(item))
        item.sources.removeFirst()
        XCTAssertNil(DetailPlaybackPreparationCandidate(item), "The current owner and one alternate are two choices")
        item.explicitSourceSelection = true
        XCTAssertNotNil(DetailPlaybackPreparationCandidate(item))
        item.versions[0] = item.versions[0].qualified(accountID: "other", itemID: item.id)
        XCTAssertNil(DetailPlaybackPreparationCandidate(item))
        item = movie()
        item.kind = .series
        XCTAssertNil(DetailPlaybackPreparationCandidate(item))
    }

    func testCandidatePositionDefaultsToZeroAndChangesItsIdentity() throws {
        var item = movie()
        let beginning = try XCTUnwrap(DetailPlaybackPreparationCandidate(item))
        XCTAssertEqual(beginning.startPosition, 0)
        item.resumePosition = 3_600.25
        let resumed = try XCTUnwrap(DetailPlaybackPreparationCandidate(item))
        XCTAssertEqual(resumed.startPosition, 3_600.25)
        XCTAssertNotEqual(beginning, resumed)
        XCTAssertEqual(Set([beginning, resumed]).count, 2)

        item.id = "f:folder/original.mkv"
        item.kind = .episode
        item.versions = []
        let physical = try XCTUnwrap(DetailPlaybackPreparationCandidate(
            item, exactFileRelativePath: "folder/original.mkv"
        ))
        XCTAssertEqual(physical.startPosition, 3_600.25)
    }

    func testInvalidPositionNeverCreatesAFileOrVersionCandidate() {
        for position in [-1, Double.nan, Double.infinity, -Double.infinity] {
            var item = movie()
            item.resumePosition = position
            XCTAssertNil(DetailPlaybackPreparationCandidate(item))
            item.id = "f:folder/original.mkv"
            item.kind = .episode
            item.versions = []
            XCTAssertNil(DetailPlaybackPreparationCandidate(
                item, exactFileRelativePath: "folder/original.mkv"
            ))
        }
    }

    func testHandoffMayChangeTimeButNotFileIdentity() throws {
        var item = movie()
        item.resumePosition = 600
        let candidate = try XCTUnwrap(DetailPlaybackPreparationCandidate(item))
        item.resumePosition = 0
        XCTAssertTrue(candidate.matchesHandoff(item))
        item.resumePosition = 1_200
        XCTAssertTrue(candidate.matchesHandoff(item))
        item.resumePosition = .nan
        XCTAssertFalse(candidate.matchesHandoff(item))
        item.resumePosition = 0
        item.id = "other"
        XCTAssertFalse(candidate.matchesHandoff(item))
    }

    func testQualifiedSelectionPreservesOriginalProviderIDAndNeverGuessesMultipleFiles() throws {
        var item = movie()
        item.versions = [
            MediaVersion(id: "folder/original.mkv").qualified(accountID: "account", itemID: "movie"),
            MediaVersion(id: "folder/other.mkv").qualified(accountID: "account", itemID: "movie")
        ]
        XCTAssertNil(DetailPlaybackPreparationCandidate(item, allowsMultipleVersions: true))
        item.explicitSourceSelection = true
        item.selectedVersionID = item.versions[0].id
        XCTAssertNil(DetailPlaybackPreparationCandidate(item))
        let candidate = try XCTUnwrap(DetailPlaybackPreparationCandidate(item, allowsMultipleVersions: true))
        XCTAssertEqual(candidate.mediaSourceID, "folder/original.mkv")
        XCTAssertEqual(candidate.accountID, "account")
        XCTAssertEqual(candidate.itemID, "movie")
        item.selectedVersionID = "missing"
        XCTAssertNil(DetailPlaybackPreparationCandidate(item, allowsMultipleVersions: true))
        item.selectedVersionID = "folder/original.mkv"
        item.versions[1] = MediaVersion(id: "folder/original.mkv").qualified(accountID: "other", itemID: "movie")
        XCTAssertNil(DetailPlaybackPreparationCandidate(item, allowsMultipleVersions: true))
    }

    func testOnlyAuthorizedHTTPNetworkShareAccountsQualify() throws {
        let revision = CredentialRevision()
        for scheme in ["https", "http", "smb", "sftp", "ftp", "nfs"] {
            let account = Account(
                id: "account",
                server: MediaServer(
                    id: "server", name: "Server",
                    baseURL: try XCTUnwrap(URL(string: "\(scheme)://example.invalid/share")),
                    provider: .mediaShare
                ),
                userID: "user", userName: "User", deviceID: "device"
            )
            let scope = DetailPlaybackPreparationScope(
                webDAVAccount: account, profileID: "profile", authorizationID: "authorization",
                credentialRevision: revision, isAuthorized: true
            )
            XCTAssertEqual(scope != nil, scheme == "http" || scheme == "https")
            XCTAssertNil(DetailPlaybackPreparationScope(
                webDAVAccount: account, profileID: "profile", authorizationID: "authorization",
                credentialRevision: revision, isAuthorized: false
            ))
            var otherProvider = account
            otherProvider.server.provider = .jellyfin
            XCTAssertNil(DetailPlaybackPreparationScope(
                webDAVAccount: otherProvider, profileID: "profile", authorizationID: "authorization",
                credentialRevision: revision, isAuthorized: true
            ))
        }
    }

    func testUnauthorizedAmbiguousAndInactivePagesDoNoWork() async throws {
        var calls = 0
        let coordinator = DetailPlaybackPreparationCoordinator(
            dwell: {}, prepare: { _, _, _ in calls += 1; return nil }
        )
        defer { coordinator.invalidate() }
        let candidate = try XCTUnwrap(DetailPlaybackPreparationCandidate(movie()))
        coordinator.update(candidate: candidate, environment: .disabled, isActive: true)
        coordinator.update(candidate: nil, environment: environment(), isActive: true)
        coordinator.update(candidate: candidate, environment: environment(), isActive: false)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(calls, 0)
    }

    func testEnvironmentUsesNarrowLocatorWithoutFullPlaybackInfoOrInventory() async throws {
        var item = movie()
        item.resumePosition = 1_234.5
        let candidate = try XCTUnwrap(DetailPlaybackPreparationCandidate(item))
        let locator = try locator()
        let provider = PreparationProvider { locator }
        var reserved: [NetworkFileLocator] = []
        var positions: [Double] = []
        let environment = DetailPlaybackPreparationEnvironment(
            scope: { [self] in scope($0) },
            provider: { _ in provider },
            reserve: { locator, position in
                reserved.append(locator)
                positions.append(position)
                return .init {}
            }
        )
        let result = try await environment.prepare(candidate, scope: scope("account"))
        XCTAssertNotNil(result)
        XCTAssertEqual(reserved, [locator])
        XCTAssertEqual(positions, [1_234.5])
        let requests = await provider.requests
        XCTAssertEqual(requests, [.init(itemID: item.id, mediaSourceID: "folder/original.mkv")])
        let inventories = await provider.inventoryRequests
        XCTAssertEqual(inventories, 0)
        let fullPlaybackCalls = await provider.fullPlaybackRequests
        XCTAssertEqual(fullPlaybackCalls, 0)
    }

    func testVersionlessShareEpisodeRequiresProviderOwnedPhysicalFileProof() async throws {
        let episode = MediaItem(
            id: "f:folder/original.mkv", title: "Episode", kind: .episode,
            seriesID: "series:show", sourceAccountID: "account"
        )
        XCTAssertTrue(episode.versions.isEmpty)
        XCTAssertNil(DetailPlaybackPreparationCandidate(episode))
        let locator = try locator()
        let provider = PreparationProvider { locator }
        var reserved: [NetworkFileLocator] = []
        let environment = DetailPlaybackPreparationEnvironment(
            scope: { [self] in scope($0) },
            exactFileRelativePath: { $0.id == episode.id ? "folder/original.mkv" : nil },
            provider: { _ in provider },
            reserve: { locator, position in
                XCTAssertEqual(position, 0)
                reserved.append(locator)
                return .init {}
            }
        )
        let candidate = try XCTUnwrap(environment.candidate(for: episode))
        XCTAssertEqual(candidate.itemID, episode.id)
        XCTAssertEqual(candidate.mediaSourceID, "folder/original.mkv")
        XCTAssertTrue(candidate.matchesHandoff(episode))
        let result = try await environment.prepare(candidate, scope: scope("account"))
        XCTAssertNotNil(result)
        XCTAssertEqual(reserved, [locator])
        let requests = await provider.requests
        XCTAssertEqual(requests, [.init(itemID: episode.id, mediaSourceID: "folder/original.mkv")])
        let inventories = await provider.inventoryRequests
        let fullPlaybackCalls = await provider.fullPlaybackRequests
        XCTAssertEqual(inventories, 0)
        XCTAssertEqual(fullPlaybackCalls, 0)

        var other = episode
        other.id = "f:folder/other.mkv"
        XCTAssertFalse(candidate.matchesHandoff(other))
        XCTAssertNil(environment.candidate(for: other))
        var logicalMovie = episode
        logicalMovie.id = "movie:logical-title"
        logicalMovie.kind = .movie
        XCTAssertNil(environment.candidate(for: logicalMovie))
        var wrongSelection = episode
        wrongSelection.selectedVersionID = "folder/other.mkv"
        XCTAssertNil(environment.candidate(for: wrongSelection))

        var syntheticPresentation = episode
        syntheticPresentation.versions = [.synthesized(from: episode)]
        XCTAssertNotNil(environment.candidate(for: syntheticPresentation))
        XCTAssertNil(DetailPlaybackPreparationCandidate(syntheticPresentation))
    }

    func testPhysicalFileProofIsNotRequestedBeforeLiveAuthorization() {
        let item = MediaItem(
            id: "f:folder/original.mkv", title: "Episode", kind: .episode, sourceAccountID: "account"
        )
        var proofCalls = 0
        let environment = DetailPlaybackPreparationEnvironment(
            scope: { _ in nil },
            exactFileRelativePath: { _ in proofCalls += 1; return "folder/original.mkv" },
            provider: { _ in nil }, reserve: { _, _ in throw CancellationError() }
        )
        XCTAssertNil(environment.candidate(for: item))
        XCTAssertEqual(proofCalls, 0)
    }

    func testUnsupportedNarrowLocatorDoesNotReserveOrFallBackToPlaybackInfo() async throws {
        let provider = PreparationProvider { nil }
        var reserved = false
        let environment = DetailPlaybackPreparationEnvironment(
            scope: { [self] in scope($0) }, provider: { _ in provider },
            reserve: { _, _ in reserved = true; return .init {} }
        )
        let candidate = try XCTUnwrap(DetailPlaybackPreparationCandidate(movie()))
        let result = try await environment.prepare(candidate, scope: scope("account"))
        XCTAssertNil(result)
        XCTAssertFalse(reserved)
        let fullPlaybackCalls = await provider.fullPlaybackRequests
        XCTAssertEqual(fullPlaybackCalls, 0)
    }

    func testEnvironmentChecksAuthorizationBeforeAndAfterProviderAwait() async throws {
        let item = movie()
        let candidate = try XCTUnwrap(DetailPlaybackPreparationCandidate(item))
        let locator = try locator()
        var authorized = false
        var reserved = false
        let provider = PreparationProvider {
            authorized = false
            return locator
        }
        let environment = DetailPlaybackPreparationEnvironment(
            scope: { [self] in authorized ? scope($0) : nil },
            provider: { _ in provider },
            reserve: { _, _ in reserved = true; return .init {} }
        )
        let denied = try await environment.prepare(candidate, scope: scope("account"))
        XCTAssertNil(denied)
        let deniedRequests = await provider.requests
        XCTAssertTrue(deniedRequests.isEmpty)
        authorized = true
        do {
            _ = try await environment.prepare(candidate, scope: scope("account"))
            XCTFail("A revoked profile cannot prepare a transport")
        } catch is CancellationError {
        }
        XCTAssertFalse(reserved)
    }

    func testEnvironmentReleasesReservationIfAuthorizationChangesDuringPrepare() async throws {
        let item = movie()
        let candidate = try XCTUnwrap(DetailPlaybackPreparationCandidate(item))
        let locator = try locator()
        let cancelled = expectation(description: "Late reservation released")
        var authorized = true
        let provider = PreparationProvider { locator }
        let environment = DetailPlaybackPreparationEnvironment(
            scope: { [self] in authorized ? scope($0) : nil },
            provider: { _ in provider },
            reserve: { _, _ in authorized = false; return .init { cancelled.fulfill() } }
        )
        let result = try await environment.prepare(candidate, scope: scope("account"))
        XCTAssertNil(result)
        await fulfillment(of: [cancelled], timeout: 1)
    }

    func testEnvironmentRejectsMismatchedFileWithoutPreparing() async throws {
        let item = movie()
        let candidate = try XCTUnwrap(DetailPlaybackPreparationCandidate(item))
        let locator = try locator(path: "folder/different.mkv")
        let provider = PreparationProvider { locator }
        var reserved = false
        let environment = DetailPlaybackPreparationEnvironment(
            scope: { [self] in scope($0) }, provider: { _ in provider },
            reserve: { _, _ in reserved = true; return .init {} }
        )
        do {
            _ = try await environment.prepare(candidate, scope: scope("account"))
            XCTFail("The locator must name the exact selected version")
        } catch let error as AppError {
            XCTAssertEqual(error, .invalidResponse)
        }
        XCTAssertFalse(reserved)
    }

    func testLeavingDuringDwellDoesNotPrepare() async throws {
        let gate = Gate()
        let started = expectation(description: "Dwell started")
        let finished = expectation(description: "Dwell finished")
        var calls = 0
        let coordinator = DetailPlaybackPreparationCoordinator(
            dwell: {
                started.fulfill()
                await gate.wait()
                finished.fulfill()
            },
            prepare: { _, _, _ in calls += 1; return nil }
        )
        coordinator.update(
            candidate: try XCTUnwrap(DetailPlaybackPreparationCandidate(movie())),
            environment: environment(), isActive: true
        )
        await fulfillment(of: [started], timeout: 1)
        coordinator.stop()
        await gate.open()
        await fulfillment(of: [finished], timeout: 1)
        XCTAssertEqual(calls, 0)
    }

    func testStaleCompletionAfterSourceSwitchCancelsOnlyItsReservation() async throws {
        let gate = Gate()
        let started = expectation(description: "First preparation started")
        let secondPrepared = expectation(description: "New source prepared")
        let staleCancelled = expectation(description: "Stale result released")
        let currentCancelled = expectation(description: "Current result released on stop")
        var calls = 0
        let coordinator = DetailPlaybackPreparationCoordinator(
            dwell: {},
            prepare: { _, _, _ in
                calls += 1
                if calls == 1 {
                    started.fulfill()
                    await gate.wait() // Deliberately ignores cancellation.
                    return .init { staleCancelled.fulfill() }
                }
                secondPrepared.fulfill()
                return .init { currentCancelled.fulfill() }
            }
        )
        let first = try XCTUnwrap(DetailPlaybackPreparationCandidate(movie()))
        coordinator.update(candidate: first, environment: environment(), isActive: true)
        await fulfillment(of: [started], timeout: 1)
        var changed = movie()
        changed.sourceAccountID = "other"
        let second = try XCTUnwrap(DetailPlaybackPreparationCandidate(changed))
        coordinator.update(candidate: second, environment: environment(), isActive: true)
        await fulfillment(of: [secondPrepared], timeout: 1)
        await gate.open()
        await fulfillment(of: [staleCancelled], timeout: 1)
        XCTAssertEqual(calls, 2)
        coordinator.stop()
        await fulfillment(of: [currentCancelled], timeout: 1)
    }

    func testAuthorizationIsRecheckedAfterAwait() async throws {
        let gate = Gate()
        let started = expectation(description: "Preparation started")
        let cancelled = expectation(description: "Revoked result cancelled")
        var authorized = true
        let environment = environment(isAuthorized: { authorized })
        let coordinator = DetailPlaybackPreparationCoordinator(
            dwell: {},
            prepare: { _, _, _ in
                started.fulfill()
                await gate.wait()
                return .init { cancelled.fulfill() }
            }
        )
        coordinator.update(
            candidate: try XCTUnwrap(DetailPlaybackPreparationCandidate(movie())),
            environment: environment, isActive: true
        )
        await fulfillment(of: [started], timeout: 1)
        authorized = false
        await gate.open()
        await fulfillment(of: [cancelled], timeout: 1)
        coordinator.invalidate()
    }

    func testProgressChangeSupersedesWorkAndCancelsLateCompletion() async throws {
        let gate = Gate()
        let started = expectation(description: "Old position started")
        let ready = expectation(description: "New position prepared")
        let staleCancelled = expectation(description: "Old position result released")
        let currentCancelled = expectation(description: "Current result released on stop")
        let currentCancellations = CancellationCounter()
        var positions: [Double] = []
        let coordinator = DetailPlaybackPreparationCoordinator(
            dwell: {},
            prepare: { candidate, _, _ in
                positions.append(candidate.startPosition)
                if positions.count == 1 {
                    started.fulfill()
                    await gate.wait()
                    return .init { staleCancelled.fulfill() }
                }
                ready.fulfill()
                return .init {
                    await currentCancellations.record()
                    currentCancelled.fulfill()
                }
            }
        )
        defer { coordinator.invalidate() }
        var item = movie()
        item.resumePosition = 100
        coordinator.update(
            candidate: try XCTUnwrap(DetailPlaybackPreparationCandidate(item)),
            environment: environment(), isActive: true
        )
        await fulfillment(of: [started], timeout: 1)
        item.resumePosition = 200
        let current = try XCTUnwrap(DetailPlaybackPreparationCandidate(item))
        coordinator.update(candidate: current, environment: environment(), isActive: true)
        await fulfillment(of: [ready], timeout: 1)
        await gate.open()
        await fulfillment(of: [staleCancelled], timeout: 1)
        coordinator.update(candidate: current, environment: environment(), isActive: true)
        XCTAssertEqual(positions, [100, 200])
        let cancellations = await currentCancellations.count
        XCTAssertEqual(cancellations, 0)
        coordinator.stop()
        await fulfillment(of: [currentCancelled], timeout: 1)
    }

    func testProgressChangeEvictsCompletedReservation() async throws {
        let firstReady = expectation(description: "First position ready")
        let secondReady = expectation(description: "Updated position ready")
        let firstCancelled = expectation(description: "First position evicted")
        let secondCancelled = expectation(description: "Updated position released")
        var positions: [Double] = []
        let coordinator = DetailPlaybackPreparationCoordinator(
            dwell: {},
            prepare: { candidate, _, _ in
                positions.append(candidate.startPosition)
                if positions.count == 1 {
                    firstReady.fulfill()
                    return .init { firstCancelled.fulfill() }
                }
                secondReady.fulfill()
                return .init { secondCancelled.fulfill() }
            }
        )
        defer { coordinator.invalidate() }
        var item = movie()
        coordinator.update(
            candidate: try XCTUnwrap(DetailPlaybackPreparationCandidate(item)),
            environment: environment(), isActive: true
        )
        await fulfillment(of: [firstReady], timeout: 1)
        item.resumePosition = 250
        coordinator.update(
            candidate: try XCTUnwrap(DetailPlaybackPreparationCandidate(item)),
            environment: environment(), isActive: true
        )
        await fulfillment(of: [firstCancelled, secondReady], timeout: 1)
        XCTAssertEqual(positions, [0, 250])
        coordinator.stop()
        await fulfillment(of: [secondCancelled], timeout: 1)
    }

    func testStartOverHandoffSurvivesDisappearanceButNotAuthorizationRevocation() async throws {
        let ready = expectation(description: "Ready")
        let cancelled = expectation(description: "Revoked handoff cancelled")
        let counter = CancellationCounter()
        let coordinator = DetailPlaybackPreparationCoordinator(
            dwell: {},
            prepare: { _, _, _ in
                ready.fulfill()
                return .init { await counter.record(); cancelled.fulfill() }
            }
        )
        var item = movie()
        item.resumePosition = 600
        let candidate = try XCTUnwrap(DetailPlaybackPreparationCandidate(item))
        coordinator.update(candidate: candidate, environment: environment(), isActive: true)
        await fulfillment(of: [ready], timeout: 1)
        var fromBeginning = item
        fromBeginning.resumePosition = 0
        coordinator.handoff(fromBeginning)
        coordinator.stop()
        coordinator.update(candidate: candidate, environment: environment(), isActive: false)
        for _ in 0..<10 { await Task.yield() }
        let cancellationsBeforeRevocation = await counter.count
        XCTAssertEqual(cancellationsBeforeRevocation, 0)
        // A live scope change must invalidate even an already-handed-off reservation.
        coordinator.update(candidate: candidate, environment: .disabled, isActive: false)
        await fulfillment(of: [cancelled], timeout: 1)
    }

    func testShellRetainsHandoffAfterPageReleaseAndRevokesItOnProfileChange() async {
        let cancelled = expectation(description: "Shell ownership revoked")
        let ownership = DetailPlaybackPreparationOwnership()
        let scope = scope("account")
        var token: PreparationLifetime? = PreparationLifetime()
        weak var retainedToken = token
        var pageReservation: DetailPlaybackPreparationReservation? = ownership.retain(
            .init { [token] in _ = token; cancelled.fulfill() }, scope: scope
        )
        token = nil
        XCTAssertNotNil(pageReservation)
        pageReservation = nil
        ownership.validate(using: environment())
        XCTAssertNotNil(retainedToken, "The shell must keep the transport handle alive during Play navigation")
        let changedProfile = DetailPlaybackPreparationEnvironment(
            scope: { [self] accountID in
                .init(
                    profileID: "other-profile", authorizationID: "authorization",
                    accountID: accountID, serverUserID: "user", credentialRevision: revision
                )
            },
            provider: { _ in nil }, reserve: { _, _ in throw CancellationError() }
        )
        ownership.validate(using: changedProfile)
        await fulfillment(of: [cancelled], timeout: 1)
    }

    func testDifferentEpisodePlayDoesNotTransferPreparedFile() async throws {
        let ready = expectation(description: "Ready")
        let cancelled = expectation(description: "Different episode invalidates")
        let coordinator = DetailPlaybackPreparationCoordinator(
            dwell: {}, prepare: { _, _, _ in ready.fulfill(); return .init { cancelled.fulfill() } }
        )
        coordinator.update(
            candidate: try XCTUnwrap(DetailPlaybackPreparationCandidate(movie())),
            environment: environment(), isActive: true
        )
        await fulfillment(of: [ready], timeout: 1)
        var other = movie()
        other.id = "other"
        coordinator.handoff(other)
        await fulfillment(of: [cancelled], timeout: 1)
    }

    private let revision = CredentialRevision()

    private func movie() -> MediaItem {
        var item = MediaItem(id: "movie", title: "Movie", kind: .movie, sourceAccountID: "account")
        item.versions = [MediaVersion(id: "folder/original.mkv")]
        return item
    }

    private func scope(_ accountID: String) -> DetailPlaybackPreparationScope {
        .init(
            profileID: "profile", authorizationID: "authorization", accountID: accountID,
            serverUserID: "user", credentialRevision: revision
        )
    }

    private func locator(path: String = "folder/original.mkv") throws -> NetworkFileLocator {
        try NetworkFileLocator(
            accountID: "account", sourceID: "share", credentialRevision: revision,
            relativePath: path,
            representation: RemoteFileRepresentation(
                size: 10_000, identity: RemoteFileIdentity(kind: .strongETag, value: "\"revision\""),
                consistency: .stronglyBound
            )
        )
    }

    private func environment(
        isAuthorized: @escaping @MainActor () -> Bool = { true }
    ) -> DetailPlaybackPreparationEnvironment {
        .init(
            scope: { [self] accountID in isAuthorized() ? scope(accountID) : nil },
            provider: { _ in nil },
            reserve: { _, _ in throw CancellationError() }
        )
    }
}

private actor Gate {
    private var isOpen = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

private actor CancellationCounter {
    private(set) var count = 0
    func record() { count += 1 }
}

private final class PreparationLifetime: @unchecked Sendable {}

private actor PreparationProvider: MediaProvider {
    struct Request: Equatable {
        let itemID: String
        let mediaSourceID: String
    }
    nonisolated let kind = ProviderKind.mediaShare
    nonisolated let session = UserSession(
        server: MediaServer(
            id: "server", name: "Server", baseURL: URL(string: "https://example.invalid")!,
            provider: .mediaShare
        ),
        userID: "user", userName: "User", deviceID: "device", accessToken: ""
    )
    private let response: @MainActor @Sendable () async throws -> NetworkFileLocator?
    private(set) var requests: [Request] = []
    private(set) var inventoryRequests = 0
    private(set) var fullPlaybackRequests = 0

    init(response: @escaping @MainActor @Sendable () async throws -> NetworkFileLocator?) {
        self.response = response
    }

    func playbackInfo(for itemID: String) async throws -> PlaybackRequest {
        fullPlaybackRequests += 1
        throw AppError.invalidResponse
    }
    func playbackInfo(
        for itemID: String, mediaSourceID: String?, forceTranscode: Bool
    ) async throws -> PlaybackRequest {
        fullPlaybackRequests += 1
        throw AppError.invalidResponse
    }
    func playbackPreparationLocator(
        for itemID: String, mediaSourceID: String
    ) async throws -> NetworkFileLocator? {
        requests.append(Request(itemID: itemID, mediaSourceID: mediaSourceID))
        return try await response()
    }
    func playbackItem(id: String) async throws -> MediaItem {
        inventoryRequests += 1
        throw AppError.notFound
    }
    func libraries() async throws -> [MediaLibrary] { [] }
    func continueWatching(limit: Int) async throws -> [MediaItem] { [] }
    func latest(limit: Int) async throws -> [MediaItem] { [] }
    func item(id: String) async throws -> MediaItem { throw AppError.notFound }
    func children(of itemID: String) async throws -> [MediaItem] { [] }
    func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        MediaPage(items: [], startIndex: 0, totalCount: 0)
    }
    func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {}
    nonisolated func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
}
