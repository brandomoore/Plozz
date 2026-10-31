import XCTest
@testable import MediaTransportHTTP

final class TransportSessionDelegateTests: XCTestCase {
    private let origin = TransportOrigin(url: URL(string: "https://nas.example.com/")!)!

    func testAnonymousMediaNeverAnswersPasswordChallenges() {
        let delegate = TransportSessionDelegate(
            credential: .anonymous, trustPolicy: .system, origin: origin, isAnonymousMediaSession: true
        )
        for method in [NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest] {
            let space = URLProtectionSpace(
                host: origin.host, port: origin.port, protocol: origin.scheme, realm: "media", authenticationMethod: method
            )
            guard case .reject(.authenticationFailed) = delegate.passwordChallengeDecision(space: space, previousFailureCount: 0) else {
                return XCTFail("anonymous media must not fall back to stored credentials")
            }
        }
    }

    func testDigestChallengeUsesSessionOnlyPasswordCredential() {
        let decision = evaluateChallenge(
            authenticationMethod: NSURLAuthenticationMethodHTTPDigest,
            credential: .password(username: "user", password: "secret", policy: .automatic)
        )

        guard case .useCredential(let credential) = decision else {
            return XCTFail("expected useCredential")
        }
        XCTAssertEqual(credential.user, "user")
        XCTAssertEqual(credential.password, "secret")
        XCTAssertEqual(credential.persistence, .forSession)
    }

    func testDigestOnlyRejectsBasicChallenge() {
        let decision = evaluateChallenge(
            authenticationMethod: NSURLAuthenticationMethodHTTPBasic,
            credential: .password(username: "user", password: "secret", policy: .digestOnly)
        )

        guard case .reject(.authenticationSchemeNotPermitted(scheme: "basic")) = decision else {
            return XCTFail("expected Basic to be rejected")
        }
    }

    func testBasicAllowedAnswersBasicChallenge() {
        let decision = evaluateChallenge(
            authenticationMethod: NSURLAuthenticationMethodHTTPBasic,
            credential: .password(username: "user", password: "secret", policy: .basicAllowed)
        )

        guard case .useCredential(let credential) = decision else {
            return XCTFail("expected useCredential")
        }
        XCTAssertEqual(credential.persistence, .forSession)
    }

    func testRejectedCredentialIsNotRetried() {
        let decision = evaluateChallenge(
            authenticationMethod: NSURLAuthenticationMethodHTTPDigest,
            credential: .password(username: "user", password: "secret", policy: .automatic),
            previousFailureCount: 1
        )

        guard case .reject(.authenticationFailed) = decision else {
            return XCTFail("expected authenticationFailed")
        }
    }

    func testChallengeForDifferentOriginIsRejected() {
        let decision = evaluateChallenge(
            host: "attacker.example.net",
            authenticationMethod: NSURLAuthenticationMethodHTTPDigest,
            credential: .password(username: "user", password: "secret", policy: .automatic)
        )

        guard case .reject(.invalidOrigin) = decision else {
            return XCTFail("expected invalidOrigin")
        }
    }

    func testAnonymousCredentialDoesNotAnswerPasswordChallenge() {
        let decision = evaluateChallenge(
            authenticationMethod: NSURLAuthenticationMethodHTTPBasic,
            credential: .anonymous
        )

        guard case .performDefaultHandling = decision else {
            return XCTFail("expected performDefaultHandling")
        }
    }

    func testWindowsAuthenticationAllowsNextSupportedChallengeWithoutCredentials() {
        for policy in [PasswordAuthPolicy.automatic, .basicAllowed, .digestOnly] {
            let delegate = TransportSessionDelegate(
                credential: .password(username: "user", password: "fixture", policy: policy),
                trustPolicy: .system, origin: origin
            )
            for method in [NSURLAuthenticationMethodNTLM, NSURLAuthenticationMethodNegotiate] {
                let space = URLProtectionSpace(
                    host: origin.host, port: origin.port, protocol: origin.scheme,
                    realm: "fixture", authenticationMethod: method
                )
                XCTAssertEqual(delegate.unsupportedChallengeDisposition(space), .rejectProtectionSpace)
            }
        }
    }

    func testAnonymousDeliveryDoesNotNegotiateAnotherAuthenticationScheme() {
        let delegate = TransportSessionDelegate(
            credential: .anonymous, trustPolicy: .system, origin: origin, isAnonymousMediaSession: true
        )
        let space = URLProtectionSpace(
            host: origin.host, port: origin.port, protocol: origin.scheme,
            realm: "fixture", authenticationMethod: NSURLAuthenticationMethodNTLM
        )
        XCTAssertEqual(delegate.unsupportedChallengeDisposition(space), .cancelAuthenticationChallenge)
    }

    private func evaluateChallenge(
        host: String = "nas.example.com",
        authenticationMethod: String,
        credential: WebDAVCredential,
        previousFailureCount: Int = 0
    ) -> PasswordChallengeDecision {
        let delegate = TransportSessionDelegate(
            credential: credential,
            trustPolicy: .system,
            origin: origin
        )
        let protectionSpace = URLProtectionSpace(
            host: host,
            port: 443,
            protocol: "https",
            realm: "test",
            authenticationMethod: authenticationMethod
        )
        return delegate.passwordChallengeDecision(
            space: protectionSpace,
            previousFailureCount: previousFailureCount
        )
    }
}
