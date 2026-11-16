import CoreModels
import Foundation
import Synchronization
import XCTest
@testable import FeatureLiveTVCore

final class LiveTVGuideAutoUpdateTests: XCTestCase {
    private struct Stop: Error {}

    private actor Provider: ServerLiveTVProviding {
        var updates = 0
        var results: [Result<Date?, any Error>]
        init(_ results: [Result<Date?, any Error>]) { self.results = results }
        func liveTVAvailability() async throws -> ServerLiveTVAvailability {
            .init(status: .available, channelCount: 1, supportsGuide: true)
        }
        func liveTVChannels() async throws -> [ServerLiveTVChannel] { [] }
        func liveTVGuide(channelIDs: [String], from: Date, to: Date) async throws -> [ServerLiveTVProgramme] {
            XCTFail("Automatic updates never request listings channel by channel")
            return []
        }
        func openLiveTVChannel(id: String) async throws -> any LiveTVStreamLease { throw Stop() }
        func updateSavedLiveTVGuide() async throws -> Date? {
            updates += 1
            return try results.isEmpty ? nil : results.removeFirst().get()
        }
    }

    @MainActor
    func testUpdatesOnlyAuthorizedIPTVAccountsAndPacesItselfByTheDueDate() async {
        let now = Date(timeIntervalSince1970: 1_000)
        let iptv = Provider([.success(now.addingTimeInterval(1_800)), .failure(URLError(.timedOut)), .success(nil)])
        let server = Provider([])
        let waits = Mutex<[TimeInterval]>([])
        await LiveTVGuideAutoUpdate.run(
            accountIDs: ["iptv", "server", "signed-out"], interval: 3_600,
            resolver: { id -> LiveTVAuthorizedServerProvider? in
                if id == "iptv" { return .init(accountID: id, authorizationID: "a", kind: .iptv, provider: iptv) }
                if id == "server" {
                    return .init(accountID: id, authorizationID: "b", kind: .jellyfin, provider: server)
                }
                return nil
            },
            now: { now },
            sleep: { seconds in
                let count = waits.withLock { $0.append(seconds); return $0.count }
                if count == 4 { throw CancellationError() }
            }
        )
        // Start delay, then the due date, then a retry after a failure, then a full interval.
        XCTAssertEqual(waits.withLock { $0 }, [60, 1_800, 900, 3_600])
        let updates = await iptv.updates
        let others = await server.updates
        XCTAssertEqual(updates, 3)
        XCTAssertEqual(others, 0)
    }

    func testWaitNeverPollsFasterThanFiveMinutesOrSlowerThanTheInterval() {
        let now = Date(timeIntervalSince1970: 1_000)
        var failures = 0
        XCTAssertEqual(LiveTVGuideAutoUpdate.wait(next: now, failed: false, failures: &failures, interval: 3_600, now: now), 300)
        XCTAssertEqual(
            LiveTVGuideAutoUpdate.wait(
                next: now.addingTimeInterval(90_000), failed: false, failures: &failures, interval: 3_600, now: now
            ), 3_600
        )
        let retries = (0..<4).map { _ in
            LiveTVGuideAutoUpdate.wait(next: nil, failed: true, failures: &failures, interval: 3_600, now: now)
        }
        XCTAssertEqual(retries, [900, 1_800, 3_600, 3_600])
    }
}
