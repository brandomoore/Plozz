import CoreModels
import Foundation
import MediaTransportCore
@testable import MediaTransportFTP
import Network
import XCTest

final class FTPCapabilityNegotiationTests: XCTestCase {
    private let noFeatures = "211-Features\r\n211 End\r\n"
    private let restartFeature = "211-Features\r\n REST STREAM\r\n211 End\r\n"
    private let accepted = "350 Restart accepted\r\n"

    func testFeaturesDiscoveredAfterLogin() async throws {
        try await check(
            beforeLogin: "530 Login first\r\n", afterLogin: restartFeature,
            restartReplies: [], expectedSupport: true
        )
    }

    func testLegacyServerWithoutFEATCanRestart() async throws {
        try await check(
            beforeLogin: "500 Unknown command\r\n", afterLogin: "500 Unknown command\r\n",
            restartReplies: [accepted, accepted], expectedSupport: true
        )
    }

    func testIncompleteFeaturesCanRestart() async throws {
        try await check(
            beforeLogin: noFeatures, afterLogin: noFeatures,
            restartReplies: [accepted, accepted], expectedSupport: true
        )
    }

    func testAdvertisedRestartNeedsNoProbe() async throws {
        try await check(
            beforeLogin: restartFeature, afterLogin: restartFeature,
            restartReplies: [], expectedSupport: true
        )
    }

    func testUnsupportedRestartRemainsBounded() async throws {
        for code in [500, 501, 502, 504] {
            try await check(
                beforeLogin: noFeatures, afterLogin: noFeatures,
                restartReplies: ["\(code) Unsupported restart\r\n"], expectedSupport: false
            )
        }
    }

    func testAuthenticatedCapabilitiesReplacePreLoginAdvertisement() async throws {
        try await check(
            beforeLogin: restartFeature, afterLogin: noFeatures,
            restartReplies: ["502 Unsupported restart\r\n"], expectedSupport: false
        )
    }

    func testTemporaryFeatureFailureIsNotUnsupportedRestart() async throws {
        try await check(
            beforeLogin: "421 Service unavailable\r\n", afterLogin: nil,
            restartReplies: [], expectedError: .timeout
        )
    }

    func testAuthenticatedFeatureFailureRemainsAuthenticationError() async throws {
        try await check(
            beforeLogin: noFeatures, afterLogin: "530 Not authorized\r\n",
            restartReplies: [], expectedError: .authentication(reason: "FTP login failed")
        )
    }

    func testTemporaryRestartFailureRemainsTransient() async throws {
        try await check(
            beforeLogin: noFeatures, afterLogin: noFeatures,
            restartReplies: ["421 Service unavailable\r\n"], expectedError: .timeout
        )
    }

    func testRestartAuthenticationFailureRemainsAuthenticationError() async throws {
        try await check(
            beforeLogin: noFeatures, afterLogin: noFeatures,
            restartReplies: ["530 Not authorized\r\n"],
            expectedError: .authentication(reason: "FTP login failed")
        )
    }

    func testFailedMarkerResetRejectsConnection() async throws {
        try await check(
            beforeLogin: noFeatures, afterLogin: noFeatures,
            restartReplies: [accepted, "500 Reset rejected\r\n"],
            expectedError: .transport(code: 500)
        )
    }

    func testProbeMarkerIsClearedBeforeWholeFileRead() async throws {
        let payload = Data("0123456789".utf8)
        try await check(
            beforeLogin: noFeatures, afterLogin: noFeatures,
            restartReplies: [accepted, accepted], expectedSupport: true,
            wholeFile: payload
        )
    }

    private func check(
        beforeLogin: String,
        afterLogin: String?,
        restartReplies: [String],
        expectedSupport: Bool? = nil,
        expectedError: MediaTransportError? = nil,
        wholeFile: Data? = nil
    ) async throws {
        var steps = [FTPHandshakeServer.Step("FEAT", beforeLogin)]
        if let afterLogin {
            steps += [
                .init("USER anonymous", "331 Password required\r\n"),
                .init("PASS anonymous@plozz", "230 Logged in\r\n"),
                .init("FEAT", afterLogin),
            ]
            if afterLogin.hasPrefix("211") || afterLogin.hasPrefix("500") {
                steps.append(.init("TYPE I", "200 Binary mode\r\n"))
            }
        }
        for (index, reply) in restartReplies.enumerated() {
            steps.append(.init(index == 0 ? "REST 1" : "REST 0", reply))
        }
        if wholeFile != nil {
            steps += [
                .init("EPSV", "229 Entering Extended Passive Mode (|||PORT|)\r\n"),
                .init("RETR /movie.bin", "150 Opening data connection\r\n"),
            ]
        }
        if expectedError == nil {
            steps.append(.init("QUIT", "221 Goodbye\r\n"))
        }
        let server = try FTPHandshakeServer(steps: steps, payload: wholeFile)
        defer { server.stop() }
        let port = try await server.start()
        let target = try FTPConnectionTarget(
            endpoint: MediaTransportEndpointIdentity(
                transportIdentifier: "ftp", host: "127.0.0.1", port: Int(port), rootPath: "/"
            ),
            security: .plaintext
        )
        let backend = FTPNetworkBackend(
            target: target,
            configuration: FTPMediaTransportConfiguration(credential: .anonymous, security: .plaintext)
        )
        do {
            try await backend.connect()
            XCTAssertNil(expectedError, "Expected connection failure")
            let support = await backend.supportsRestart()
            XCTAssertEqual(support, expectedSupport)
            if let wholeFile {
                let result = try await backend.readSmallFile(path: "/movie.bin", maximumBytes: 64)
                XCTAssertEqual(result, wholeFile, "Probe must not skip the first byte")
            }
        } catch let error as MediaTransportError {
            XCTAssertEqual(error, expectedError)
        } catch {
            await backend.shutdown()
            throw error
        }
        await backend.shutdown()
        XCTAssertEqual(server.commands, steps.map(\.command))
    }
}

final class FTPHandshakeServer: @unchecked Sendable {
    struct Step: Sendable {
        let command: String
        let reply: String

        init(_ command: String, _ reply: String) {
            self.command = command
            self.reply = reply
        }
    }

    private let queue = DispatchQueue(label: "plozz.tests.ftp-handshake")
    private let listener: NWListener
    private let dataListener: NWListener
    private let closedPortListener: NWListener
    private var closedPort: UInt16 = 0
    private let steps: [Step]
    private let payload: Data?
    private let completion: String
    private var connections: [NWConnection] = []
    private var dataConnection: NWConnection?
    private var transferControl: NWConnection?
    private var buffer = Data()
    private var receivedCommands: [String] = []
    private var restartOffset = 0

    var commands: [String] { queue.sync { receivedCommands } }

    init(steps: [Step], payload: Data?, completion: String = "226 Complete\r\n", host: String = "127.0.0.1") throws {
        self.steps = steps
        self.payload = payload
        self.completion = completion
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: .any)
        listener = try NWListener(using: parameters)
        dataListener = try NWListener(using: parameters)
        closedPortListener = try NWListener(using: parameters)
    }

    func start() async throws -> UInt16 {
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.connections.append(connection)
            self.buffer = Data()
            self.restartOffset = 0
            connection.start(queue: self.queue)
            connection.send(content: Data("220 Test FTP\r\n".utf8), completion: .contentProcessed { _ in })
            self.receive(on: connection)
        }
        dataListener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.connections.append(connection)
            self.dataConnection = connection
            connection.start(queue: self.queue)
            self.sendTransferIfReady()
        }
        listener.start(queue: queue)
        dataListener.start(queue: queue)
        closedPortListener.newConnectionHandler = { $0.cancel() }
        closedPortListener.start(queue: queue)
        for _ in 0..<200 {
            if let port = listener.port?.rawValue, port != 0,
               let dataPort = dataListener.port?.rawValue, dataPort != 0,
               let unusedPort = closedPortListener.port?.rawValue, unusedPort != 0 {
                queue.sync {
                    closedPort = unusedPort
                    closedPortListener.cancel()
                }
                return port
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        throw MediaTransportError.timeout
    }

    func stop() {
        queue.sync {
            listener.cancel()
            dataListener.cancel()
            closedPortListener.cancel()
            connections.forEach { $0.cancel() }
            connections.removeAll()
        }
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8_192) { [weak self] data, _, done, error in
            guard let self else { return }
            if let data { self.buffer.append(data) }
            while let range = self.buffer.range(of: Data([13, 10])) {
                let command = String(decoding: self.buffer[..<range.lowerBound], as: UTF8.self)
                self.buffer.removeSubrange(..<range.upperBound)
                let index = self.receivedCommands.count
                self.receivedCommands.append(command)
                guard index < self.steps.count, self.steps[index].command == command else {
                    connection.cancel()
                    return
                }
                let port = self.dataListener.port!.rawValue
                let reply = self.steps[index].reply
                    .replacingOccurrences(of: "CLOSEDPORT", with: String(self.closedPort))
                    .replacingOccurrences(of: "PORT_HIGH", with: String(port / 256))
                    .replacingOccurrences(of: "PORT_LOW", with: String(port % 256))
                    .replacingOccurrences(of: "PORT", with: String(port))
                if command.hasPrefix("REST "), reply.hasPrefix("350") {
                    self.restartOffset = Int(command.dropFirst(5))!
                }
                if command == "EPSV" || command == "PASV" {
                    self.dataConnection = nil
                    self.transferControl = nil
                }
                connection.send(content: Data(reply.utf8), completion: .contentProcessed { _ in })
                if (reply.hasPrefix("150") || reply.hasPrefix("125")),
                   command.hasPrefix("RETR ") || command.hasPrefix("MLSD ") || command.hasPrefix("LIST ") {
                    self.transferControl = connection
                    self.sendTransferIfReady()
                }
            }
            if !done, error == nil { self.receive(on: connection) }
        }
    }

    private func sendTransferIfReady() {
        guard let control = transferControl, let dataConnection, let payload else { return }
        transferControl = nil
        self.dataConnection = nil
        dataConnection.send(
            content: payload.dropFirst(restartOffset), contentContext: .finalMessage,
            isComplete: true, completion: .contentProcessed { _ in
                control.send(content: Data(self.completion.utf8), completion: .contentProcessed { _ in })
            }
        )
    }
}
