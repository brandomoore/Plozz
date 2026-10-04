import Foundation
import os

public struct LibraryBrowsePreferences: Codable, Equatable, Sendable {
    public var sort: SortDescriptor
    public var filters: LibraryFilters

    public init(sort: SortDescriptor = .default, filters: LibraryFilters = .all) {
        self.sort = sort
        self.filters = filters
    }
}

public struct LibraryBrowsePreferencesStore {
    private static let logger = Logger(subsystem: "com.plozz.app", category: "settings")
    public static let storageKey = "com.plozz.libraryBrowsePreferences"
    private let defaults: UserDefaults
    private let key: String

    public init(namespace: String? = nil, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        key = SettingsKey.scoped(Self.storageKey, namespace: namespace)
    }

    public static func address(accountID: String, libraryID: String, mode: String) -> String {
        // Length-prefixing keeps arbitrary provider IDs from colliding.
        [accountID, libraryID, mode].map { "\($0.utf8.count):\($0)" }.joined()
    }

    public func preferences(at address: String) -> LibraryBrowsePreferences? {
        read()[address]
    }

    public func save(_ preferences: LibraryBrowsePreferences, at address: String) {
        var values = read()
        values[address] = preferences
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            defaults.set(try encoder.encode(values), forKey: key)
        } catch {
            Self.logger.error("Unable to save library browse preferences: \(String(describing: error))")
        }
    }

    private func read() -> [String: LibraryBrowsePreferences] {
        guard let data = defaults.data(forKey: key) else { return [:] }
        do {
            return try JSONDecoder().decode([String: LibraryBrowsePreferences].self, from: data)
        } catch {
            Self.logger.error("Unable to read library browse preferences: \(String(describing: error))")
            return [:]
        }
    }
}
