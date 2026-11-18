import XCTest
@testable import MediaDownloads

final class DownloadNetworkPolicyTests: XCTestCase {

    private let wifi = DownloadNetworkConditions(
        isSatisfied: true, isExpensive: false, isConstrained: false
    )
    private let cellular = DownloadNetworkConditions(
        isSatisfied: true, isExpensive: true, isConstrained: false
    )
    private let lowData = DownloadNetworkConditions(
        isSatisfied: true, isExpensive: false, isConstrained: true
    )

    func testWifiOnlyDefaultAllowsWifiBlocksCellular() {
        let policy = DownloadNetworkPolicy.default
        XCTAssertFalse(policy.allowsExpensiveNetwork)
        XCTAssertTrue(policy.allows(wifi))
        XCTAssertFalse(policy.allows(cellular))
    }

    func testAllowingExpensivePermitsCellular() {
        let policy = DownloadNetworkPolicy(allowsExpensiveNetwork: true)
        XCTAssertTrue(policy.allows(cellular))
    }

    func testConstrainedNetworkPausesByDefaultButCanBeAllowed() {
        XCTAssertFalse(DownloadNetworkPolicy.default.allows(lowData))
        let permissive = DownloadNetworkPolicy(pausesOnConstrainedNetwork: false)
        XCTAssertTrue(permissive.allows(lowData))
    }

    func testUnsatisfiedNetworkNeverAllows() {
        let policy = DownloadNetworkPolicy(allowsExpensiveNetwork: true, pausesOnConstrainedNetwork: false)
        XCTAssertFalse(policy.allows(.unsatisfied))
    }

    func testMaxConcurrencyClampedToAtLeastOne() {
        XCTAssertEqual(DownloadNetworkPolicy(maxConcurrentDownloads: 0).maxConcurrentDownloads, 1)
        XCTAssertEqual(DownloadNetworkPolicy(maxConcurrentDownloads: 4).maxConcurrentDownloads, 4)
    }

    func testPolicyIsCodable() throws {
        let policy = DownloadNetworkPolicy(
            allowsExpensiveNetwork: true,
            quality: .hd1080,
            storageBudgetBytes: 5_000,
            maxConcurrentDownloads: 2,
            maximumBytesPerSecond: 1_250_000,
            cappedBackgroundBehavior: .continueAtFullSpeed
        )
        let data = try JSONEncoder().encode(policy)
        XCTAssertEqual(try JSONDecoder().decode(DownloadNetworkPolicy.self, from: data), policy)
    }

    func testRetiredTrackPreferencesDoNotAffectTheRemainingProfilePolicy() throws {
        let expected = DownloadNetworkPolicy(
            allowsExpensiveNetwork: true, pausesOnConstrainedNetwork: false,
            quality: .hd720, storageBudgetBytes: 5_000, maxConcurrentDownloads: 2,
            maximumBytesPerSecond: 1_250_000, cappedBackgroundBehavior: .continueAtFullSpeed
        )
        var legacy = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(expected)) as? [String: Any]
        )
        legacy["includesAllAudioTracks"] = true
        legacy["includesTextSubtitleTracks"] = false
        let restored = try JSONDecoder().decode(
            DownloadNetworkPolicy.self, from: JSONSerialization.data(withJSONObject: legacy)
        )
        XCTAssertEqual(restored, expected)
        let saved = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(restored)) as? [String: Any]
        )
        XCTAssertNil(saved["includesAllAudioTracks"])
        XCTAssertNil(saved["includesTextSubtitleTracks"])
    }

    func testLegacyDataSaverDecodesAsStandardDefinition() throws {
        let decoded = try JSONDecoder().decode(
            DownloadQuality.self,
            from: Data(#""dataSaver""#.utf8)
        )
        XCTAssertEqual(decoded, .sd480)
    }
}
