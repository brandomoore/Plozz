import CoreModels
import Foundation
import Synchronization

/// All app-owned HTTP sessions use the same explicit offline admission rule.
public enum OfflineNetworkSession {
    private final class WeakSession: @unchecked Sendable {
        weak var value: URLSession?
        init(_ value: URLSession) { self.value = value }
    }

    private static let sessions = Mutex<[WeakSession]>([])
    public static let shared = make(configuration: .default)

    public static func make(
        configuration: URLSessionConfiguration,
        delegate: (any URLSessionDelegate)? = nil,
        delegateQueue: OperationQueue? = nil
    ) -> URLSession {
        // Background transfers are admitted and cancelled by DownloadQueue.
        if configuration.identifier == nil {
            configuration.protocolClasses = [OfflineURLProtocol.self] + (configuration.protocolClasses ?? [])
        }
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: delegateQueue)
        sessions.withLock {
            $0.removeAll { $0.value == nil }
            $0.append(WeakSession(session))
        }
        return session
    }

    public static func cancelRequests() async {
        let current = sessions.withLock { $0.compactMap(\.value) }
        for session in current {
            for task in await session.allTasks { task.cancel() }
        }
    }
}

private final class OfflineURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool {
        OfflineMode.shared.isEnabled && ["http", "https"].contains(request.url?.scheme?.lowercased() ?? "")
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: OfflineModeError.networkUnavailable)
    }

    override func stopLoading() {}
}
