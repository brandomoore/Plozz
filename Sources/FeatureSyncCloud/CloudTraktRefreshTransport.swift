import CloudKit
import CoreNetworking
import Foundation
import Security
import TraktService

/// Uses the deployed tracker record type, encrypted `value` field and private
/// zone. Only the non-secret record-name prefix is new; no schema deployment is
/// needed. These records must NEVER enter SyncLedger's last-writer-wins merge.
public actor CloudTraktRefreshTransport: TraktSharedRefreshTransport {
    // Keep the existing trackerToken grammar: older sync clients retain opaque
    // tracker payloads, but delete record names their capture cannot represent.
    // A separate Keychain service/account prevents old Trakt clients decoding
    // the coordination envelope as an OAuth grant.
    public static let recordPrefix = "trackerToken:com.plozz.trakt.sharedGrant|"
    private let containerIdentifier: String
    private lazy var container = CKContainer(identifier: containerIdentifier)
    private let schema = CloudSyncSchemaDescriptor.trackerTokensV1

    private struct Envelope: Codable {
        let accountID: String
        let value: Data
    }

    public init(containerIdentifier: String) {
        self.containerIdentifier = containerIdentifier
    }

    /// Fail closed BEFORE constructing CKContainer, including test hosts and
    /// branded applications. A receipt is the distribution-build fallback where
    /// Apple removes the embedded provisioning profile.
    public static func isAvailable(containerIdentifier: String, bundle: Bundle = .main) -> Bool {
        guard !isTestHost else { return false }
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil),
              let values = SecTaskCopyValueForEntitlement(
                task, "com.apple.developer.icloud-container-identifiers" as CFString, nil
              ) as? [String] else { return false }
        return values.contains(containerIdentifier)
        #else
        if let values = provisionedContainers(bundle) { return values.contains(containerIdentifier) }
        guard bundle.url(forResource: "embedded", withExtension: "mobileprovision") == nil else { return false }
        guard containerIdentifier == "iCloud.com.thatcube.Plozz",
              bundle.bundleIdentifier == "com.thatcube.Plozz",
              let receipt = bundle.appStoreReceiptURL,
              FileManager.default.fileExists(atPath: receipt.path) else { return false }
        return true
        #endif
    }

    /// Unknown capability in the canonical app must fail as "iCloud unavailable",
    /// not silently downgrade a shared credential to an unsynchronized refresh.
    public static func requiresCoordination(containerIdentifier: String, bundle: Bundle = .main) -> Bool {
        guard !isTestHost else { return false }
        if isAvailable(containerIdentifier: containerIdentifier, bundle: bundle) { return true }
        #if os(macOS)
        return false
        #else
        return bundle.bundleIdentifier == "com.thatcube.Plozz" && provisionedContainers(bundle) == nil
        #endif
    }

    private static var isTestHost: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }

    private static func provisionedContainers(_ bundle: Bundle) -> [String]? {
        guard let url = bundle.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
              let profile = try? PropertyListSerialization.propertyList(
                from: data[start.lowerBound..<end.upperBound], format: nil
              ) as? [String: Any],
              let entitlements = profile["Entitlements"] as? [String: Any] else { return nil }
        return entitlements["com.apple.developer.icloud-container-identifiers"] as? [String] ?? []
    }

    public static func recordName(scope: String) -> String {
        recordPrefix + Data(scope.utf8).base64EncodedString()
    }

    public static func scope(recordName: String) -> String? {
        guard recordName.hasPrefix(recordPrefix),
              let data = Data(base64Encoded: String(recordName.dropFirst(recordPrefix.count))),
              let scope = String(data: data, encoding: .utf8),
              scope.split(separator: "\0", omittingEmptySubsequences: false).count == 2 else { return nil }
        return scope
    }

    /// Freeze legacy Trakt records too: their old LWW transport is only a
    /// migration source, never an authority after the CAS record exists.
    public static func manages(recordName: String) -> Bool {
        if recordName.hasPrefix(recordPrefix) { return true }
        guard recordName.hasPrefix("trackerToken:"),
              let separator = recordName.firstIndex(of: "|") else { return false }
        let account = recordName[recordName.index(after: separator)...]
        return account == "trakt.oauth" || account.hasPrefix("trakt.oauth.")
    }

    public func accountID() async throws -> String {
        guard Self.isAvailable(containerIdentifier: containerIdentifier) else {
            PlozzLog.sync.error("Trakt iCloud capability check failed")
            throw TraktSharedRefreshError.unavailable
        }
        do {
            let status = try await container.accountStatus()
            guard status == .available else {
                PlozzLog.sync.error("Trakt iCloud account is unavailable: status=\(status.rawValue)")
                throw TraktSharedRefreshError.unavailable
            }
            return try await container.userRecordID().recordName
        } catch {
            throw Self.mapError(error, operation: "account")
        }
    }

    private func requireAccount(_ expected: String) async throws {
        guard try await accountID() == expected else { throw TraktSharedRefreshError.accountChanged }
    }

    public func read(scope: String, accountID: String) async throws -> TraktSharedRecord? {
        try await requireAccount(accountID)
        do {
            let record = try await container.privateCloudDatabase.record(
                for: schema.recordID(forRecordName: Self.recordName(scope: scope))
            )
            try await requireAccount(accountID)
            return try decode(record, accountID: accountID)
        } catch let error as CKError where error.code == .unknownItem || error.code == .zoneNotFound {
            try await requireAccount(accountID)
            return nil
        } catch let error as TraktSharedRefreshError {
            throw error
        } catch {
            throw Self.mapError(error, operation: "read")
        }
    }

    public func readLegacyTokens(scope: String, accountID: String) async throws -> TraktTokens? {
        let parts = scope.split(separator: "\0", omittingEmptySubsequences: false)
        guard parts.count == 2 else { throw TraktSharedRefreshError.invalidRecord }
        try await requireAccount(accountID)
        do {
            let record = try await container.privateCloudDatabase.record(
                for: schema.recordID(forRecordName: "trackerToken:\(parts[0])|\(parts[1])")
            )
            try await requireAccount(accountID)
            guard schema.matches(record),
                  let bytes = record.encryptedValues[schema.fieldValue] as? Data else {
                throw TraktSharedRefreshError.invalidRecord
            }
            guard let tokens = try? JSONDecoder().decode(TraktTokens.self, from: bytes) else {
                throw TraktSharedRefreshError.invalidRecord
            }
            return tokens
        } catch let error as CKError where error.code == .unknownItem || error.code == .zoneNotFound {
            try await requireAccount(accountID)
            return nil
        } catch let error as TraktSharedRefreshError {
            throw error
        } catch {
            throw Self.mapError(error, operation: "legacy read")
        }
    }

    public func compareAndSwap(
        scope: String, accountID: String, expected: TraktSharedRecord?, value: Data
    ) async throws -> TraktSharedRecord {
        try await requireAccount(accountID)
        let id = schema.recordID(forRecordName: Self.recordName(scope: scope))
        let record: CKRecord
        if let expected {
            guard let restored = CloudSyncSystemFields.record(from: expected.version),
                  restored.recordID == id, schema.matches(restored) else {
                throw TraktSharedRefreshError.invalidRecord
            }
            record = restored
        } else {
            // Saving an already-existing zone is idempotent. No new record type
            // or field is introduced here (production CK schema stays unchanged).
            do { _ = try await container.privateCloudDatabase.save(CKRecordZone(zoneID: schema.zoneID)) }
            catch { throw Self.mapError(error, operation: "zone save") }
            try await requireAccount(accountID)
            record = CKRecord(recordType: schema.recordType, recordID: id)
        }
        record[schema.fieldKind] = "trackerToken" as CKRecordValue
        record[schema.fieldEditedAt] = Int64(Date().timeIntervalSince1970 * 1_000) as CKRecordValue
        record.encryptedValues[schema.fieldValue] = try JSONEncoder().encode(
            Envelope(accountID: accountID, value: value)
        ) as CKRecordValue
        do {
            let result = try await container.privateCloudDatabase.modifyRecords(
                saving: [record], deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: true
            )
            guard let saved = result.saveResults[id] else { throw TraktSharedRefreshError.unavailable }
            let confirmed = try saved.get()
            try await requireAccount(accountID)
            return try decode(confirmed, accountID: accountID)
        } catch let error as CKError where error.code == .serverRecordChanged {
            throw TraktSharedRefreshError.conflict
        } catch let error as TraktSharedRefreshError {
            throw error
        } catch {
            throw Self.mapError(error, operation: "conditional save")
        }
    }

    static func mapError(_ error: Error, operation: String) -> Error {
        if error is CancellationError || error is TraktSharedRefreshError { return error }
        let ns = error as NSError
        // CloudKit descriptions/userInfo can contain record or account data.
        PlozzLog.sync.error("Trakt iCloud \(operation) failed: domain=\(ns.domain) code=\(ns.code)")
        guard let cloud = error as? CKError else { return TraktSharedRefreshError.unavailable }
        switch cloud.code {
        case .networkFailure, .networkUnavailable, .serviceUnavailable, .requestRateLimited,
             .zoneBusy, .notAuthenticated, .accountTemporarilyUnavailable:
            return TraktSharedRefreshError.unavailable
        default:
            return TraktSharedRefreshError.cloudFailure(code: cloud.code.rawValue)
        }
    }

    private func decode(_ record: CKRecord, accountID: String) throws -> TraktSharedRecord {
        guard schema.matches(record),
              let data = record.encryptedValues[schema.fieldValue] as? Data else {
            throw TraktSharedRefreshError.invalidRecord
        }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
            throw TraktSharedRefreshError.invalidRecord
        }
        guard envelope.accountID == accountID else { throw TraktSharedRefreshError.accountChanged }
        return .init(value: envelope.value, version: CloudSyncSystemFields.archive(record))
    }
}
