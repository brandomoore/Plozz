import XCTest
import CoreModels
@testable import FeatureAuthCore

final class SiloCredentialRotationTests: XCTestCase {
    func testRotationPreservesLoginRevisionAndInvalidatesTokenCache() throws {
        let store = AccountStore(secureStore: InMemorySecureStore())
        let account = Account(server: MediaServer(id: "server", name: "Silo", baseURL: URL(string: "https://silo.test")!, provider: .silo),
                              userID: "account:profile", userName: "Profile", deviceID: "device")
        try store.add(account, token: "first")
        XCTAssertEqual(store.token(for: account.id), "first")
        let persisted = try XCTUnwrap(store.loadAccounts().first)
        try store.rotateCredential(accountID: account.id, revision: persisted.credentialRevision,
                                   expected: "first", replacement: "second")
        XCTAssertEqual(store.token(for: account.id), "second")
        XCTAssertEqual(store.loadAccounts().first?.credentialRevision, persisted.credentialRevision)
        XCTAssertThrowsError(try store.rotateCredential(accountID: account.id, revision: persisted.credentialRevision,
                                                        expected: "first", replacement: "stale"))
    }

    func testRemovedAccountCannotBeResurrectedByLateRefresh() throws {
        let store = AccountStore(secureStore: InMemorySecureStore())
        let account = Account(server: MediaServer(id: "server", name: "Silo", baseURL: URL(string: "https://silo.test")!, provider: .silo),
                              userID: "account:profile", userName: "Profile", deviceID: "device")
        try store.add(account, token: "first")
        let revision = try XCTUnwrap(store.loadAccounts().first?.credentialRevision)
        try store.remove(id: account.id)
        XCTAssertThrowsError(try store.rotateCredential(accountID: account.id, revision: revision,
                                                        expected: "first", replacement: "late"))
        XCTAssertTrue(store.loadAccounts().isEmpty)
        XCTAssertNil(store.token(for: account.id))
    }
}
