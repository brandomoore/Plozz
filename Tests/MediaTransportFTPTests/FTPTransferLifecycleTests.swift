import CoreModels
import Foundation
import MediaTransportCore
@testable import MediaTransportFTP
import XCTest

final class FTPTransferLifecycleTests: XCTestCase {
    private let payload = Data("0123456789".utf8)

    private func login(features: String = " REST STREAM\r\n") -> [FTPHandshakeServer.Step] {
        let reply = "211-Features\r\n\(features)211 End\r\n"
        return [
            .init("FEAT", reply),
            .init("USER anonymous", "331 Password required\r\n"),
            .init("PASS anonymous@plozz", "230 Logged in\r\n"),
            .init("FEAT", reply),
            .init("TYPE I", "200 Binary\r\n"),
        ]
    }

    private func transfer(offset: Int64 = 0) -> [FTPHandshakeServer.Step] {
        var steps: [FTPHandshakeServer.Step] = [
            .init("EPSV", "229 Passive (|||PORT|)\r\n"),
        ]
        if offset > 0 { steps.append(.init("REST \(offset)", "350 Restart\r\n")) }
        steps.append(.init("RETR /movie.bin", "150 Transfer\r\n"))
        return steps
    }

    private func expected(size: Int64 = 10) throws -> RemoteFileRepresentation {
        try RemoteFileRepresentation(
            size: size,
            identity: RemoteFileIdentity(
                kind: .modificationTime, modifiedAt: Date(timeIntervalSince1970: 1_700_000_000)
            ),
            consistency: .changeDetecting
        )
    }

    private func connect(_ server: FTPHandshakeServer, host: String = "127.0.0.1") async throws -> FTPNetworkBackend {
        let port = try await server.start()
        let target = try FTPConnectionTarget(
            endpoint: .init(transportIdentifier: "ftp", host: host, port: Int(port), rootPath: "/"),
            security: .plaintext
        )
        let backend = FTPNetworkBackend(
            target: target, configuration: .init(credential: .anonymous, security: .plaintext)
        )
        try await backend.connect()
        return backend
    }

    func testSeekDiscardsQueuedCompletionInsteadOfMixingAbortReplies() async throws {
        let metadata: [FTPHandshakeServer.Step] = [
            .init("SIZE /movie.bin", "213 10\r\n"),
            .init("MDTM /movie.bin", "213 20231114221320\r\n"),
        ]
        let steps = login() + metadata + transfer() + login() + metadata + transfer(offset: 6)
            + [.init("QUIT", "221 Goodbye\r\n")]
        let server = try FTPHandshakeServer(steps: steps, payload: payload)
        defer { server.stop() }
        let backend = try await connect(server)
        do {
            let first = try await backend.read(path: "/movie.bin", at: 0, length: 2, expected: expected())
            XCTAssertEqual(first, payload.prefix(2))
            let seek = try await backend.read(path: "/movie.bin", at: 6, length: 4, expected: expected())
            XCTAssertEqual(seek, payload.suffix(4))
        } catch {
            await backend.shutdown()
            throw error
        }
        await backend.shutdown()
        XCTAssertEqual(server.commands, steps.map(\.command))
    }

    func testPrematureEOFIsNotSuccessfulShortRead() async throws {
        let steps = login() + [
            .init("SIZE /movie.bin", "213 20\r\n"),
            .init("MDTM /movie.bin", "213 20231114221320\r\n"),
        ] + transfer()
        let server = try FTPHandshakeServer(steps: steps, payload: payload)
        defer { server.stop() }
        let backend = try await connect(server)
        do {
            _ = try await backend.read(path: "/movie.bin", at: 0, length: 20, expected: expected(size: 20))
            XCTFail("Truncated transfer must fail")
        } catch {
            XCTAssertEqual(mapFTPError(error), .sourceChanged(reason: "FTP transfer ended early"))
        }
        await backend.shutdown()
    }

    func testWholeFileRejectsFailedFinalReply() async throws {
        let server = try FTPHandshakeServer(
            steps: login() + transfer(), payload: payload, completion: "426 Transfer failed\r\n"
        )
        defer { server.stop() }
        let backend = try await connect(server)
        do {
            _ = try await backend.readSmallFile(path: "/movie.bin", maximumBytes: 10)
            XCTFail("Data alone does not establish successful completion")
        } catch {
            XCTAssertEqual(mapFTPError(error), .transport(code: 426))
        }
        await backend.shutdown()
    }

    func testCapturedModificationTimeCannotDisappearOnSeek() async throws {
        let steps = login() + [
            .init("SIZE /movie.bin", "213 10\r\n"),
            .init("MDTM /movie.bin", "502 Unsupported\r\n"),
        ]
        let server = try FTPHandshakeServer(steps: steps, payload: payload)
        defer { server.stop() }
        let backend = try await connect(server)
        do {
            _ = try await backend.read(
                path: "/movie.bin", at: 0, length: 2,
                expected: expected()
            )
            XCTFail("Loss of a captured identity must fail closed")
        } catch {
            XCTAssertEqual(mapFTPError(error), .sourceChanged(reason: "FTP mtime changed"))
        }
        await backend.shutdown()
    }

    func testMLSTAdvertisementEnablesMLSD() async throws {
        let steps = login(features: " REST STREAM\r\n MLST type*;size*;modify*;\r\n") + [
            .init("EPSV", "229 Passive (|||PORT|)\r\n"),
            .init("MLSD /", "150 Listing\r\n"),
            .init("QUIT", "221 Goodbye\r\n"),
        ]
        let server = try FTPHandshakeServer(
            steps: steps, payload: Data("type=file;size=10; movie.bin\r\n".utf8)
        )
        defer { server.stop() }
        let backend = try await connect(server)
        do {
            let entries = try await backend.list(path: "/")
            XCTAssertEqual(entries.map(\.name), ["movie.bin"])
            XCTAssertEqual(entries.first?.size, 10)
        } catch {
            await backend.shutdown()
            throw error
        }
        await backend.shutdown()
        XCTAssertEqual(server.commands, steps.map(\.command))
    }

    func testFailedEPSVConnectionFallsBackToPASVOnControlHost() async throws {
        let steps = login() + [
            .init("EPSV", "229 Passive (|||CLOSEDPORT|)\r\n"),
            // Deliberately unreachable advertised IP: use the control peer.
            .init("PASV", "227 Passive (203,0,113,99,PORT_HIGH,PORT_LOW)\r\n"),
            .init("RETR /movie.bin", "150 Transfer\r\n"),
            .init("QUIT", "221 Goodbye\r\n"),
        ]
        let server = try FTPHandshakeServer(steps: steps, payload: payload)
        defer { server.stop() }
        let backend = try await connect(server)
        do {
            let result = try await backend.readSmallFile(path: "/movie.bin", maximumBytes: 10)
            XCTAssertEqual(result, payload)
        } catch {
            await backend.shutdown()
            throw error
        }
        await backend.shutdown()
        XCTAssertEqual(server.commands, steps.map(\.command))
    }

    func testEPSVAuthenticationFailureDoesNotFallBack() async throws {
        let steps = login() + [.init("EPSV", "530 Authorization lost\r\n")]
        let server = try FTPHandshakeServer(steps: steps, payload: payload)
        defer { server.stop() }
        let backend = try await connect(server)
        do {
            _ = try await backend.readSmallFile(path: "/movie.bin", maximumBytes: 10)
            XCTFail("Authentication failure must not trigger PASV")
        } catch {
            XCTAssertEqual(mapFTPError(error), .authentication(reason: "FTP login failed"))
        }
        await backend.shutdown()
        XCTAssertEqual(server.commands, steps.map(\.command))
    }

    func testFinalStatusIsValidatedAtExactExpectedLength() async throws {
        for completion in ["426 Aborted\r\n", "200 Not a transfer completion\r\n"] {
            let steps = login() + [
                .init("SIZE /movie.bin", "213 10\r\n"),
                .init("MDTM /movie.bin", "213 20231114221320\r\n"),
            ] + transfer()
            let server = try FTPHandshakeServer(steps: steps, payload: payload, completion: completion)
            defer { server.stop() }
            let backend = try await connect(server)
            do {
                _ = try await backend.read(path: "/movie.bin", at: 0, length: 10, expected: expected())
                XCTFail("Exact byte count still requires a successful final reply")
            } catch {
                XCTAssertEqual(mapFTPError(error), .transport(code: Int(completion.prefix(3))!))
            }
            await backend.shutdown()
        }
    }

    func testContiguousReadsReuseTransferAndPermit250Completion() async throws {
        let steps = login() + [
            .init("SIZE /movie.bin", "213 10\r\n"),
            .init("MDTM /movie.bin", "213 20231114221320\r\n"),
        ] + transfer() + [.init("QUIT", "221 Goodbye\r\n")]
        let server = try FTPHandshakeServer(steps: steps, payload: payload, completion: "250 Complete\r\n")
        defer { server.stop() }
        let backend = try await connect(server)
        do {
            let first = try await backend.read(path: "/movie.bin", at: 0, length: 3, expected: expected())
            let next = try await backend.read(path: "/movie.bin", at: 3, length: 20, expected: expected())
            XCTAssertEqual(first + next, payload)
        } catch {
            await backend.shutdown()
            throw error
        }
        await backend.shutdown()
        XCTAssertEqual(server.commands, steps.map(\.command))
    }

    func testWholeFileBoundClosesTaintedConnection() async throws {
        let server = try FTPHandshakeServer(steps: login() + transfer(), payload: payload)
        defer { server.stop() }
        let backend = try await connect(server)
        do {
            _ = try await backend.readSmallFile(path: "/movie.bin", maximumBytes: 5)
            XCTFail("Bounded reads must not silently truncate")
        } catch {
            XCTAssertEqual(mapFTPError(error), .invalidInput(reason: "FTP file exceeds bound"))
        }
        await backend.shutdown()
    }

    func testUTF8OptionMayRequireAuthentication() async throws {
        let features = "211-Features\r\n REST STREAM\r\n UTF8\r\n211 End\r\n"
        let steps: [FTPHandshakeServer.Step] = [
            .init("FEAT", features),
            .init("OPTS UTF8 ON", "530 Login first\r\n"),
            .init("USER anonymous", "331 Password required\r\n"),
            .init("PASS anonymous@plozz", "230 Logged in\r\n"),
            .init("FEAT", features),
            .init("OPTS UTF8 ON", "200 Enabled\r\n"),
            .init("TYPE I", "200 Binary\r\n"),
            .init("QUIT", "221 Goodbye\r\n"),
        ]
        let server = try FTPHandshakeServer(steps: steps, payload: nil)
        defer { server.stop() }
        let backend = try await connect(server)
        await backend.shutdown()
        XCTAssertEqual(server.commands, steps.map(\.command))
    }

    func testIPv6DoesNotFallBackToPASV() async throws {
        let steps = login() + [.init("EPSV", "502 Unsupported\r\n")]
        let server = try FTPHandshakeServer(steps: steps, payload: nil, host: "::1")
        defer { server.stop() }
        let backend = try await connect(server, host: "::1")
        do {
            _ = try await backend.readSmallFile(path: "/movie.bin", maximumBytes: 10)
            XCTFail("PASV is not an IPv6 fallback")
        } catch {
            XCTAssertEqual(mapFTPError(error), .protocolViolation(reason: "FTP passive mode failed"))
        }
        await backend.shutdown()
        XCTAssertEqual(server.commands, steps.map(\.command))
    }

    func testUnsupportedMLSDUsesFreshConnectionForLIST() async throws {
        let features = " REST STREAM\r\n MLST type*;size*;modify*;\r\n"
        let steps = login(features: features) + [
            .init("EPSV", "229 Passive (|||PORT|)\r\n"),
            .init("MLSD /", "502 Unsupported\r\n"),
        ] + login(features: features) + [
            .init("EPSV", "229 Passive (|||PORT|)\r\n"),
            .init("LIST /", "150 Listing\r\n"),
            .init("QUIT", "221 Goodbye\r\n"),
        ]
        let server = try FTPHandshakeServer(
            steps: steps, payload: Data("-rw-r--r-- 1 owner group 10 Nov 14 2023 movie.bin\r\n".utf8)
        )
        defer { server.stop() }
        let backend = try await connect(server)
        do {
            let entries = try await backend.list(path: "/")
            XCTAssertEqual(entries.map(\.name), ["movie.bin"])
        } catch {
            await backend.shutdown()
            throw error
        }
        await backend.shutdown()
        XCTAssertEqual(server.commands, steps.map(\.command))
    }
}
