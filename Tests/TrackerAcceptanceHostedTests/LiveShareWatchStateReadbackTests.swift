import CryptoKit
import Foundation
import Security
import XCTest

final class LiveShareWatchStateReadbackTests: XCTestCase {
    func testReadExactAuthorizedShareWatchEnvelope() throws {
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        guard environment["PLOZZ_LIVE_WATCH_STATE_READ"] == "1" else {
            throw XCTSkip("Opt-in readback of an explicitly selected live test profile and share.")
        }
        #if targetEnvironment(simulator)
        let simulator = try XCTUnwrap(environment["PLOZZ_LIVE_WATCH_STATE_SIMULATOR"])
        XCTAssertFalse(simulator.isEmpty)
        XCTAssertEqual(environment["SIMULATOR_UDID"], simulator)
        #else
        XCTFail("Live state readback requires an owned simulator.")
        return
        #endif
        // The normal application host supplies its own existing Keychain access.
        // Do not change access groups or read through an unentitled helper.
        XCTAssertEqual(Bundle.main.bundleIdentifier, "com.thatcube.Plozz")
        let profile = try XCTUnwrap(environment["PLOZZ_LIVE_WATCH_STATE_PROFILE"])
        let source = try XCTUnwrap(environment["PLOZZ_LIVE_WATCH_STATE_SOURCE"])
        guard !profile.isEmpty, profile.utf8.count <= 512,
              source.hasPrefix("share:"), source.utf8.count <= 512 else {
            XCTFail("Expected one explicit local-share profile/account scope.")
            return
        }
        let address = "com.plozz.local-state.localMediaWatch.source."
            + [profile, source, "state"].map { value in
                Data(value.utf8).base64EncodedString()
                    .replacingOccurrences(of: "+", with: "-")
                    .replacingOccurrences(of: "/", with: "_")
                    .replacingOccurrences(of: "=", with: "")
            }.joined(separator: ".")
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.plozz.app.local-state",
            kSecAttrAccount as String: address,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        #if os(tvOS)
        // Match DurableLocalStateStoreFactory's household namespace, without a per-user fallback.
        query[kSecUseUserIndependentKeychain as String] = kCFBooleanTrue
        #endif
        var stored: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &stored)
        var result: [String: Any] = [
            "profileID": profile, "sourceID": source, "storageKey": address,
            "status": status, "capturedAt": Date().timeIntervalSince1970,
            "readOnly": true, "found": status == errSecSuccess
        ]
        #if os(tvOS)
        result["userIndependentKeychain"] = true
        #else
        result["userIndependentKeychain"] = false
        #endif
        if status == errSecSuccess {
            let data = try XCTUnwrap(stored as? Data)
            XCTAssertLessThanOrEqual(data.count, 400_000)
            let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(envelope["version"] as? Int, 1)
            XCTAssertEqual(envelope["collection"] as? String, "localMediaWatch")
            XCTAssertEqual(envelope["address"] as? String, address)
            XCTAssertEqual(envelope["schemaID"] as? String, "com.plozz.local-media-watch.v1")
            let payload = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(envelope["payload"] as? String)))
            XCTAssertLessThanOrEqual(payload.count, 256 * 1024)
            let state = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
            let records = try XCTUnwrap(state["records"] as? [String: Any])
            XCTAssertLessThanOrEqual(records.count, 2_000)
            result["records"] = records
            result["envelopeSHA256"] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        } else {
            XCTAssertEqual(status, errSecItemNotFound, "Do not treat denied or failed reads as empty history.")
        }
        let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "live-share-watch-state"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
