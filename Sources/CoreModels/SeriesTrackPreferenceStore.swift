import Foundation
import os

/// Per-profile persistence of series tracks, movie audio and title zoom choices.
/// Read at load and written only on a manual choice. Reads/writes are serialized so the player's manual-switch
/// writes and load-time reads can't interleave a lost update.
public protocol SeriesTrackPreferenceStoring: Sendable {
    func preference(forKey key: String) -> SeriesTrackPreference?
    func setAudioLanguage(_ language: String?, forKey key: String)
    func setSubtitle(_ selection: RememberedSubtitleSelection?, forKey key: String)
    func setVideoZoom(_ zoom: VideoZoomPreference?, forKey key: String)
}

public final class SeriesTrackPreferenceStore: SeriesTrackPreferenceStoring, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String
    private static let lock = NSLock()
    private static let logger = Logger(subsystem: "com.plozz.app", category: "settings")

    /// - Parameter namespace: per-profile scope. `nil` (the default/primary
    ///   profile) uses the un-suffixed key; other profiles pass their
    ///   `Profile.id`, mirroring the other settings stores.
    public init(defaults: UserDefaults = .standard, namespace: String? = nil) {
        self.defaults = defaults
        self.key = SettingsKey.scoped("com.plozz.seriesTrackPreferences", namespace: namespace)
    }

    public func preference(forKey key: String) -> SeriesTrackPreference? {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        return loadAll()?[key]
    }

    public func setAudioLanguage(_ language: String?, forKey key: String) {
        mutate(key) { $0.audioLanguage = language }
    }

    public func setSubtitle(_ selection: RememberedSubtitleSelection?, forKey key: String) {
        mutate(key) { $0.subtitle = selection }
    }

    public func setVideoZoom(_ zoom: VideoZoomPreference?, forKey key: String) {
        mutate(key) { $0.videoZoom = zoom }
    }

    // MARK: - Private

    /// Read-modify-write one series entry under the lock, dropping the entry when
    /// it becomes empty so the persisted map doesn't grow with no-op records.
    private func mutate(_ key: String, _ body: (inout SeriesTrackPreference) -> Void) {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        guard var all = loadAll() else { return }
        var entry = all[key] ?? SeriesTrackPreference()
        body(&entry)
        if entry.isEmpty {
            all[key] = nil
        } else {
            all[key] = entry
        }
        saveAll(all)
    }

    private func loadAll() -> [String: SeriesTrackPreference]? {
        guard let data = defaults.data(forKey: key) else { return [:] }
        do {
            return try JSONDecoder().decode([String: SeriesTrackPreference].self, from: data)
        } catch {
            Self.logger.error("Unable to decode title playback preferences; preserving the stored data.")
            return nil
        }
    }

    private func saveAll(_ map: [String: SeriesTrackPreference]) {
        do {
            defaults.set(try JSONEncoder().encode(map), forKey: key)
        } catch {
            Self.logger.error("Unable to encode title playback preferences.")
        }
    }
}
