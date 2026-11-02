import CoreModels
import Foundation
import MediaTransportCore

/// The real FTP protocol engine over `NWConnection`. An actor that serializes
/// logical operations (an FTP control channel is single-command-at-a-time) and
/// keeps a contiguous playback transfer streaming on one data connection,
/// restarting it with `REST`+`RETR` on a discontiguous seek.
///
/// **TLS scope on tvOS:** `NWConnection` has no StartTLS, so *explicit* FTPS
/// (`AUTH TLS`) cannot be performed — `connect()` rejects it. *Implicit* FTPS
/// (TLS from connect, conventionally port 990) and plain FTP are supported.
actor FTPNetworkBackend: FTPBackend {
    private struct ActiveTransfer {
        let socket: FTPSocket
        let path: String
        let expected: RemoteFileRepresentation
        var nextOffset: Int64
    }

    private let target: FTPConnectionTarget
    private let configuration: FTPMediaTransportConfiguration

    private var control: FTPControlConnection?
    private var features: Set<String> = []
    private var restartSupported = false
    private var activeTransfer: ActiveTransfer?
    private var isClosed = false

    // Async serialization gate (actor methods are reentrant across awaits).
    private var isBusy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private static let maxListingBytes = 8 * 1_024 * 1_024

    init(target: FTPConnectionTarget, configuration: FTPMediaTransportConfiguration) {
        self.target = target
        self.configuration = configuration
    }

    // MARK: - Serialization

    private func acquire() async {
        if !isBusy {
            isBusy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty {
            isBusy = false
        } else {
            waiters.removeFirst().resume()
        }
    }

    // MARK: - Connect / login

    func connect() async throws {
        guard control == nil, !isClosed else {
            throw MediaTransportError.invalidInput(reason: "FTP backend already connected")
        }
        if configuration.security.negotiatesExplicitTLS {
            // Explicit FTPS needs to upgrade an established plaintext socket to
            // TLS (RFC 4217 AUTH TLS). Network.framework offers no StartTLS on
            // tvOS, so this is honestly unsupported rather than silently
            // downgraded. Implicit FTPS (990) or plain FTP are the options.
            throw MediaTransportError.unsupportedCapability(
                "FTP explicit TLS (AUTH TLS) is unavailable on tvOS"
            )
        }

        let parameters = FTPTLSParameters.make(
            security: configuration.security,
            trustPolicy: configuration.trustPolicy
        )
        let socket = FTPSocket(host: target.host, port: target.port, parameters: parameters)
        do {
            try await socket.start()
        } catch {
            socket.cancel()
            throw mapFTPError(error)
        }
        let control = FTPControlConnection(socket: socket)
        self.control = control

        do {
            let greeting = try await control.readReply()
            guard greeting.code == 220 else {
                throw FTPProtocolError.unexpectedReply(code: greeting.code)
            }
            try await loadFeatures(control, beforeLogin: true)
            if features.contains("UTF8") {
                try await enableUTF8(control, beforeLogin: true)
            }
            try await login(control)
            try await loadFeatures(control, beforeLogin: false)
            if features.contains("UTF8") {
                try await enableUTF8(control, beforeLogin: false)
            }
            if configuration.security.usesTLS {
                // Protect the data channel too (RFC 4217): PBSZ 0 then PROT P.
                try await control.sendExpectingCompletion("PBSZ 0")
                let prot = try await control.send("PROT P")
                guard prot.isPositiveCompletion else {
                    throw FTPProtocolError.unexpectedReply(code: prot.code)
                }
            }
            try await control.sendExpectingCompletion("TYPE I")
            restartSupported = try await detectRestartSupport(control)
        } catch {
            control.cancel()
            self.control = nil
            throw mapFTPError(error)
        }
    }

    func supportsRestart() async -> Bool {
        restartSupported
    }

    private func loadFeatures(_ control: FTPControlConnection, beforeLogin: Bool) async throws {
        let reply = try await control.send("FEAT")
        guard reply.code == 211 else {
            guard [500, 502, 504].contains(reply.code) || (beforeLogin && reply.code == 530) else {
                throw FTPProtocolError.unexpectedReply(code: reply.code)
            }
            features = []
            return
        }
        var found: Set<String> = []
        for line in reply.text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let token = trimmed.split(separator: " ").first else { continue }
            found.insert(token.uppercased())
        }
        features = found
    }

    private func detectRestartSupport(_ control: FTPControlConnection) async throws -> Bool {
        if features.contains("REST") { return true }

        // FEAT is optional on older servers. Probe a nonzero offset in binary
        // mode, then clear the marker so browsing/whole-file reads start at zero.
        let restart = try await control.send("REST 1")
        switch restart.code {
        case 350:
            let reset = try await control.send("REST 0")
            guard reset.code == 350 else {
                throw FTPProtocolError.unexpectedReply(code: reset.code)
            }
            return true
        case 500, 501, 502, 504:
            return false
        default:
            throw FTPProtocolError.unexpectedReply(code: restart.code)
        }
    }

    private func login(_ control: FTPControlConnection) async throws {
        let (user, pass) = configuration.credential.loginPair
        let userReply = try await control.send("USER \(user)")
        if userReply.code == 331 || userReply.isPositiveIntermediate {
            let passReply = try await control.send("PASS \(pass)")
            guard passReply.isPositiveCompletion else {
                throw FTPProtocolError.unexpectedReply(code: passReply.code)
            }
        } else if !userReply.isPositiveCompletion {
            throw FTPProtocolError.unexpectedReply(code: userReply.code)
        }
    }

    private func enableUTF8(_ control: FTPControlConnection, beforeLogin: Bool) async throws {
        let reply = try await control.send("OPTS UTF8 ON")
        guard reply.isPositiveCompletion || [500, 501, 502, 504].contains(reply.code)
                || (beforeLogin && reply.code == 530) else {
            throw FTPProtocolError.unexpectedReply(code: reply.code)
        }
    }

    // MARK: - Passive data channel

    private func negotiatePassivePort(forcePASV: Bool) async throws -> (port: Int, extended: Bool) {
        guard let control else { throw MediaTransportError.transport(code: -1) }
        if !forcePASV {
            let epsv = try await control.send("EPSV")
            if epsv.code == 229 {
                if let parsed = try? FTPPassiveParser.parseEPSV(epsv.text) {
                    return (parsed.port, true)
                }
            } else if ![500, 501, 502, 504, 522].contains(epsv.code) {
                throw FTPProtocolError.unexpectedReply(code: epsv.code)
            }
        }
        guard control.usesIPv4 else { throw FTPProtocolError.passiveModeUnavailable }
        let pasv = try await control.send("PASV")
        guard pasv.code == 227 else {
            throw FTPProtocolError.unexpectedReply(code: pasv.code)
        }
        return (try FTPPassiveParser.parsePASV(pasv.text).port, false)
    }

    private func beginTransfer(
        _ command: String,
        offset: Int64 = 0,
        expectedFile: (path: String, representation: RemoteFileRepresentation)? = nil
    ) async throws -> FTPSocket {
        var forcePASV = false
        while true {
            try Task.checkCancellation()
            guard let control else { throw MediaTransportError.transport(code: -1) }
            if let expectedFile {
                try await validateSize(path: expectedFile.path, expected: expectedFile.representation)
            }
            let passive = try await negotiatePassivePort(forcePASV: forcePASV)
            let socket = FTPSocket(
                host: target.host, port: passive.port,
                parameters: FTPTLSParameters.make(
                    security: configuration.security, trustPolicy: configuration.trustPolicy
                )
            )
            let readiness = Task { try await socket.start() }
            let controlUsesIPv4 = control.usesIPv4
            var waitingForDataConnection = false
            var commandSent = false
            do {
                try await withTaskCancellationHandler {
                    // Start TCP immediately, but do not wait for data TLS before
                    // RETR/LIST: servers may defer that handshake until then.
                    if !configuration.security.usesTLS {
                        waitingForDataConnection = true
                        try await readiness.value
                        waitingForDataConnection = false
                    }
                    if offset > 0 {
                        let rest = try await control.send("REST \(offset)")
                        guard rest.code == 350 else {
                            throw FTPProtocolError.unexpectedReply(code: rest.code)
                        }
                    }
                    commandSent = true
                    let reply = try await control.send(command)
                    guard reply.code == 125 || reply.code == 150 else {
                        throw FTPProtocolError.unexpectedReply(code: reply.code)
                    }
                    waitingForDataConnection = true
                    try await readiness.value
                    waitingForDataConnection = false
                } onCancel: {
                    readiness.cancel()
                    socket.cancel()
                }
                return socket
            } catch {
                readiness.cancel()
                socket.cancel()
                let readyResult = await readiness.result
                let dataConnectionFailed: Bool
                if case .failure(let dataError) = readyResult {
                    dataConnectionFailed = isRetryableFTPError(dataError)
                } else {
                    dataConnectionFailed = false
                }
                let canFallback = (waitingForDataConnection || dataConnectionFailed)
                    && passive.extended && controlUsesIPv4
                    && !Task.isCancelled && isRetryableFTPError(error)
                if commandSent || !canFallback {
                    discardConnections()
                }
                guard canFallback else { throw error }
                forcePASV = true
                if commandSent { try await connect() }
            }
        }
    }

    private func prepareIdleConnection() async throws {
        try Task.checkCancellation()
        guard !isClosed else { throw MediaTransportError.cancelled }
        // A pending 226 and the ABOR response are indistinguishable on some
        // servers. Never reuse that control stream after a partial transfer.
        if activeTransfer != nil { discardConnections() }
        if control == nil { try await connect() }
    }

    private func discardConnections() {
        activeTransfer?.socket.cancel()
        activeTransfer = nil
        control?.cancel()
        control = nil
    }

    private func finishTransfer() async throws {
        guard let control else { throw MediaTransportError.transport(code: -1) }
        let reply = try await control.readReply()
        guard reply.code == 226 || reply.code == 250 else {
            throw FTPProtocolError.unexpectedReply(code: reply.code)
        }
    }

    // MARK: - Browse

    func list(path: String) async throws -> [FTPBackendEntry] {
        try Task.checkCancellation()
        await acquire()
        defer { release() }
        do {
            try await prepareIdleConnection()
            var useMLSD = features.contains("MLST") || features.contains("MLSD")
            let dataSocket: FTPSocket
            do {
                dataSocket = try await beginTransfer(useMLSD ? "MLSD \(path)" : "LIST \(path)")
            } catch FTPProtocolError.unexpectedReply(let code) where useMLSD && [500, 502, 504].contains(code) {
                try await prepareIdleConnection()
                useMLSD = false
                dataSocket = try await beginTransfer("LIST \(path)")
            }
            defer { dataSocket.cancel() }
            let data = try await readAll(from: dataSocket, cap: Self.maxListingBytes)
            try await finishTransfer()
            let text = String(decoding: data, as: UTF8.self)
            let listings = useMLSD ? FTPListParser.parseMLSD(text) : FTPListParser.parseLIST(text)
            return listings.map {
                FTPBackendEntry(name: $0.name, kind: $0.kind, size: $0.size, modifiedAt: $0.modifiedAt)
            }
        } catch {
            discardConnections()
            throw error
        }
    }

    func stat(path: String) async throws -> FTPBackendEntry {
        await acquire()
        defer { release() }
        try await prepareIdleConnection()
        guard let control else { throw MediaTransportError.transport(code: -1) }
        let name = lastComponent(of: path)

        if features.contains("MLST"),
           let reply = try? await control.send("MLST \(path)"),
           reply.isPositiveCompletion,
           let listing = parseMLSTFacts(reply.text) {
            return FTPBackendEntry(
                name: name,
                kind: listing.kind,
                size: listing.kind == .directory ? nil : listing.size,
                modifiedAt: listing.modifiedAt
            )
        }

        // Fallback: SIZE identifies a file; otherwise probe as a directory.
        let sizeReply = try await control.send("SIZE \(path)")
        if sizeReply.code == 213,
           let size = Int64(sizeReply.text.trimmingCharacters(in: .whitespaces)) {
            let mtime = try await fetchMDTM(path, on: control)
            return FTPBackendEntry(name: name, kind: .file, size: size, modifiedAt: mtime)
        }

        let cwd = try await control.send("CWD \(path)")
        guard cwd.isPositiveCompletion else {
            throw FTPProtocolError.unexpectedReply(code: cwd.code)
        }
        // Restore the working directory to the root to avoid state drift.
        _ = try? await control.send("CWD \(target.rootPath)")
        return FTPBackendEntry(name: name, kind: .directory, size: nil, modifiedAt: nil)
    }

    func readSmallFile(path: String, maximumBytes: Int) async throws -> Data {
        try Task.checkCancellation()
        await acquire()
        defer { release() }
        do {
            try await prepareIdleConnection()
            let dataSocket = try await beginTransfer("RETR \(path)")
            defer { dataSocket.cancel() }
            let data = try await readAll(from: dataSocket, cap: maximumBytes)
            try await finishTransfer()
            return data
        } catch {
            discardConnections()
            throw error
        }
    }

    // MARK: - Ranged playback read

    /// Drift detection over FTP (deliberate, documented policy):
    ///
    /// The filesystem-transport family fails closed if a file changes underneath
    /// in-flight playback. FTP has no ETag and — unlike SMB's per-read fstat — no
    /// cheap per-read stat: `SIZE`/`MDTM` are separate control commands that
    /// cannot be issued while a `RETR` transfer occupies the control channel. So
    /// FTP re-validates `SIZE`+`MDTM` and fails closed with `.sourceChanged` at
    /// two boundaries — at `openSource` (see the filesystem) and again on **every
    /// seek** (a discontiguous read restarts the transfer, so `validateSize` runs
    /// before each new `REST`+`RETR`). It does **not** re-validate mid-contiguous
    /// stream, because doing so would require aborting the active transfer. Net:
    /// drift is caught at open and at each seek; a change during an uninterrupted
    /// linear read cannot reliably detect same-size in-place edits. Length
    /// changes and failed transfer completion are rejected separately.
    func read(
        path: String,
        at offset: Int64,
        length: Int,
        expected: RemoteFileRepresentation
    ) async throws -> Data {
        try Task.checkCancellation()
        await acquire()
        defer { release() }

        guard offset >= 0, length > 0 else {
            throw MediaTransportError.invalidInput(reason: "invalid FTP byte range")
        }
        do {
            try Task.checkCancellation()
            guard !isClosed else { throw MediaTransportError.cancelled }
            if let active = activeTransfer, active.nextOffset == offset,
               active.path == path, active.expected == expected {
                return try await continueRead(length: length)
            }
            try await prepareIdleConnection()
            guard offset < expected.size else { return Data() }
            let socket = try await beginTransfer(
                "RETR \(path)", offset: offset, expectedFile: (path, expected)
            )
            activeTransfer = ActiveTransfer(socket: socket, path: path, expected: expected, nextOffset: offset)
            return try await continueRead(length: length)
        } catch {
            discardConnections()
            throw error
        }
    }

    private func validateSize(path: String, expected: RemoteFileRepresentation) async throws {
        guard let control else { throw MediaTransportError.transport(code: -1) }
        let reply = try await control.send("SIZE \(path)")
        guard reply.code == 213 else {
            throw FTPProtocolError.unexpectedReply(code: reply.code)
        }
        guard let size = Int64(reply.text.trimmingCharacters(in: .whitespaces)) else {
            throw MediaTransportError.sourceChanged(reason: "FTP size unavailable")
        }
        guard size == expected.size else {
            throw MediaTransportError.sourceChanged(reason: "FTP size changed")
        }
        let current = try await fetchMDTM(path, on: control)
        try validateFTPRepresentation(size: size, modifiedAt: current, against: expected)
    }

    private func continueRead(length: Int) async throws -> Data {
        guard var active = activeTransfer else { throw MediaTransportError.transport(code: -1) }
        let count = Int(min(Int64(length), active.expected.size - active.nextOffset))
        var accumulated = Data()
        while true {
            // At the expected end, require actual EOF and the final reply even
            // if the last payload receive did not carry the EOF flag.
            let remaining = max(1, count - accumulated.count)
            let (chunk, isComplete) = try await active.socket.receive(maximumLength: remaining)
            accumulated.append(chunk)
            guard Int64(accumulated.count) <= active.expected.size - active.nextOffset else {
                throw MediaTransportError.sourceChanged(reason: "FTP transfer exceeded size")
            }
            let end = active.nextOffset + Int64(accumulated.count)
            if isComplete {
                guard end == active.expected.size else { throw FTPProtocolError.transferIncomplete }
                try await finishTransfer()
                active.socket.cancel()
                activeTransfer = nil
                return accumulated
            }
            guard !chunk.isEmpty else { throw FTPProtocolError.transferIncomplete }
            if accumulated.count == count, end < active.expected.size { break }
        }
        active.nextOffset += Int64(accumulated.count)
        activeTransfer = active

        return accumulated
    }

    // MARK: - Helpers

    private func fetchMDTM(_ path: String, on control: FTPControlConnection) async throws -> Date? {
        let reply = try await control.send("MDTM \(path)")
        if [500, 502, 504].contains(reply.code) { return nil }
        guard reply.code == 213 else { throw FTPProtocolError.unexpectedReply(code: reply.code) }
        guard let date = FTPListParser.parseMLSDTimestamp(reply.text.trimmingCharacters(in: .whitespaces)) else {
            throw FTPProtocolError.malformedReply
        }
        return date
    }

    private func readAll(from socket: FTPSocket, cap: Int) async throws -> Data {
        var accumulated = Data()
        guard cap >= 0 else { throw MediaTransportError.invalidInput(reason: "invalid FTP read bound") }
        while true {
            let count = min(64 * 1_024, cap - accumulated.count)
            let (chunk, isComplete) = try await socket.receive(maximumLength: max(1, count))
            accumulated.append(chunk)
            guard accumulated.count <= cap else {
                throw MediaTransportError.invalidInput(reason: "FTP file exceeds bound")
            }
            if isComplete { return accumulated }
            guard !chunk.isEmpty else { throw FTPProtocolError.transferIncomplete }
        }
    }

    private func lastComponent(of path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    /// Extracts type/size/modify from an `MLST` reply. The fact line is
    /// ` facts SP pathname` (leading space); `FTPReplyParser` has already
    /// stripped the `250`/`250-` framing, so scan for the line carrying facts.
    private func parseMLSTFacts(_ text: String) -> FTPListing? {
        for line in text.split(separator: "\n") {
            let trimmed = String(line).trimmingCharacters(in: .whitespaces)
            guard trimmed.contains("=") else { continue }
            if let listing = FTPListParser.parseMLSDLine(trimmed) {
                return listing
            }
        }
        return nil
    }

    func shutdown() async {
        await acquire()
        defer { release() }
        guard !isClosed else { return }
        isClosed = true
        if activeTransfer == nil, let control {
            _ = try? await control.send("QUIT")
        }
        discardConnections()
    }
}
