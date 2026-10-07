import CoreModels
import CoreNetworking
import CryptoKit
import Foundation
import Network

/// AVFoundation forwards custom headers to every HLS host. Keep credentials
/// behind a per-playback, loopback-only endpoint and authorize each upstream
/// request against the original stream origin instead.
actor IPTVPlaybackProxy {
    private let listener: NWListener
    private let origin: URL
    private let headers: [String: String]
    private let http: IPTVHTTP
    private let key = SymmetricKey(size: .bits256)
    private let token = UUID().uuidString
    private var port: UInt16?
    private var requests: [UUID: (NWConnection, Task<Void, Never>)] = [:]
    private var stopped = false
    private var didStart = false

    init(
        origin: URL, headers: [String: String], configuration: URLSessionConfiguration? = nil,
        sensitiveValues: [String] = []
    ) throws {
        self.origin = origin
        self.headers = headers
        http = IPTVHTTP(configuration: configuration, resourceTimeout: 86_400, sensitiveValues: sensitiveValues)
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> URL {
        guard !stopped else { throw CancellationError() }
        guard !didStart else { throw AppError.invalidResponse }
        didStart = true
        let listener = listener
        let ready = IPTVListenerReady()
        listener.newConnectionHandler = { [weak self] connection in
            Task {
                guard let self else { connection.cancel(); return }
                await self.accept(connection)
            }
        }
        let value: UInt16 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                ready.install(continuation)
                listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        if let port = listener.port?.rawValue { ready.finish(.success(port)) }
                        else { ready.finish(.failure(IPTVError.storage)) }
                    case .failed: ready.finish(.failure(IPTVError.storage))
                    case .cancelled: ready.finish(.failure(CancellationError()))
                    default: break
                    }
                }
                listener.start(queue: DispatchQueue.global(qos: .userInitiated))
            }
        } onCancel: {
            ready.finish(.failure(CancellationError()))
            listener.cancel()
        }
        guard !stopped, !Task.isCancelled else { listener.cancel(); throw CancellationError() }
        port = value
        return try address(for: origin)
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        listener.cancel()
        for (connection, task) in requests.values { task.cancel(); connection.cancel() }
        requests.removeAll()
    }

    private func accept(_ connection: NWConnection) {
        guard !stopped, requests.count < 16 else { connection.cancel(); return }
        let id = UUID()
        connection.start(queue: DispatchQueue.global(qos: .userInitiated))
        let task = Task { [weak self] in
            guard let self else { connection.cancel(); return }
            await self.serve(connection)
            await self.finished(id)
        }
        requests[id] = (connection, task)
    }

    private func finished(_ id: UUID) {
        requests.removeValue(forKey: id)?.0.cancel()
    }

    private func address(for url: URL) throws -> URL {
        guard let port, LiveTVPlaylistSource.isSupportedURL(url),
              let encrypted = try AES.GCM.seal(Data(url.absoluteString.utf8), using: key).combined else {
            throw IPTVError.invalidAddress
        }
        let payload = encrypted.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        guard let url = URL(string: "http://127.0.0.1:\(port)/\(token)/\(payload)") else {
            throw IPTVError.invalidAddress
        }
        return url
    }

    private func upstream(for path: String) throws -> URL {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count == 2, parts[0] == token, parts[1].utf8.count <= 24_000 else {
            throw IPTVError.authentication
        }
        var text = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        text += String(repeating: "=", count: (4 - text.count % 4) % 4)
        guard let data = Data(base64Encoded: text),
              let raw = String(data: try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key), encoding: .utf8),
              let url = URL(string: raw), LiveTVPlaylistSource.isSupportedURL(url) else { throw IPTVError.authentication }
        return url
    }

    private func serve(_ connection: NWConnection) async {
        let deadline = Task {
            do { try await Task.sleep(for: .seconds(15)); connection.cancel() }
            catch is CancellationError {}
            catch { connection.cancel() }
        }
        defer { deadline.cancel() }
        var sentResponse = false
        do {
            var head = Data()
            while head.range(of: Data("\r\n\r\n".utf8)) == nil {
                let bytes = try await Self.receive(connection, maximum: 32_768 - head.count)
                guard !bytes.isEmpty, head.count + bytes.count < 32_768 else { throw IPTVError.malformed }
                head.append(bytes)
            }
            deadline.cancel()
            guard let text = String(data: head, encoding: .utf8), let line = text.components(separatedBy: "\r\n").first else {
                throw IPTVError.malformed
            }
            let request = line.split(separator: " ")
            guard request.count == 3, request[0] == "GET" || request[0] == "HEAD" else { throw IPTVError.unsupported }
            let url = try upstream(for: String(request[1]))
            var outgoing = IPTVCredential.sameOrigin(origin, url) ? headers : [:]
            for field in text.components(separatedBy: "\r\n").dropFirst() {
                guard let colon = field.firstIndex(of: ":") else { continue }
                let name = field[..<colon].lowercased()
                if name == "range" || name == "if-range" {
                    outgoing[String(field[..<colon])] = field[field.index(after: colon)...]
                        .trimmingCharacters(in: .whitespaces)
                }
            }
            let (bytes, response) = try await http.bytes(url: url, headers: outgoing, method: String(request[0]))
            defer { bytes.task.cancel() }
            if request[0] == "HEAD" {
                try await Self.send(connection, data: responseHead(response, chunked: false))
                return
            }
            var iterator = bytes.makeAsyncIterator()
            var prefix = Data()
            while prefix.count < 16, let byte = try await iterator.next() { prefix.append(byte) }
            let contentType = response.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
            let prefixText = String(decoding: prefix, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            let manifest = contentType.contains("mpegurl") || prefixText.hasPrefix("#EXTM3U")
                || prefixText.hasPrefix("\u{FEFF}#EXTM3U")
            if manifest {
                var body = prefix
                while let byte = try await iterator.next() {
                    guard body.count < 8 * 1_024 * 1_024 else { throw IPTVError.oversizedRecord }
                    body.append(byte)
                    if body.count.isMultiple(of: 65_536) { try Task.checkCancellation() }
                }
                guard let text = String(data: body, encoding: .utf8) else { throw IPTVError.malformed }
                let rewritten = try rewrite(text, baseURL: response.url ?? url)
                let data = Data(rewritten.utf8)
                try await Self.send(connection, data: Data(
                    "HTTP/1.1 200 OK\r\nContent-Type: application/vnd.apple.mpegurl\r\nContent-Length: \(data.count)\r\nConnection: close\r\n\r\n".utf8
                ))
                sentResponse = true
                try await Self.send(connection, data: data)
            } else {
                try await Self.send(connection, data: responseHead(response, chunked: true))
                sentResponse = true
                var chunk = prefix
                while let byte = try await iterator.next() {
                    chunk.append(byte)
                    if chunk.count == 65_536 {
                        try Task.checkCancellation()
                        try await Self.sendChunk(connection, data: chunk)
                        chunk.removeAll(keepingCapacity: true)
                    }
                }
                if !chunk.isEmpty { try await Self.sendChunk(connection, data: chunk) }
                try await Self.send(connection, data: Data("0\r\n\r\n".utf8))
            }
        } catch {
            if !Task.isCancelled { PlozzLog.playback.error("Authenticated IPTV delivery failed") }
            if !sentResponse {
                do {
                    try await Self.send(connection, data: Data(
                        "HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8
                    ))
                } catch { connection.cancel() }
            }
        }
    }

    func rewrite(_ manifest: String, baseURL: URL) throws -> String {
        let expression = try NSRegularExpression(pattern: #"\bURI="([^"]+)""#)
        let normalized = manifest.hasPrefix("\u{FEFF}") ? String(manifest.dropFirst()) : manifest
        return try normalized.components(separatedBy: .newlines).map { line in
            if line.trimmingCharacters(in: .whitespaces).isEmpty { return line }
            if !line.hasPrefix("#") {
                guard let url = URL(string: line.trimmingCharacters(in: .whitespaces), relativeTo: baseURL)?.absoluteURL else {
                    throw IPTVError.malformed
                }
                return try address(for: url).absoluteString
            }
            var result = line
            for match in expression.matches(in: line, range: NSRange(line.startIndex..., in: line)).reversed() {
                guard let range = Range(match.range(at: 1), in: result),
                      let url = URL(string: String(result[range]), relativeTo: baseURL)?.absoluteURL else {
                    throw IPTVError.malformed
                }
                result.replaceSubrange(range, with: try address(for: url).absoluteString)
            }
            return result
        }.joined(separator: "\n")
    }

    private func responseHead(_ response: HTTPURLResponse, chunked: Bool) -> Data {
        var fields = ["HTTP/1.1 \(response.statusCode) OK", "Connection: close"]
        for name in ["Content-Type", "Content-Range", "Accept-Ranges"] {
            if let value = response.value(forHTTPHeaderField: name),
               !value.contains("\r"), !value.contains("\n") { fields.append(name + ": " + value) }
        }
        if chunked { fields.append("Transfer-Encoding: chunked") }
        else if response.expectedContentLength >= 0 { fields.append("Content-Length: \(response.expectedContentLength)") }
        return Data((fields.joined(separator: "\r\n") + "\r\n\r\n").utf8)
    }

    private nonisolated static func receive(_ connection: NWConnection, maximum: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: max(1, maximum)) { data, _, _, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: data ?? Data()) }
            }
        }
    }

    private nonisolated static func send(_ connection: NWConnection, data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }

    private nonisolated static func sendChunk(_ connection: NWConnection, data: Data) async throws {
        var output = Data((String(data.count, radix: 16) + "\r\n").utf8)
        output.append(data)
        output.append(Data("\r\n".utf8))
        try await send(connection, data: output)
    }
}

private final class IPTVListenerReady: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<UInt16, Error>?
    private var result: Result<UInt16, Error>?

    func install(_ continuation: CheckedContinuation<UInt16, Error>) {
        let completed: Result<UInt16, Error>? = lock.withLock {
            if let result { return result }
            self.continuation = continuation
            return nil
        }
        if let completed { continuation.resume(with: completed) }
    }

    func finish(_ result: Result<UInt16, Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let callback = continuation
        continuation = nil
        lock.unlock()
        callback?.resume(with: result)
    }
}
