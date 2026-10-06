import XCTest
@testable import FeatureSyncSetup
@testable import CoreModels

final class SyncPairingInviteCodecTests: XCTestCase {

    private func sampleInvite() -> SyncPairingInvite {
        SyncPairingInvite(
            serviceName: "AB4K",
            publicKeyData: SyncPairingIdentity().publicKeyData,
            context: SyncPairingContext()
        )
    }

    func testEncodedProducesUniversalLink() {
        let invite = sampleInvite()
        let encoded = invite.encoded()
        XCTAssertTrue(encoded.hasPrefix("https://plozz.app/pair#"),
                      "QR should encode an https universal link, got \(encoded)")
        XCTAssertEqual(SyncPairingInvite.decode(encoded), invite)
    }

    func testDecodeAcceptsLegacyCustomScheme() {
        let invite = sampleInvite()
        let legacy = "plozz-pair://" + invite.encodedPayload()
        XCTAssertEqual(SyncPairingInvite.decode(legacy), invite,
                       "Legacy plozz-pair:// strings must still decode")
    }

    func testDecodeAcceptsQueryFallback() {
        let invite = sampleInvite()
        let queryForm = "https://plozz.app/pair?d=" + invite.encodedPayload()
        XCTAssertEqual(SyncPairingInvite.decode(queryForm), invite)
    }

    func testDecodeAcceptsBarePayload() {
        let invite = sampleInvite()
        XCTAssertEqual(SyncPairingInvite.decode(invite.encodedPayload()), invite)
    }

    func testDecodeRejectsGarbage() {
        XCTAssertNil(SyncPairingInvite.decode("https://plozz.app/pair"))
        XCTAssertNil(SyncPairingInvite.decode("https://example.com/other#zzz"))
        XCTAssertNil(SyncPairingInvite.decode("not a url"))
    }

    func testFirstRunInvitesCannotCrossIntoRealOrDifferentTestHouseholds() {
        let installation = AppInstallation.firstRun(UUID())
        let invite = SyncPairingInvite(
            serviceName: "TEST", publicKeyData: SyncPairingIdentity().publicKeyData,
            context: SyncPairingContext(), installation: installation
        )
        XCTAssertTrue(invite.encoded().hasPrefix(installation.pairingURLPrefix))
        XCTAssertEqual(SyncPairingInvite.decode(invite.encoded(), installation: installation), invite)
        XCTAssertNil(SyncPairingInvite.decode(invite.encoded()))
        XCTAssertNil(SyncPairingInvite.decode(invite.encodedPayload()))
        XCTAssertNil(SyncPairingInvite.decode(
            invite.encodedPayload(), installation: .firstRun(UUID())
        ))
        XCTAssertNil(SyncPairingInvite.decode(sampleInvite().encoded(), installation: installation))
        XCTAssertNil(SyncPairingInvite.decode(sampleInvite().encodedPayload(), installation: installation))
    }
}
