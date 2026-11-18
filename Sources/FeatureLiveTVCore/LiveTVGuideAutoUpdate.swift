import CoreModels
import CoreNetworking
import Foundation

/// Keeps programme guides that are already saved on the device current while the app is
/// open, so Live TV opens on listings it does not have to wait for.
///
/// Each pass asks an account only whether its saved guide is due; the provider contacts
/// its server at most once per chosen interval, never per channel, and never downloads a
/// guide the profile has not used before.
public enum LiveTVGuideAutoUpdate {
    /// Launch belongs to Home; the first check waits until it has settled.
    public static let startDelay: TimeInterval = 60
    static let minimumWait: TimeInterval = 300
    static let firstRetry: TimeInterval = 900

    @MainActor
    public static func run(
        accountIDs: [String], interval: TimeInterval, resolver: LiveTVServerProviderResolver,
        now: @escaping @Sendable () -> Date = Date.init,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    ) async {
        guard interval > 0, !accountIDs.isEmpty else { return }
        do {
            try await sleep(startDelay)
            var failures = 0
            while true {
                var next: Date?
                var failed = false
                for id in accountIDs {
                    try Task.checkCancellation()
                    // Resolved again on every pass: only the current profile's authorized accounts.
                    guard let context = resolver(id), context.kind == .iptv else { continue }
                    do {
                        if let due = try await context.provider.updateSavedLiveTVGuide() {
                            next = min(next ?? due, due)
                        }
                    } catch {
                        try Task.checkCancellation()
                        failed = true
                        PlozzLog.app.error("Automatic guide update failed; saved listings retained")
                    }
                }
                try await sleep(wait(next: next, failed: failed, failures: &failures, interval: interval, now: now()))
            }
        } catch {
            // Cancelled: the profile, accounts, setting, or foreground state changed.
        }
    }

    static func wait(
        next: Date?, failed: Bool, failures: inout Int, interval: TimeInterval, now: Date
    ) -> TimeInterval {
        let wanted: TimeInterval
        if failed {
            failures += 1
            wanted = firstRetry * pow(2, Double(min(failures, 6) - 1))
        } else {
            failures = 0
            wanted = next.map { $0.timeIntervalSince(now) } ?? interval
        }
        return min(interval, max(minimumWait, wanted))
    }
}
