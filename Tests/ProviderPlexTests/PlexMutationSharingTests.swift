@testable import CoreNetworking
import Foundation
import XCTest
@testable import ProviderPlex
@testable import TestSupportNetworking

final class PlexMutationSharingTests: XCTestCase {
    func testOverlappingMetadataReadsShareButCompletedReadsAreFresh() async throws {
        let gate = FirstResponseGate()
        let server = try LoopbackHTTPServer { _ in
            await gate.record()
            return .json(#"{"MediaContainer":{"Metadata":[{"ratingKey":"101","type":"movie","title":"Fixture"}]}}"#)
        }
        let session = URLSession(configuration: .ephemeral)
        addTeardownBlock {
            await gate.release()
            await server.stop()
            session.invalidateAndCancel()
        }
        let http = URLSessionHTTPClient(session: session)
        let client = PlexClient(
            baseURL: try await server.start(),
            deviceProfile: PlexDeviceProfile(clientIdentifier: "fixture"),
            token: "fixture", http: http, interactiveHTTP: http
        )
        let first = Task { try await client.metadata(ratingKey: "101") }
        defer { first.cancel() }
        try await waitUntil { await gate.count == 1 }
        let second = Task { try await client.metadata(ratingKey: "101") }
        defer { second.cancel() }
        try await waitUntil { await HTTPRequestCoalescer.shared.waitingReaderCount() == 2 }
        await gate.release()
        let items = try await [first.value, second.value]
        XCTAssertEqual(items.map(\.ratingKey), ["101", "101"])
        let sharedRequests = await gate.count
        XCTAssertEqual(sharedRequests, 1)
        _ = try await client.metadata(ratingKey: "101")
        let freshRequests = await gate.count
        XCTAssertEqual(freshRequests, 2)
    }

    func testInterleavedGETWritesCannotJoinAnOlderPendingResponse() async throws {
        for mutation in Mutation.allCases {
            let gate = FirstResponseGate()
            let server = try LoopbackHTTPServer { _ in
                await gate.record()
                return .json("{}")
            }
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 5
            config.timeoutIntervalForResource = 5
            let session = URLSession(configuration: config)
            addTeardownBlock {
                await gate.release()
                await server.stop()
                session.invalidateAndCancel()
            }
            let client = PlexClient(
                baseURL: try await server.start(),
                deviceProfile: PlexDeviceProfile(clientIdentifier: "fixture"),
                token: "fixture",
                http: URLSessionHTTPClient(session: session)
            )
            let first = Task { try await mutation.apply(alternate: false, to: client) }
            defer { first.cancel() }
            try await waitUntil { await gate.count == 1 }
            try await mutation.apply(alternate: true, to: client)
            let latest = Task { try await mutation.apply(alternate: false, to: client) }
            defer { latest.cancel() }

            // The latest write must reach the server before the first response
            // is released, even though its request is identical to the first.
            try await waitUntil { await gate.count == 3 }
            try await latest.value
            let requests = await server.requests
            XCTAssertEqual(requests.map(\.method), ["GET", "GET", "GET"], "\(mutation)")
            XCTAssertEqual(requests[0].target, requests[2].target, "\(mutation)")
            XCTAssertNotEqual(requests[0].target, requests[1].target, "\(mutation)")
            await gate.release()
            try await first.value
            await server.stop()
            session.invalidateAndCancel()
        }
    }

    private enum Mutation: CaseIterable, Sendable {
        case rating, watched, progress, timeline

        func apply(alternate: Bool, to client: PlexClient) async throws {
            switch self {
            case .rating:
                try await client.setMusicRating(alternate ? 3 : 5, ratingKey: "101")
            case .watched:
                try await client.setWatched(!alternate, ratingKey: "101")
            case .progress:
                try await client.reportProgress(ratingKey: "101", timeMs: alternate ? 2_000 : 1_000)
            case .timeline:
                try await client.reportTimeline(
                    ratingKey: "101", playSessionID: "fixture", state: "playing",
                    timeMs: alternate ? 2_000 : 1_000, durationMs: 10_000
                )
            }
        }
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !(await condition()) {
            guard ContinuousClock.now < deadline else {
                XCTFail("An independent mutation did not reach the server")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    private actor FirstResponseGate {
        private(set) var count = 0
        private var pending: CheckedContinuation<Void, Never>?
        private var released = false

        func record() async {
            count += 1
            if count == 1, !released {
                await withCheckedContinuation { pending = $0 }
            }
        }

        func release() {
            released = true
            let waiter = pending
            pending = nil
            waiter?.resume()
        }
    }
}
