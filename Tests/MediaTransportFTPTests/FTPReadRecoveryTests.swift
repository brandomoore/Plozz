import CoreModels
import Foundation
import MediaTransportCore
@testable import MediaTransportFTP
import XCTest

final class FTPReadRecoveryTests: XCTestCase {
    func testTransientFailureReplaysExactReadOnce() async throws {
        let factory = RecoveryFactory(failures: [.timeout])
        let source = try source(factory)
        let data = try await source.read(at: 4, length: 3)
        await source.shutdown()
        XCTAssertEqual(data, Data([4, 5, 6]))
        let reads = await factory.offsets
        let count = await factory.connectionCount
        XCTAssertEqual(reads, [4, 4])
        XCTAssertEqual(count, 2)
    }

    func testSecondFailureEndsRecovery() async throws {
        let factory = RecoveryFactory(failures: [.timeout, .transport(code: 426)])
        let source = try source(factory)
        do {
            _ = try await source.read(at: 4, length: 3)
            XCTFail("Recovery must be bounded")
        } catch {
            XCTAssertEqual(error as? MediaTransportError, .transport(code: 426))
        }
        await source.shutdown()
        let count = await factory.connectionCount
        XCTAssertEqual(count, 2)
    }

    func testPermanentFailuresAreNotRetried() async throws {
        for error: MediaTransportError in [
            .authentication(reason: "test"), .permissionDenied, .trust(reason: "test"),
            .sourceChanged(reason: "test"), .cancelled, .transport(code: 500),
            .protocolViolation(reason: "test"), .unsupportedRange(reason: "test"),
        ] {
            let factory = RecoveryFactory(failures: [error])
            let source = try source(factory)
            do {
                _ = try await source.read(at: 0, length: 3)
                XCTFail("Expected failure")
            } catch let actual as MediaTransportError {
                XCTAssertEqual(actual, error)
            }
            await source.shutdown()
            let count = await factory.connectionCount
            XCTAssertEqual(count, 1)
        }
    }

    func testReleasedCursorCannotReturnLateBytesOrReconnect() async throws {
        let factory = RecoveryFactory(failures: [], waitsForShutdown: true)
        let source = try source(factory)
        let cursor = UUID()
        let read = Task { try await source.read(cursorID: cursor, at: 0, length: 3) }
        await factory.waitForRead()
        await source.release(cursorID: cursor)
        do {
            _ = try await read.value
            XCTFail("Released cursor must not return late bytes")
        } catch {
            XCTAssertEqual(error as? MediaTransportError, .cancelled)
        }
        await source.shutdown()
        let count = await factory.connectionCount
        XCTAssertEqual(count, 1)
    }

    private func source(_ factory: RecoveryFactory) throws -> FTPCursorIsolatedByteSource {
        FTPCursorIsolatedByteSource(
            byteSize: 10, path: "/movie.bin",
            expectedRepresentation: try RemoteFileRepresentation(
                size: 10,
                identity: RemoteFileIdentity(kind: .modificationTime, modifiedAt: Date(timeIntervalSince1970: 0)),
                consistency: .changeDetecting
            ),
            backendFactory: { await factory.make() }
        )
    }
}

private actor RecoveryFactory {
    private var failures: [MediaTransportError]
    private let waitsForShutdown: Bool
    private(set) var connectionCount = 0
    private(set) var offsets: [Int64] = []
    private var readWaiter: CheckedContinuation<Void, Never>?

    init(failures: [MediaTransportError], waitsForShutdown: Bool = false) {
        self.failures = failures
        self.waitsForShutdown = waitsForShutdown
    }

    func make() -> any FTPBackend {
        connectionCount += 1
        let error = failures.isEmpty ? nil : failures.removeFirst()
        return RecoveryBackend(factory: self, failure: error, waitsForShutdown: waitsForShutdown)
    }

    func record(_ offset: Int64) {
        offsets.append(offset)
        readWaiter?.resume()
        readWaiter = nil
    }

    func waitForRead() async {
        if !offsets.isEmpty { return }
        await withCheckedContinuation { readWaiter = $0 }
    }
}

private actor RecoveryBackend: FTPBackend {
    let factory: RecoveryFactory
    let failure: MediaTransportError?
    let waitsForShutdown: Bool
    private var shutdownWaiter: CheckedContinuation<Void, Never>?
    private var closed = false

    init(factory: RecoveryFactory, failure: MediaTransportError?, waitsForShutdown: Bool) {
        self.factory = factory
        self.failure = failure
        self.waitsForShutdown = waitsForShutdown
    }

    func connect() {}
    func supportsRestart() -> Bool { true }
    func list(path: String) throws -> [FTPBackendEntry] { throw MediaTransportError.unsupportedCapability("test") }
    func stat(path: String) throws -> FTPBackendEntry { throw MediaTransportError.unsupportedCapability("test") }
    func readSmallFile(path: String, maximumBytes: Int) throws -> Data {
        throw MediaTransportError.unsupportedCapability("test")
    }

    func read(path: String, at offset: Int64, length: Int, expected: RemoteFileRepresentation) async throws -> Data {
        await factory.record(offset)
        if waitsForShutdown, !closed {
            await withCheckedContinuation { shutdownWaiter = $0 }
        }
        if let failure { throw failure }
        return Data((Int(offset)..<min(10, Int(offset) + length)).map(UInt8.init))
    }

    func shutdown() {
        closed = true
        shutdownWaiter?.resume()
        shutdownWaiter = nil
    }
}
