import Foundation

/// Follow the matched article's language link, rather than guessing a translated
/// title or searching another edition for a potentially different work/person.
enum WikipediaLocalizedText {
    struct Link: Decodable, Sendable {
        let lang: String
        let title: String

        private enum CodingKeys: String, CodingKey { case lang, title, legacyTitle = "*" }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            lang = try values.decode(String.self, forKey: .lang)
            title = try values.decodeIfPresent(String.self, forKey: .title)
                ?? values.decode(String.self, forKey: .legacyTitle)
        }
    }

    static func edition(for language: String) -> String? {
        let code = Locale.Language(identifier: language).languageCode?.identifier.lowercased()
        guard let code, (2...3).contains(code.utf8.count),
              code.utf8.allSatisfy({ (97...122).contains($0) }) else { return nil }
        return code == "nb" ? "no" : code
    }

    static func linkParameters(language: String) -> [URLQueryItem] {
        guard let edition = edition(for: language), edition != "en" else { return [] }
        return [
            URLQueryItem(name: "lllang", value: edition),
            URLQueryItem(name: "lllimit", value: "1")
        ]
    }

    static func extract(
        links: [Link], language: String, http: MetadataDiscoveryHTTPClient
    ) async throws -> (text: String, url: URL)? {
        guard let edition = edition(for: language),
              let link = links.first(where: { $0.lang == edition }) else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "\(edition).wikipedia.org"
        components.path = "/w/api.php"
        components.queryItems = [
            URLQueryItem(name: "action", value: "query"),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "prop", value: "extracts"),
            URLQueryItem(name: "exintro", value: "1"),
            URLQueryItem(name: "explaintext", value: "1"),
            URLQueryItem(name: "redirects", value: "1"),
            URLQueryItem(name: "titles", value: link.title)
        ]
        let locale = Locale.Language(identifier: language)
        if edition == "zh", let script = locale.script?.identifier.lowercased() {
            components.queryItems?.append(URLQueryItem(name: "variant", value: "zh-\(script)"))
        } else if edition == "sr", let script = locale.script?.identifier.lowercased() {
            if let variant = ["latn": "sr-el", "cyrl": "sr-ec"][script] {
                components.queryItems?.append(URLQueryItem(name: "variant", value: variant))
            }
        }
        guard let url = components.url else { throw MetadataDiscoveryHTTPError.invalidResponse }
        let response = try await http.decode(Response.self, from: URLRequest(url: url))
        guard let text = response.query?.pages?.values.first?.extract?
            .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return (text, url)
    }

    private struct Response: Decodable, Sendable {
        let query: Query?
        struct Query: Decodable, Sendable { let pages: [String: Page]? }
        struct Page: Decodable, Sendable { let extract: String? }
    }
}
