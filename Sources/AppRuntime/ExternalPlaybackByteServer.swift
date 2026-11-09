import CoreModels
import CoreNetworking
import Foundation
import MediaTransportCore
import Network

/// One loopback capability for an already-authorized set of immutable files.
/// Incoming requests can select only these resources, never an upstream URL.
actor ExternalPlaybackByteServer {
    struct Resource: Sendable {
        let cursor: MediaTransportSourceCursor
        let suffix: String
        let readSize: Int

        init(cursor: MediaTransportSourceCursor, suffix: String, preferredReadSize: Int = 1_048_576) {
            self.cursor = cursor
            self.suffix = suffix
            readSize = min(4 * 1024 * 1024, max(1, preferredReadSize))
        }
    }

    struct Request: Equatable {
        let path: String
        let head: Bool
        let range: String?

        init(_ text: String, authority: String) throws {
            let lines = text.components(separatedBy: "\r\n")
            let start = (lines.first ?? "").split(separator: " ", omittingEmptySubsequences: false)
            guard start.count == 3, ["GET", "HEAD"].contains(String(start[0])),
                  start[2] == "HTTP/1.1", start[1].hasPrefix("/") else { throw Failure.request }
            var headers: [String: String] = [:]
            for line in lines.dropFirst() where !line.isEmpty {
                guard let colon = line.firstIndex(of: ":"), colon != line.startIndex,
                      !line.hasPrefix(" "), !line.hasPrefix("\t") else { throw Failure.request }
                let key = line[..<colon].lowercased()
                guard headers[key] == nil else { throw Failure.request }
                headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            guard headers["host"] == authority, headers["origin"] == nil,
                  headers["transfer-encoding"] == nil,
                  headers["content-length"] == nil || headers["content-length"] == "0" else {
                throw Failure.request
            }
            path = String(start[1])
            head = start[0] == "HEAD"
            range = headers["range"]
        }
    }

    enum Failure: Error { case request, range, unavailable, truncated }

    static func interval(_ header: String?, size: Int64) throws -> Range<Int64> {
        guard size > 0 else { throw Failure.range }
        guard let header else { return 0..<size }
        guard header.hasPrefix("bytes=") else { throw Failure.range }
        let parts = header.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
        func number(_ value: Substring) -> Int64? {
            guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
            return Int64(value)
        }
        guard parts.count == 2 else { throw Failure.range }
        if parts[0].isEmpty {
            guard let count = number(parts[1]), count > 0 else { throw Failure.range }
            return max(0, size - min(count, size))..<size
        }
        guard let start = number(parts[0]), start < size else { throw Failure.range }
        if parts[1].isEmpty { return start..<size }
        guard let end = number(parts[1]), end >= start else { throw Failure.range }
        return start..<(min(end, size - 1) + 1)
    }

    private let listener: NWListener
    private let resources: [Resource]
    private let authorized: @MainActor @Sendable () -> Bool
    private let progress: @MainActor @Sendable (Int64) -> Void
    private let failed: @MainActor @Sendable () -> Void
    private let token = UUID().uuidString + UUID().uuidString
    private var paths: [String] = []
    private var authority = ""
    private var ready: CheckedContinuation<[URL], Error>?
    private var readinessTimeout: Task<Void, Never>?
    private var stopped = false
    private var terminalFailure = false
    private var connections: [UUID: (NWConnection, Task<Void, Never>, Task<Void, Never>)] = [:]
    private var shutdown: Task<Void, Never>?
    private var coverage: [Range<Int64>] = []
    private var lastProgress = Date.distantPast

    init(
        resources: [Resource], authorized: @escaping @MainActor @Sendable () -> Bool,
        progress: @escaping @MainActor @Sendable (Int64) -> Void,
        failed: @escaping @MainActor @Sendable () -> Void = {}
    ) throws {
        guard !resources.isEmpty, resources.count <= 9,
              resources.allSatisfy({ resource in
                  resource.cursor.byteSize > 0 && !resource.suffix.isEmpty && resource.suffix.count <= 8
                      && resource.suffix.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) }
              }) else { throw Failure.unavailable }
        self.resources = resources
        self.authorized = authorized
        self.progress = progress
        self.failed = failed
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> [URL] {
        let listener = listener
        let urls: [URL] = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                guard !stopped, ready == nil, paths.isEmpty else {
                    continuation.resume(throwing: Failure.unavailable)
                    return
                }
                ready = continuation
                listener.newConnectionHandler = { [weak self] connection in
                    Task {
                        guard let self else { connection.cancel(); return }
                        await self.accept(connection)
                    }
                }
                listener.stateUpdateHandler = { [weak self] state in
                    Task { await self?.stateChanged(state) }
                }
                readinessTimeout = Task {
                    do { try await Task.sleep(for: .seconds(5)) } catch { return }
                    await self.stop()
                }
                listener.start(queue: DispatchQueue.global(qos: .userInitiated))
            }
        } onCancel: { listener.cancel() }
        try Task.checkCancellation()
        return urls
    }

    private func stateChanged(_ state: NWListener.State) async {
        switch state {
        case .ready:
            guard !stopped, let continuation = ready, let port = listener.port?.rawValue else { return }
            authority = "127.0.0.1:\(port)"
            paths = resources.enumerated().map { "/\(token)/\($0.offset).\($0.element.suffix)" }
            let urls = paths.compactMap { URL(string: "http://\(authority)\($0)") }
            ready = nil
            readinessTimeout?.cancel()
            guard urls.count == resources.count else {
                continuation.resume(throwing: Failure.unavailable)
                await stop()
                return
            }
            continuation.resume(returning: urls)
        case .failed, .cancelled: await stop()
        default: break
        }
    }

    func stop() async {
        if let shutdown { await shutdown.value; return }
        stopped = true
        ready?.resume(throwing: Failure.unavailable)
        ready = nil
        readinessTimeout?.cancel()
        listener.newConnectionHandler = nil
        listener.stateUpdateHandler = nil
        listener.cancel()
        let pending = Array(connections.values)
        connections.removeAll()
        for (connection, task, timeout) in pending {
            task.cancel()
            timeout.cancel()
            connection.cancel()
        }
        resources.forEach { $0.cursor.close() }
        let drain = Task { for (_, task, _) in pending { await task.value } }
        shutdown = drain
        await drain.value
    }

    private func accept(_ connection: NWConnection) {
        guard !stopped, !terminalFailure, connections.count < 8 else { connection.cancel(); return }
        let id = UUID()
        connection.start(queue: DispatchQueue.global(qos: .userInitiated))
        let task = Task {
            await serve(connection, id: id)
            remove(id)
        }
        connections[id] = (connection, task, deadline(id))
    }

    private func deadline(_ id: UUID) -> Task<Void, Never> {
        Task {
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            self.remove(id)
        }
    }

    private func touch(_ id: UUID) {
        guard var value = connections[id] else { return }
        value.2.cancel()
        value.2 = deadline(id)
        connections[id] = value
    }

    private func remove(_ id: UUID) {
        guard let (connection, task, timeout) = connections.removeValue(forKey: id) else { return }
        timeout.cancel()
        task.cancel()
        connection.cancel()
    }

    private func checkAuthorization() async throws {
        try Task.checkCancellation()
        guard !stopped, !terminalFailure, await authorized() else { throw CancellationError() }
    }

    private func serve(_ connection: NWConnection, id: UUID) async {
        var sentHead = false
        do {
            var input = Data()
            let terminator = Data("\r\n\r\n".utf8)
            while input.range(of: terminator) == nil {
                guard input.count < 16_384 else { throw Failure.request }
                let next: Data = try await withCheckedThrowingContinuation { continuation in
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384 - input.count) { data, _, done, error in
                        if let error { continuation.resume(throwing: error) }
                        else if let data, !data.isEmpty { continuation.resume(returning: data) }
                        else { continuation.resume(throwing: done ? Failure.request : Failure.unavailable) }
                    }
                }
                input.append(next)
            }
            guard input.range(of: terminator)?.upperBound == input.endIndex,
                  let text = String(data: input, encoding: .utf8) else { throw Failure.request }
            let request = try Request(text, authority: authority)
            guard let index = paths.firstIndex(of: request.path) else { throw Failure.request }
            try await checkAuthorization()
            let resource = resources[index]
            let interval: Range<Int64>
            do { interval = try Self.interval(request.range, size: resource.cursor.byteSize) }
            catch {
                try await send(Self.head(
                    status: 416, length: 0, extra: "Content-Range: bytes */\(resource.cursor.byteSize)\r\n"
                ), connection: connection, id: id)
                return
            }
            guard let cursor = resource.cursor.clone() else { throw Failure.unavailable }
            defer { cursor.close() }
            var offset = interval.lowerBound
            let first = request.head ? Data() : try await cursor.read(
                at: offset, length: Int(min(Int64(resource.readSize), interval.upperBound - offset))
            )
            try await checkAuthorization()
            if !request.head, first.isEmpty { throw Failure.truncated }
            let range = request.range == nil ? "" :
                "Content-Range: bytes \(interval.lowerBound)-\(interval.upperBound - 1)/\(cursor.byteSize)\r\n"
            let contentType = resource.suffix == "srt" ? "application/x-subrip" : "application/octet-stream"
            try await send(Self.head(
                status: request.range == nil ? 200 : 206, length: interval.count,
                extra: range + "Content-Type: \(contentType)\r\nAccept-Ranges: bytes\r\n"
            ), connection: connection, id: id)
            sentHead = true
            if request.head { return }
            var data = first
            while offset < interval.upperBound {
                try await checkAuthorization()
                guard !data.isEmpty, Int64(data.count) <= interval.upperBound - offset else { throw Failure.truncated }
                var consumed = 0
                while consumed < data.count {
                    try await checkAuthorization()
                    let length = min(262_144, data.count - consumed)
                    try await send(data.subdata(in: consumed..<(consumed + length)), connection: connection, id: id)
                    let next = offset + Int64(length)
                    if index == 0 { await recordCoverage(offset..<next) }
                    offset = next
                    consumed += length
                }
                if offset < interval.upperBound {
                    data = try await cursor.read(at: offset, length: Int(min(Int64(resource.readSize), interval.upperBound - offset)))
                }
            }
        } catch {
            if Self.isTerminal(error), !terminalFailure {
                terminalFailure = true
                PlozzLog.playback.error("External file source is no longer usable; revoking handoff.")
                let failed = failed
                // Shutdown joins serving tasks, so it must run outside this one.
                Task {
                    await failed()
                    await self.stop()
                }
            }
            if !(error is CancellationError), !Task.isCancelled {
                PlozzLog.playback.error("External file streaming request failed.")
            }
            if !sentHead, !stopped, !Task.isCancelled {
                do {
                    try await send(Self.head(status: error is Failure ? 400 : 502, length: 0), connection: connection, id: id)
                } catch { connection.cancel() }
            }
        }
    }

    private static func isTerminal(_ error: Error) -> Bool {
        if case Failure.truncated = error { return true }
        guard let error = error as? MediaTransportError else { return false }
        switch error {
        case .timeout, .resourceBusy, .transport, .cancelled: return false
        case .invalidInput, .unsupportedCapability, .unsupportedRange, .authentication,
             .trust, .permissionDenied, .protocolViolation, .sourceChanged: return true
        }
    }

    private static func head(status: Int, length: Int, extra: String = "") -> Data {
        Data(("HTTP/1.1 \(status) Response\r\nContent-Length: \(length)\r\n"
            + extra + "Cache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n").utf8)
    }

    private func send(_ data: Data, connection: NWConnection, id: UUID) async throws {
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
        touch(id)
    }

    private func recordCoverage(_ interval: Range<Int64>) async {
        var merged = interval
        var result: [Range<Int64>] = []
        for existing in coverage {
            if existing.upperBound < merged.lowerBound || existing.lowerBound > merged.upperBound {
                result.append(existing)
            } else {
                merged = min(merged.lowerBound, existing.lowerBound)..<max(merged.upperBound, existing.upperBound)
            }
        }
        guard result.count < 4096 else { return }
        result.append(merged)
        coverage = result
        if Date().timeIntervalSince(lastProgress) >= 1 {
            lastProgress = Date()
            await progress(coverage.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) })
        }
    }
}
