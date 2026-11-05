import Foundation
import Network

/// Connectivity is an opportunity to retry, not proof that a server is reachable.
@MainActor
public final class WatchOutboxConnectivity {
    public private(set) var isConnected = false
    private let monitor: NWPathMonitor?
    private let onReconnect: @MainActor @Sendable () -> Void

    public init(
        monitor: NWPathMonitor? = NWPathMonitor(),
        onReconnect: @escaping @MainActor @Sendable () -> Void
    ) {
        self.monitor = monitor
        self.onReconnect = onReconnect
        monitor?.pathUpdateHandler = { [weak self] path in
            let isConnected = path.status == .satisfied
            Task { @MainActor [weak self] in
                self?.update(isConnected: isConnected)
            }
        }
        monitor?.start(queue: DispatchQueue(label: "com.plozz.watch-outbox.connectivity"))
    }

    deinit {
        monitor?.cancel()
    }

    func update(isConnected: Bool) {
        guard self.isConnected != isConnected else { return }
        self.isConnected = isConnected
        if isConnected { onReconnect() }
    }
}
