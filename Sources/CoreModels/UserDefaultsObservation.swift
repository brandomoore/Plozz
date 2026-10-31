import Foundation

public final class UserDefaultsObservation {
    private let token: any NSObjectProtocol

    public init(onChange: @escaping @MainActor @Sendable () -> Void) {
        // Different UserDefaults instances can write the same persistent domain.
        token = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: nil
        ) { _ in
            if Thread.isMainThread {
                MainActor.assumeIsolated { onChange() }
            } else {
                // A synchronous main-queue observer can deadlock a background writer.
                Task { @MainActor in onChange() }
            }
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(token)
    }
}
