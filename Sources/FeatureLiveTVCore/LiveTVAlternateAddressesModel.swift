import CoreModels
import Foundation
import Observation

/// Per-provider Xtream backup server addresses (Settings → Live TV → source → Backup server addresses).
@MainActor
@Observable
public final class LiveTVAlternateAddressesModel {
    public enum Issue: Equatable, Sendable {
        case invalidAddress, duplicate, tooMany, couldNotSave

        public var message: LocalizedStringResource {
            switch self {
            case .invalidAddress: "Enter a server address starting with http:// or https://."
            case .duplicate: "This server address is already added."
            case .tooMany: "No more backup server addresses can be added."
            case .couldNotSave: "The server address couldn't be saved. Please try again."
            }
        }
    }

    public typealias Load = @MainActor (_ accountID: String) -> [URL]?
    public typealias Save = @MainActor (_ accountID: String, _ urls: [URL]) throws -> Void

    public static let maximumAlternateAddresses = IPTVCredential.maximumAlternateAddresses

    public private(set) var issue: Issue?
    private var revision = 0
    @ObservationIgnored private let load: Load
    @ObservationIgnored private let save: Save

    public init(load: @escaping Load, save: @escaping Save) {
        self.load = load
        self.save = save
    }

    /// Nil when the account is not an Xtream IPTV provider.
    public func alternateAddresses(accountID: String) -> [URL]? {
        _ = revision
        return load(accountID)
    }

    @discardableResult
    public func add(_ address: String, accountID: String) -> Bool {
        guard let current = alternateAddresses(accountID: accountID) else { return false }
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let candidate = URL(string: trimmed),
              let normalized = try? IPTVCredential.normalizedXtreamAddress(candidate) else {
            return fail(.invalidAddress)
        }
        guard !current.contains(where: { IPTVCredential.sameOrigin($0, normalized) && $0.path == normalized.path }) else {
            return fail(.duplicate)
        }
        guard current.count < Self.maximumAlternateAddresses else {
            return fail(.tooMany)
        }
        do {
            try save(accountID, current + [normalized])
            revision += 1
            if let updated = load(accountID), updated.count == current.count {
                return fail(.duplicate)
            }
            issue = nil
            return true
        } catch {
            return fail(.couldNotSave)
        }
    }

    @discardableResult
    public func remove(_ url: URL, accountID: String) -> Bool {
        guard let current = alternateAddresses(accountID: accountID) else { return false }
        do {
            try save(accountID, current.filter { $0 != url })
            issue = nil
            revision += 1
            return true
        } catch {
            return fail(.couldNotSave)
        }
    }

    public func clearIssue() { issue = nil }
    public func refresh() { revision += 1 }

    private func fail(_ issue: Issue) -> Bool {
        self.issue = issue
        return false
    }
}
