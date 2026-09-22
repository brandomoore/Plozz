import Foundation
import CoreModels
import CoreNetworking
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Silo has no native server broadcast protocol. Probe only its public v2
/// identity on the standard port, never credentials or a compatibility API.
public struct SiloServerDiscovery: ServerDiscovering {
    static let maximumConcurrentProbes = 32
    static let maximumCandidates = 512
    private let candidates: @Sendable () -> [URL]
    private let validator: ServerValidator

    public init() {
        candidates = {
            #if canImport(Darwin)
            return LANIPv4Interface.active().flatMap { $0.siloCandidates() }
            #else
            return []
            #endif
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 1
        configuration.timeoutIntervalForResource = 1.5
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        #if !os(Linux)
        configuration.waitsForConnectivity = false
        #endif
        validator = ServerValidator(provider: .silo, http: URLSessionHTTPClient(session: URLSession(configuration: configuration)))
    }

    init(candidates: @escaping @Sendable () -> [URL], validator: ServerValidator) {
        self.candidates = candidates
        self.validator = validator
    }

    public func discover(timeout: TimeInterval) -> AsyncStream<MediaServer> {
        guard timeout.isFinite, timeout > 0 else {
            PlozzLog.discovery.error("Invalid Silo discovery timeout")
            return AsyncStream { $0.finish() }
        }
        return AsyncStream { continuation in
            let task = Task.detached(priority: .utility) {
                await withTaskGroup(of: Void.self) { group in
                    group.addTask {
                        var seen = Set<URL>()
                        let urls = candidates().filter { seen.insert($0).inserted }.prefix(Self.maximumCandidates)
                        await probe(Array(urls), continuation: continuation)
                    }
                    group.addTask {
                        do { try await Task.sleep(for: .seconds(min(timeout, 30))) }
                        catch { return }
                    }
                    await group.next()
                    group.cancelAll()
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func probe(_ urls: [URL], continuation: AsyncStream<MediaServer>.Continuation) async {
        await withTaskGroup(of: MediaServer?.self) { group in
            var next = 0
            func enqueue(_ url: URL) {
                group.addTask {
                    guard !Task.isCancelled else { return nil }
                    do {
                        return try await validator.validate(rawURL: url.absoluteString)
                    } catch {
                        // Most LAN hosts do not run Silo. Only validated native
                        // replies are surfaced; failed candidates are not servers.
                        return nil
                    }
                }
            }
            while next < min(urls.count, Self.maximumConcurrentProbes), !Task.isCancelled {
                enqueue(urls[next])
                next += 1
            }
            while let server = await group.next() {
                guard !Task.isCancelled else { group.cancelAll(); break }
                if let server { continuation.yield(server) }
                if next < urls.count {
                    enqueue(urls[next])
                    next += 1
                }
            }
        }
    }
}
