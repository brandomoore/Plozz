import Foundation
import Observation

@MainActor
public protocol TrackerActivationControlling: AnyObject {
    var trackerEnabled: Bool { get }
    func setTrackerEnabled(_ enabled: Bool) throws
}

/// Opaque identity for capturing playback to the currently enabled grant.
public protocol TrackerPlaybackAdmitting: Sendable {
    var playbackAdmissionID: String? { get }
}

public extension TrackerPlaybackAdmitting {
    var playbackAdmissionID: String? { nil }
}

package enum TrackerPlaybackAdmissions {
    package static func capture(
        trakt: any TrackerPlaybackAdmitting, simkl: any TrackerPlaybackAdmitting,
        wetrakr: any TrackerPlaybackAdmitting, anilist: any TrackerPlaybackAdmitting, mal: any TrackerPlaybackAdmitting
    ) -> [String: String] {
        ["trakt": trakt.playbackAdmissionID, "simkl": simkl.playbackAdmissionID,
         "wetrakr": wetrakr.playbackAdmissionID, "anilist": anilist.playbackAdmissionID,
         "myanimelist": mal.playbackAdmissionID].compactMapValues { $0 }
    }
}

/// Playback adapters are also created independently of Settings, sometimes before
/// the profile is connected. Consult the persisted grant at capture and dispatch,
/// rather than copying a switch value into a player or an outbox at construction.
@Observable
package final class TrackerActivationStore: @unchecked Sendable {
    @TaskLocal package static var capturedAdmissions: [String: String]?
    /// External playback may report an earlier stop after returning to Plozz.
    @TaskLocal package static var eventDate: Date?
    private let tracker: String
    private let defaults: UserDefaults
    private let lock = NSLock()
    @ObservationIgnored private var namespace: String?
    @MainActor private var revision = 0

    package init(_ tracker: String, namespace: String? = nil, defaults: UserDefaults = .standard) {
        self.tracker = tracker
        self.defaults = defaults
        self.namespace = namespace
    }

    package func setNamespace(_ namespace: String?, update: () -> Void) {
        lock.withLock {
            self.namespace = namespace
            update()
        }
    }

    package func snapshot() -> TrackerActivationStore {
        lock.withLock { TrackerActivationStore(tracker, namespace: namespace, defaults: defaults) }
    }

    /// The legacy grant is enabled without a migration. Each re-enable mints a
    /// different admission, invalidating undelivered work from before the pause.
    package func admission(for identity: @autoclosure () -> String?) -> String? {
        lock.withLock { identity().flatMap(currentAdmission) }
    }

    package func capture<T>(_ load: () -> T?, identity: KeyPath<T, String>) -> (tokens: T, admission: String)? {
        lock.withLock {
            guard let tokens = load(), let id = currentAdmission(for: tokens[keyPath: identity]) else { return nil }
            return (tokens, id)
        }
    }

    private func currentAdmission(for id: String) -> String? {
        let key = key(for: id)
        let admission: String
        if let value = defaults.object(forKey: key) {
            guard let record = value as? [String: Any], let since = record["since"] as? Date,
                  let generation = record["generation"] as? String, UUID(uuidString: generation) != nil,
                  Self.eventDate.map({ $0 >= since }) != false else { return nil }
            admission = generation
        } else {
            admission = key
        }
        if let captured = Self.capturedAdmissions, captured[tracker] != admission { return nil }
        return admission
    }

    @MainActor package func observedAdmission(for identity: String?) -> String? {
        _ = revision
        return admission(for: identity)
    }

    @MainActor package func setEnabled(_ enabled: Bool, for identity: String?) throws {
        guard let identity else { throw TrackerHistoryError.scopeChanged }
        guard enabled != (observedAdmission(for: identity) != nil) else { return }
        write(enabled, identity: identity)
    }

    /// Status/credential refresh must not call this. A successful explicit pairing
    /// starts a fresh interval, even if the provider returned the same account.
    @MainActor package func didConnect(_ identity: String) {
        write(true, identity: identity)
    }

    @MainActor private func write(_ enabled: Bool, identity: String) {
        lock.withLock {
            let key = key(for: identity)
            if enabled {
                defaults.set(["generation": UUID().uuidString, "since": Date()] as [String: Any], forKey: key)
            } else {
                defaults.set(false, forKey: key)
            }
        }
        revision &+= 1
    }

    private func key(for identity: String) -> String {
        let grant = WatchlistReconciliationIdentity.credential(identity)
        return SettingsKey.scoped("com.plozz.tracker.activation.\(tracker).\(grant)", namespace: namespace)
    }
}
