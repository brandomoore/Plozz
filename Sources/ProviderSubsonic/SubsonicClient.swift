import CoreModels
import CoreNetworking
import CryptoKit
import Foundation

struct SubsonicCredential: Codable, Sendable {
    let username: String
    let token: String?
    let salt: String?
    let apiKey: String?

    static func password(username: String, password: String, salt: String = UUID().uuidString) -> Self {
        let token = Insecure.MD5.hash(data: Data((password + salt).utf8))
            .map { String(format: "%02x", $0) }.joined()
        return Self(username: username, token: token, salt: salt, apiKey: nil)
    }

    var query: [URLQueryItem] {
        if let apiKey { return [.init(name: "apiKey", value: apiKey)] }
        return [.init(name: "u", value: username), .init(name: "t", value: token),
                .init(name: "s", value: salt)]
    }

    func encoded() throws -> String {
        String(decoding: try JSONEncoder().encode(self), as: UTF8.self)
    }

    static func decode(_ value: String) throws -> Self {
        guard let credential = try? JSONDecoder().decode(Self.self, from: Data(value.utf8)),
              !credential.username.isEmpty,
              credential.apiKey?.isEmpty == false
                || (credential.token?.isEmpty == false && credential.salt?.isEmpty == false) else {
            throw AppError.unauthorized
        }
        return credential
    }
}

struct SubsonicClient: Sendable {
    let baseURL: URL
    let credential: SubsonicCredential
    let http: any HTTPClient

    static func normalizeAddress(_ value: String) throws -> URL {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              var parts = URLComponents(string: value.contains("://") ? value : "https://" + value),
              ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
              let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil else {
            throw AppError.invalidResponse
        }
        while parts.path.hasSuffix("/") { parts.path.removeLast() }
        if parts.path.hasSuffix("/rest") { parts.path.removeLast(5) }
        guard let url = parts.url else { throw AppError.invalidResponse }
        return url
    }

    func query(_ parameters: [URLQueryItem] = []) -> [URLQueryItem] {
        credential.query + [.init(name: "v", value: "1.16.1"),
                            .init(name: "c", value: "Plozz"), .init(name: "f", value: "json")] + parameters
    }

    func url(_ method: String, _ parameters: [URLQueryItem] = [], authenticated: Bool = true) -> URL? {
        guard var parts = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return nil }
        parts.path += "/rest/\(method).view"
        parts.queryItems = authenticated ? query(parameters) : parameters
        return parts.url
    }

    func request(_ method: String, _ parameters: [URLQueryItem] = []) async throws -> SubsonicResponse {
        try Task.checkCancellation()
        let endpoint = Endpoint(
            path: "/rest/\(method).view", queryItems: query(parameters), headers: ["Cache-Control": "no-store"],
            redirectPolicy: .sameOrigin, allowsAutomaticAddressRetry: false
        )
        let envelope = try await http.decode(SubsonicEnvelope.self, from: endpoint, baseURL: baseURL)
        try Task.checkCancellation()
        guard envelope.response.status == "ok" else {
            switch envelope.response.error?.code {
            case 40, 44: throw AppError.unauthorized
            case 50: throw AppError.accessRestricted
            case 70: throw AppError.notFound
            default: throw AppError.invalidResponse
            }
        }
        return envelope.response
    }
}

struct SubsonicEnvelope: Decodable {
    let response: SubsonicResponse
    enum CodingKeys: String, CodingKey { case response = "subsonic-response" }
}

struct SubsonicResponse: Decodable, Sendable {
    struct User: Decodable, Sendable { let username: String }
    struct Failure: Decodable, Sendable { let code: Int }
    struct Artists: Decodable, Sendable {
        struct Index: Decodable, Sendable { var artist: [SubsonicNode]? }
        var index: [Index]?
    }
    struct Albums: Decodable, Sendable { var album: [SubsonicNode]? }
    struct Playlists: Decodable, Sendable { var playlist: [SubsonicNode]? }
    struct Search: Decodable, Sendable { var song: [SubsonicNode]? }
    struct Genres: Decodable, Sendable {
        struct Genre: Decodable, Sendable { let value: String; var songCount: Int?; var albumCount: Int? }
        var genre: [Genre]?
    }
    let status: String
    var error: Failure?
    var user: User?
    var artists: Artists?
    var artist: SubsonicNode?
    var albumList2: Albums?
    var album: SubsonicNode?
    var song: SubsonicNode?
    var playlists: Playlists?
    var playlist: SubsonicNode?
    var searchResult3: Search?
    var genres: Genres?
}

struct SubsonicNode: Decodable, Sendable {
    let id: String
    var name: String?
    var title: String?
    var artist: String?
    var artistId: String?
    var album: String?
    var albumId: String?
    var coverArt: String?
    var albumCount: Int?
    var songCount: Int?
    var duration: Double?
    var year: Int?
    var track: Int?
    var discNumber: Int?
    var genre: String?
    var suffix: String?
    var bitRate: Int?
    var samplingRate: Int?
    var bitDepth: Int?
    var channelCount: Int?
    var starred: String?
    var played: String?
    var song: [SubsonicNode]?
    var entry: [SubsonicNode]?
    // Artist albums share the JSON "album" key with a song's album title.
    var albums: [SubsonicNode]?

    enum CodingKeys: String, CodingKey {
        case id, name, title, artist, artistId, album, albumId, coverArt, albumCount, songCount
        case duration, year, track, discNumber, genre, suffix, bitRate, samplingRate, bitDepth
        case channelCount, starred, played, song, entry
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        artist = try c.decodeIfPresent(String.self, forKey: .artist)
        artistId = try c.decodeIfPresent(String.self, forKey: .artistId)
        if let title = try? c.decode(String.self, forKey: .album) { album = title }
        else { albums = try c.decodeIfPresent([SubsonicNode].self, forKey: .album) }
        albumId = try c.decodeIfPresent(String.self, forKey: .albumId)
        coverArt = try c.decodeIfPresent(String.self, forKey: .coverArt)
        albumCount = try c.decodeIfPresent(Int.self, forKey: .albumCount)
        songCount = try c.decodeIfPresent(Int.self, forKey: .songCount)
        duration = try c.decodeIfPresent(Double.self, forKey: .duration)
        year = try c.decodeIfPresent(Int.self, forKey: .year)
        track = try c.decodeIfPresent(Int.self, forKey: .track)
        discNumber = try c.decodeIfPresent(Int.self, forKey: .discNumber)
        genre = try c.decodeIfPresent(String.self, forKey: .genre)
        suffix = try c.decodeIfPresent(String.self, forKey: .suffix)
        bitRate = try c.decodeIfPresent(Int.self, forKey: .bitRate)
        samplingRate = try c.decodeIfPresent(Int.self, forKey: .samplingRate)
        bitDepth = try c.decodeIfPresent(Int.self, forKey: .bitDepth)
        channelCount = try c.decodeIfPresent(Int.self, forKey: .channelCount)
        starred = try c.decodeIfPresent(String.self, forKey: .starred)
        played = try c.decodeIfPresent(String.self, forKey: .played)
        song = try c.decodeIfPresent([SubsonicNode].self, forKey: .song)
        entry = try c.decodeIfPresent([SubsonicNode].self, forKey: .entry)
    }
}
