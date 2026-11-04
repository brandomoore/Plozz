import AppRuntime
import CoreModels
import FeatureAuthCore
import FeatureHomeCore
import Foundation
import ProviderJellyfin
import ProviderPlex
import XCTest

/// Opt-in protocol checks. The private broker must authorize disposable test-user
/// history and keep all credentials in memory.
final class LiveWatchProgressTests: XCTestCase {
    func testJellyfinSavedProgressAndHomeAdmission() async throws {
        try await verify(.jellyfin)
    }

    func testEmbySavedProgressAndHomeAdmission() async throws {
        try await verify(.emby)
    }

    func testPlexSavedProgressAndHomeAdmission() async throws {
        try await verify(.plex)
    }

    private struct Configuration: Decodable {
        let baseURL: URL
        let username: String
        let userID: String
        let serverID: String
        let deviceID: String
        let token: String
        let allowWatchStateWrites: Bool
    }

    private struct InvalidConfiguration: Error {}

    private struct Fixture {
        let provider: any MediaProvider
        let raw: any MediaProvider
        var rebuild: (() throws -> PlexProvider)?
    }

    private func provider(_ kind: ProviderKind) async throws -> Fixture {
        guard let input = ProcessInfo.processInfo.environment["PLOZZ_LIVE_WATCH_BROKER"] else {
            throw XCTSkip("Set PLOZZ_LIVE_WATCH_BROKER for explicitly authorized internal watch-history tests.")
        }
        guard let broker = URL(string: input), broker.scheme == "http", broker.host == "127.0.0.1",
              broker.user == nil, broker.password == nil, broker.query == nil else {
            throw InvalidConfiguration()
        }
        let (data, response) = try await URLSession.shared.data(for: URLRequest(
            url: broker.appendingPathComponent(kind.rawValue), timeoutInterval: 10
        ))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw InvalidConfiguration() }
        let config = try JSONDecoder().decode(Configuration.self, from: data)
        guard config.allowWatchStateWrites, !config.token.isEmpty,
              ["http", "https"].contains(config.baseURL.scheme),
              config.baseURL.host != nil, config.baseURL.user == nil,
              config.baseURL.password == nil, config.baseURL.query == nil else {
            throw InvalidConfiguration()
        }
        let session = UserSession(
            server: .init(id: config.serverID, name: "Internal watch verification", baseURL: config.baseURL, provider: kind),
            userID: config.userID, userName: config.username, deviceID: config.deviceID, accessToken: config.token
        )
        if kind == .plex {
            try await PlexProvider.verifyAddress(config.baseURL, serverID: config.serverID)
            let backend = InMemorySecureStore()
            let context = LocalMediaContext(
                accountID: "test-origin", profileID: UUID().uuidString,
                profileNamespace: nil, serverUserID: config.userID
            )
            let rebuild = {
                try PlexProvider(
                    session: session, localMediaContext: context,
                    durableStore: DurableLocalStateStore(secureStore: backend)
                )
            }
            return Fixture(provider: try rebuild(), raw: PlexProvider(session: session), rebuild: rebuild)
        }
        let provider = JellyfinProvider(session: session, playbackRequests: .init())
        return Fixture(provider: provider, raw: provider)
    }

    private func verify(_ kind: ProviderKind) async throws {
        let fixture = try await provider(kind)
        let provider = fixture.provider
        let writer = try XCTUnwrap(provider as? any ResumeStateWriting)
        let watched = try XCTUnwrap(provider as? any WatchStateProviding)
        let libraries = try await provider.libraries()
        let library = try XCTUnwrap(libraries.first { $0.kind == .movie && !$0.isMusic })
        let candidates = try await provider.items(in: library.id, kind: .movie, page: .init(limit: 20)).items
        let movie = try XCTUnwrap(candidates.first {
            $0.kind == .movie && !$0.isTrailer && ($0.runtime ?? 0) >= 1_200
        }, "The approved test library must expose a long movie in the bounded sample.")
        let baseline = try await provider.item(id: movie.id)
        do {
            try await watched.setPlayed(false, itemID: movie.id)
            for position in [2.0, 59, 60, 61, 90] {
                let mutation = try XCTUnwrap(WatchMutationFactory.playbackStop(
                    item: movie, position: position, watchedPercent: position / (movie.runtime ?? 1) * 100,
                    primaryAccountID: "test-origin"
                ))
                XCTAssertEqual(mutation.targets.map(\.itemID), [movie.id])
                try await writer.setResumePosition(
                    try XCTUnwrap(mutation.resumePosition), itemID: movie.id, capturedAt: mutation.capturedAt
                )
                // This Plex server drops stopped offsets <=60 seconds. Its
                // persisted feed is authoritative; client curation cannot add them.
                let expectedPosition = kind == .plex && position <= 60 ? 0 : position
                let persisted = try await readPosition(expectedPosition, itemID: movie.id, provider: provider)
                XCTAssertEqual(persisted.resumePosition ?? 0, expectedPosition, accuracy: 0.1)
                if expectedPosition > 0 {
                    XCTAssertEqual(ContinueWatchingPolicy.admits(persisted), position >= 60)
                }
                let feed = try await provider.continueWatching(limit: 100)
                let curated = HomeViewModel.reconcileContinueWatching(feed, pending: [])
                if position < 60 || expectedPosition == 0 {
                    XCTAssertFalse(curated.contains { $0.id == movie.id })
                } else {
                    XCTAssertTrue(curated.contains { $0.id == movie.id },
                                  "Eligible saved progress must reach the actual provider Home feed.")
                }
            }
            try await verifyTrailer(
                candidates: [movie] + candidates.filter { $0.id != movie.id },
                fixture: fixture, writer: writer, watched: watched
            )
            try await restore(baseline, writer: writer, watched: watched)
        } catch {
            try await restore(baseline, writer: writer, watched: watched)
            throw error
        }
        print("Live \(kind.rawValue): checked 2/59/60/61/90-second writes and actual Home-feed admission; original watched/resume state restored.")
        if kind == .plex {
            print("Live plex limitation: this server discards stopped resume offsets <=60 seconds, independently of Plozz's adaptive Home threshold.")
        }
    }

    private func readPosition(
        _ position: TimeInterval, itemID: String, provider: any MediaProvider
    ) async throws -> MediaItem {
        let deadline = ContinuousClock.now + .seconds(5)
        while true {
            let item = try await provider.item(id: itemID)
            if abs((item.resumePosition ?? 0) - position) <= 1 || ContinuousClock.now >= deadline { return item }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private func verifyTrailer(
        candidates: [MediaItem], fixture: Fixture,
        writer: any ResumeStateWriting, watched: any WatchStateProviding
    ) async throws {
        let provider = fixture.provider
        var selected: (parent: MediaItem, trailer: MediaItem)?
        for parent in candidates.prefix(5) {
            let trailers = try await provider.trailers(for: parent.id)
            if let trailer = trailers.filter({ !$0.isYouTubeTrailer && ($0.runtime ?? 0) > 20 })
                .min(by: { ($0.runtime ?? 0) < ($1.runtime ?? 0) }) {
                selected = (parent, trailer)
                break
            }
        }
        guard let (parent, trailer) = selected else {
            print("Live \(provider.kind.rawValue): no provider trailer over 20 seconds in five sampled titles; trailer server writes not exercised.")
            return
        }
        XCTAssertTrue(trailer.isTrailer)
        XCTAssertNotEqual(trailer.id, parent.id)
        let baseline = try await fixture.raw.item(id: trailer.id)
        let rawWriter = try XCTUnwrap(fixture.raw as? any ResumeStateWriting)
        let rawWatched = try XCTUnwrap(fixture.raw as? any WatchStateProviding)
        let parentBefore = try await provider.item(id: parent.id)
        do {
            let position = 15.0
            let mutation = try XCTUnwrap(WatchMutationFactory.playbackStop(
                item: trailer, position: position, watchedPercent: position / (trailer.runtime ?? 1) * 100,
                primaryAccountID: "test-origin", reportTraktProgress: true
            ))
            XCTAssertEqual(mutation.targets.map(\.itemID), [trailer.id])
            XCTAssertNil(mutation.traktProgress)
            XCTAssertFalse(mutation.expansionPending)
            try await writer.setResumePosition(
                try XCTUnwrap(mutation.resumePosition), itemID: trailer.id, capturedAt: mutation.capturedAt
            )
            let persisted = try await readPosition(position, itemID: trailer.id, provider: provider)
            XCTAssertEqual(persisted.resumePosition ?? 0, position, accuracy: 0.1)
            XCTAssertTrue(persisted.isTrailer, "A fresh provider lookup must retain trailer classification.")
            XCTAssertFalse(ContinueWatchingPolicy.admits(persisted))
            if let rebuild = fixture.rebuild {
                let raw = try await fixture.raw.item(id: trailer.id)
                XCTAssertNotEqual(raw.resumePosition, position, "This fixture must exercise the actual Plex omission.")
                let restored = try await rebuild().item(id: trailer.id)
                XCTAssertEqual(restored.resumePosition, position)
                let listed = try await rebuild().trailers(for: parent.id)
                XCTAssertEqual(listed.first { $0.id == trailer.id }?.resumePosition, position)
                print("Live plex: short trailer offset survived provider/store reconstruction despite missing native offset.")
            }
            let parentAfter = try await provider.item(id: parent.id)
            XCTAssertEqual(parentAfter.resumePosition, parentBefore.resumePosition)
            XCTAssertEqual(parentAfter.isPlayed, parentBefore.isPlayed)
            let feed = try await provider.continueWatching(limit: 100)
            XCTAssertFalse(ContinueWatchingPolicy.default.curated(feed).contains { $0.id == trailer.id })
            try await restore(baseline, writer: rawWriter, watched: rawWatched)
        } catch {
            try await restore(baseline, writer: rawWriter, watched: rawWatched)
            throw error
        }
        print("Live \(provider.kind.rawValue): checked trailer-only progress, parent isolation and Home exclusion.")
    }

    private func restore(
        _ item: MediaItem, writer: any ResumeStateWriting, watched: any WatchStateProviding
    ) async throws {
        try await watched.setPlayed(item.isPlayed, itemID: item.id)
        try await writer.setResumePosition(
            item.resumePosition ?? 0, itemID: item.id, capturedAt: item.lastPlayedAt ?? Date()
        )
    }
}
