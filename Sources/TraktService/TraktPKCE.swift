import CryptoKit
import Foundation
import CoreModels

struct TraktPKCE: Sendable {
    let verifier: String
    let state: String
    let redirectURI: URL
    let authorizationURL: URL

    init(
        config: TraktConfig,
        verifier: String = Self.randomValue(),
        state: String = Self.randomValue()
    ) throws {
        guard let clientID = config.clientID,
              config.redirectURI.scheme == "https",
              config.redirectURI.host != nil,
              config.redirectURI.user == nil, config.redirectURI.password == nil,
              config.redirectURI.query == nil, config.redirectURI.fragment == nil,
              (43...128).contains(verifier.utf8.count),
              verifier.utf8.allSatisfy({
                  (65...90).contains($0) || (97...122).contains($0)
                      || (48...57).contains($0) || [45, 46, 95, 126].contains($0)
              }),
              !state.isEmpty else { throw AppError.invalidResponse }
        self.verifier = verifier
        self.state = state
        self.redirectURI = config.redirectURI
        var components = URLComponents(
            url: config.authBaseURL.appendingPathComponent("oauth/authorize"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: config.redirectURI.absoluteString),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        guard let url = components?.url else { throw AppError.invalidResponse }
        authorizationURL = url
    }

    func authorizationCode(from callback: URL) throws -> String {
        guard let actual = URLComponents(url: callback, resolvingAgainstBaseURL: false),
              let expected = URLComponents(url: redirectURI, resolvingAgainstBaseURL: false),
              actual.scheme == expected.scheme,
              actual.host == expected.host, actual.port == expected.port,
              actual.percentEncodedPath == expected.percentEncodedPath,
              actual.user == nil, actual.password == nil, actual.fragment == nil
        else { throw AppError.invalidResponse }
        let items = actual.queryItems ?? []
        guard items.filter({ $0.name == "state" }).count == 1,
              items.first(where: { $0.name == "state" })?.value == state
        else { throw AppError.invalidResponse }
        if items.contains(where: { $0.name == "error" }) {
            throw AppError.cancelled
        }
        guard items.filter({ $0.name == "code" }).count == 1,
              let code = items.first(where: { $0.name == "code" })?.value,
              !code.isEmpty else { throw AppError.invalidResponse }
        return code
    }

    private static func randomValue() -> String {
        var generator = SystemRandomNumberGenerator()
        return base64URL(Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
