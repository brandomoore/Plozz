import Foundation
import Observation
import FeatureHomeCore

/// A retained browsing-session clock, independent of Home's content task keys.
@MainActor
@Observable
public final class HeroFreshnessRefreshDriver {
    public struct ActivityID: Equatable {
        let driverID: ObjectIdentifier
        let isActive: Bool
    }

    public static let interval = HeroFreshnessSnapshot.refreshInterval
    public private(set) var revision = 0
    @ObservationIgnored private var lastAttemptAt: Date

    public init(now: Date = Date()) {
        lastAttemptAt = now
    }

    public func activityID(isActive: Bool) -> ActivityID {
        ActivityID(driverID: ObjectIdentifier(self), isActive: isActive)
    }

    public func beganCuration(at now: Date = Date()) {
        lastAttemptAt = now
    }

    @discardableResult
    public func requestIfDue(at now: Date = Date()) -> Bool {
        guard now.timeIntervalSince(lastAttemptAt) >= Self.interval else { return false }
        lastAttemptAt = now
        revision &+= 1
        return true
    }

    public func runWhileVisible() async {
        while !Task.isCancelled {
            requestIfDue()
            let delay = max(1, Self.interval - Date().timeIntervalSince(lastAttemptAt))
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
        }
    }
}
