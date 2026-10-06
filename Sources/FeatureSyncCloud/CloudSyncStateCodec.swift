import CoreSecureStore
import CryptoKit
import Foundation

/// CloudKit encrypted fields are plaintext again in the local ledger.
public struct CloudSyncStateCodec: Sendable {
    enum Failure: Error { case invalidEnvelope, invalidKey, keyUnavailable, tooLarge, unavailable }
    static let maximumBytes = 256 * 1_024 * 1_024
    private static let prefix = Data("Plozz.CloudSync.Sealed.v1\n".utf8)
    private let secureStore: any SecureStore
    private let keyName: String
    private let context: Data

    public init(context: String, secureStore: any SecureStore) {
        self.secureStore = secureStore
        self.context = Data(context.utf8)
        keyName = SHA256.hash(data: self.context).map { String(format: "%02x", $0) }.joined()
    }

    static func deviceLocal(context: String) -> Self {
        .init(context: context, secureStore: KeychainStore(
            service: "com.plozz.cloudSync.localEncryption",
            userIndependent: false, fallbackToPerUser: false, synchronizable: false
        ))
    }

    static func isSealed(_ data: Data) -> Bool { data.starts(with: prefix) }

    func encode(_ data: Data) throws -> Data {
        guard data.count <= Self.maximumBytes else { throw Failure.tooLarge }
        let sealed = try AES.GCM.seal(data, using: key(create: true), authenticating: context)
        guard let combined = sealed.combined else { throw Failure.invalidEnvelope }
        return Self.prefix + combined
    }

    func decode(_ data: Data) throws -> Data {
        guard data.count <= Self.maximumBytes + Self.prefix.count + 28 else { throw Failure.tooLarge }
        guard Self.isSealed(data) else { throw Failure.invalidEnvelope }
        return try AES.GCM.open(
            AES.GCM.SealedBox(combined: data.dropFirst(Self.prefix.count)),
            using: key(create: false), authenticating: context
        )
    }

    private func key(create: Bool) throws -> SymmetricKey {
        if let stored = try secureStore.readString(for: keyName) { return try decodeKey(stored) }
        guard create else { throw Failure.keyUnavailable }
        let encoded = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0).base64EncodedString() }
        _ = try secureStore.insertStringIfAbsent(encoded, for: keyName)
        guard let stored = try secureStore.readString(for: keyName) else { throw Failure.keyUnavailable }
        return try decodeKey(stored)
    }

    private func decodeKey(_ value: String) throws -> SymmetricKey {
        guard let data = Data(base64Encoded: value), data.count == 32 else { throw Failure.invalidKey }
        return SymmetricKey(data: data)
    }
}
