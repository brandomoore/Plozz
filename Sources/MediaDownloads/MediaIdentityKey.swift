import CoreModels
import CryptoKit
import Foundation

/// A stable, deterministic string form of a ``MediaIdentity`` used to key
/// download records and to name a download's on-disk folder.
///
/// It must be **stable across launches and app versions** (it addresses a pinned
/// file), so it is derived structurally from the identity's cases — never from a
/// Swift type name or a non-deterministic hash.
public enum MediaIdentityKey {
    /// The canonical key string for an identity, optionally scoped to one
    /// **version** (a specific file of a title).
    ///
    /// A title can exist as several files — 4K, 1080p, a remux — and each is a
    /// separately downloadable thing. Keying on the identity alone means one
    /// record per title, so a second version can't be stored. Appending the
    /// version id keeps each file its own record and its own on-disk folder,
    /// allowing playback to prefer a particular locally available version.
    ///
    /// A `nil`/empty version keeps the historic un-suffixed key, so records that
    /// genuinely have no version concept are unchanged.
    public static func string(for identity: MediaIdentity, versionID: String?) -> String {
        let base = string(for: identity)
        guard let versionID, !versionID.isEmpty else { return base }
        return "\(base)\u{1}ver\u{1}\(versionID)"
    }

    /// The canonical key string for an identity.
    public static func string(for identity: MediaIdentity) -> String {
        switch identity {
        case let .external(source, value):
            return "ext\u{1}\(source)\u{1}\(value)"
        case let .title(normalizedTitle, year, kind):
            return "title\u{1}\(normalizedTitle)\u{1}\(year.map(String.init) ?? "")\u{1}\(kind.rawValue)"
        case let .sameItemID(id):
            return "same\u{1}\(id)"
        }
    }

    /// A filesystem-safe folder name, preserving legacy base64url names when
    /// they fit the filesystem's component limit.
    public static func folderName(for identity: MediaIdentity) -> String {
        folderName(forKey: string(for: identity))
    }

    /// A filesystem-safe folder name for an already-computed key.
    public static func folderName(forKey key: String) -> String {
        folderName(forKey: key, maximumLength: 255)
    }

    static func folderName(forKey key: String, maximumLength: Int) -> String {
        let encoded = Data(key.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        guard encoded.utf8.count > maximumLength else { return encoded }
        // "." cannot occur in a legacy base64url name.
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return "sha256.\(digest)"
    }
}
