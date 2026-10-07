import Foundation
import Network

actor IPTVTestHTTPServer {
    struct Response: Sendable {
        var data = Data()
        var file: URL?
        var status = 200
        var headers: [String: String] = [:]
        var cutoff: Int?
        var delay: Duration = .zero
    }

    private let listener: NWListener
    private let respond: @Sendable (String) -> Response
    private var connections: [UUID: (NWConnection, Task<Void, Never>)] = [:]
    private var stopped = false
    private(set) var requestCount = 0

    init(respond: @escaping @Sendable (String) -> Response) throws {
        self.respond = respond
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> URL {
        let listener = listener
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    if let port = listener.port { continuation.resume(returning: port.rawValue) }
                    else { continuation.resume(throwing: URLError(.cannotConnectToHost)) }
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task {
                    guard let self else { connection.cancel(); return }
                    await self.accept(connection)
                }
            }
            listener.start(queue: DispatchQueue(label: "IPTVTestHTTPServer"))
        }
        return URL(string: "http://127.0.0.1:\(port)/")!
    }

    func stop() {
        stopped = true
        listener.newConnectionHandler = nil
        listener.cancel()
        for (connection, task) in connections.values {
            task.cancel()
            connection.cancel()
        }
        connections.removeAll()
    }

    private func accept(_ connection: NWConnection) {
        guard !stopped else { connection.cancel(); return }
        let id = UUID()
        connection.start(queue: DispatchQueue.global())
        let task = Task {
            await serve(connection)
            connections.removeValue(forKey: id)
            connection.cancel()
        }
        connections[id] = (connection, task)
    }

    private func serve(_ connection: NWConnection) async {
        do {
            var request = Data()
            while request.range(of: Data("\r\n\r\n".utf8)) == nil {
                let part: Data = try await withCheckedThrowingContinuation { continuation in
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, _, error in
                        if let error { continuation.resume(throwing: error) }
                        else { continuation.resume(returning: data ?? Data()) }
                    }
                }
                guard !part.isEmpty, request.count < 32_768 else { throw URLError(.badServerResponse) }
                request.append(part)
            }
            requestCount += 1
            let text = String(decoding: request, as: UTF8.self)
            let response = respond(text)
            let file = try response.file.map { try FileHandle(forReadingFrom: $0) }
            defer {
                do { try file?.close() }
                catch { print("IPTV test fixture file close failed") }
            }
            let count: Int
            if let url = response.file {
                count = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            } else { count = response.data.count }
            var fields = response.headers
            fields["Content-Length"] = String(count)
            fields["Connection"] = "close"
            let head = "HTTP/1.1 \(response.status) Fixture\r\n"
                + fields.map { "\($0): \($1)\r\n" }.joined() + "\r\n"
            try await send(Data(head.utf8), on: connection)
            if text.hasPrefix("HEAD ") { return }
            let limit = min(count, response.cutoff ?? count)
            var offset = 0
            while offset < limit {
                try Task.checkCancellation()
                if response.delay != .zero { try await Task.sleep(for: response.delay) }
                let end = min(limit, offset + 65_536)
                let chunk: Data
                if let file { chunk = try file.read(upToCount: end - offset) ?? Data() }
                else { chunk = response.data.subdata(in: offset..<end) }
                guard !chunk.isEmpty else { throw URLError(.cannotDecodeContentData) }
                try await send(chunk, on: connection)
                offset += chunk.count
            }
        } catch {
            // URLSession deliberately closes authentication probes and cancelled test requests.
            print("IPTV test fixture transfer ended: \(type(of: error))")
        }
    }

    private func send(_ data: Data, on connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }
}
