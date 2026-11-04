import CoreModels
import EnginePlozzigen
import Foundation
import MediaTransportCore
import MediaTransportFTP
import XCTest

@MainActor
final class FTPPlaybackIntegrationTests: XCTestCase {
    func testMP4WithTailMetadataPlaybackAndSeeks() async throws {
        try await playback(server: "plain")
    }

    func testMKVPlaybackAndSeeks() async throws {
        try await playback(server: "plain", path: "movie.mkv")
    }

    func testImplicitFTPSPlayback() async throws {
        try await playback(server: "tls")
    }

    func testDelayedDataTLSPlayback() async throws {
        try await playback(server: "delayedTLS")
    }

    func testIndependentRemoteServerPlayback() async throws {
        try await playback(server: "remote")
    }

    func testImplicitTLSFallsBackAfterRefusedEPSVConnection() async throws {
        try await playback(server: "tlsPassiveFallback")
    }

    func testPlaybackRecoversFromInjectedDataConnectionReset() async throws {
        let before = try await configuration(server: "reset").interruptions
        let url = try fixtureURL().appendingPathComponent("reset-drop")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let (_, response) = try await session.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 204)
        try await playback(server: "reset")
        let after = try await configuration(server: "reset").interruptions
        XCTAssertEqual(after, (before ?? 0) + 1, "The fixture must actually interrupt a data connection")
    }

    func testLargeOffsetsAndIndependentCursors() async throws {
        let context = try await context(server: "plain", path: "large.bin")
        do {
            let resolved = try await context.resolver.resolve(context.locator)
            let source = try XCTUnwrap(resolved.sourceLease.makeCursor())
            let sibling = try XCTUnwrap(source.clone())
            defer { source.close(); sibling.close() }
            let offset = Int64(4 * 1024 * 1024 * 1024 + 123)
            let marker = try await source.read(at: offset, length: 19)
            XCTAssertEqual(marker, Data("large-offset-marker".utf8))
            let beginning = try await sibling.read(at: 0, length: 16)
            XCTAssertEqual(beginning, Data(repeating: 0, count: 16))
            let end = try await source.read(at: context.locator.representation.size, length: 16)
            XCTAssertTrue(end.isEmpty)
            source.close()
            sibling.close()
            await resolved.waitForFinalShutdown()
        } catch {
            await context.close()
            throw error
        }
        await context.close()
    }

    func testUntrustedImplicitTLSIsRejected() async throws {
        let configuration = try await configuration(server: "tls")
        let adapter = FTPMediaTransportAdapter(scheme: .ftps) { _, _ in
            .init(credential: .anonymous, security: .implicitTLS, trustPolicy: .pinnedLeaf(
                sha256: [UInt8](repeating: 0, count: 32), revision: UUID()
            ))
        }
        let key = try configuration.key()
        do {
            let session = try await adapter.connect(for: key)
            await session.shutdown()
            XCTFail("An incorrect certificate pin must fail")
        } catch let error as MediaTransportError {
            guard case .trust = error else {
                XCTFail("Expected typed TLS trust failure")
                return
            }
        }
    }

    private func playback(server: String, path: String? = nil) async throws {
        let context = try await context(server: server, path: path)
        let engine = try PlozzigenVideoEngine(networkFileResolver: context.resolver)
        engine.configureLiveOutput(.init(isAudible: false, sharesAudioSession: true, suppressesDisplayMatching: true))
        do {
            let request = PlaybackRequest(
                item: MediaItem(id: "ftp-fixture", title: "FTP fixture", kind: .movie),
                playbackSource: .networkFile(context.locator)
            )
            await engine.load(request: request, startPosition: 0)
            try await waitForProgress(engine, beyond: 2)
            XCTAssertTrue(engine.hasPresentedVideoFrame, "A connection or demux probe is not playback")
            engine.pause()
            try await Task.sleep(for: .seconds(2))
            engine.play()
            try await waitForProgress(engine, beyond: engine.currentTime + 1)
            for position: Double in [40, 8, 55, 5] {
                await engine.seek(to: position)
                XCTAssertEqual(engine.currentTime, position, accuracy: 3)
                try await waitForProgress(engine, beyond: position + 1)
            }
            engine.stop()
            await engine.drainTransport()
            await engine.load(request: request, startPosition: 12)
            try await waitForProgress(engine, beyond: 13)
            XCTAssertTrue(engine.hasPresentedVideoFrame)
            engine.stop()
            await engine.drainTransport()
        } catch {
            engine.stop()
            await engine.drainTransport()
            await context.close()
            throw error
        }
        await context.close()
    }

    private func waitForProgress(_ engine: PlozzigenVideoEngine, beyond position: Double) async throws {
        let deadline = ContinuousClock.now + .seconds(45)
        while engine.currentTime < position, ContinuousClock.now < deadline {
            if case .failed = engine.status { throw Failure.playback }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard engine.currentTime >= position else { throw Failure.playbackTimeout }
    }

    private func configuration(server: String) async throws -> Configuration {
        let url = try fixtureURL()
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure.configuration }
        let values = try JSONDecoder().decode([String: Configuration].self, from: data)
        guard let configuration = values[server] else { throw Failure.configuration }
        return configuration
    }

    private func fixtureURL() throws -> URL {
        guard let value = ProcessInfo.processInfo.environment["PLOZZ_FTP_FIXTURE_URL"] else {
            throw XCTSkip("Opt in with the loopback tools/ftp-playback-fixture.py configuration URL.")
        }
        guard let url = URL(string: value), url.scheme == "http", url.host == "127.0.0.1" else {
            throw Failure.configuration
        }
        return url
    }

    private func context(server: String, path: String?) async throws -> Context {
        let configuration = try await configuration(server: server)
        let key = try configuration.key()
        let adapter = FTPMediaTransportAdapter(scheme: configuration.pin == nil ? .ftp : .ftps) { _, _ in
            .init(
                credential: .password(username: configuration.username, password: configuration.password),
                security: configuration.pin == nil ? .plaintext : .implicitTLS,
                trustPolicy: configuration.pin.map { .pinnedLeaf(sha256: $0, revision: key.trustRevision) } ?? .system
            )
        }
        let registry = MediaTransportResolverRegistry(adapter: adapter)
        let lease = try await registry.lease(for: key)
        do {
            let relativePath = path ?? configuration.path
            let file = try await lease.session.fileSystem.stat(relativePath: relativePath)
            let locator = try NetworkFileLocator(
                accountID: key.accountID, sourceID: key.accountID, credentialRevision: key.credentialRevision,
                relativePath: relativePath,
                representation: RemoteFileRepresentation(
                    size: XCTUnwrap(file.size),
                    identity: RemoteFileIdentity(kind: .modificationTime, modifiedAt: XCTUnwrap(file.modifiedAt)),
                    consistency: .changeDetecting
                ),
                formatHint: .init(container: URL(fileURLWithPath: relativePath).pathExtension)
            )
            lease.release()
            return Context(
                locator: locator, registry: registry,
                resolver: MediaTransportNetworkFileResolver(registry: registry) { _ in key }
            )
        } catch {
            lease.release()
            await registry.retire(accountID: key.accountID, credentialRevision: key.credentialRevision)
            throw error
        }
    }

    private enum Failure: Error { case configuration, playback, playbackTimeout }

    private struct Configuration: Decodable, Sendable {
        let host: String
        let port: Int
        let username: String
        let password: String
        let path: String
        let pin: [UInt8]?
        let interruptions: Int?

        func key() throws -> MediaTransportSessionKey {
            .init(
                accountID: "ftp-fixture", credentialRevision: .init(),
                endpoint: try .init(transportIdentifier: pin == nil ? "ftp" : "ftps", host: host, port: port, rootPath: "/"),
                trustRevision: UUID(), role: .playback
            )
        }
    }

    private struct Context {
        let locator: NetworkFileLocator
        let registry: MediaTransportResolverRegistry
        let resolver: MediaTransportNetworkFileResolver

        func close() async {
            await registry.retire(accountID: locator.accountID, credentialRevision: locator.credentialRevision)
        }
    }
}
