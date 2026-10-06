import Foundation

enum CloudSyncEntitlementPolicy {
    static func permits(container: String, profileData: Data?, requiresProof: Bool) -> Bool {
        guard let data = profileData,
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
              let profile = try? PropertyListSerialization.propertyList(
                from: data[start.lowerBound..<end.upperBound], format: nil) as? [String: Any],
              let entitlements = profile["Entitlements"] as? [String: Any] else {
            return !requiresProof
        }
        let containers = entitlements["com.apple.developer.icloud-container-identifiers"] as? [String]
        return containers?.contains(container) == true
    }
}
