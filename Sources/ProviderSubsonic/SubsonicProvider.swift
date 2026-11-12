import CoreModels
import CoreNetworking
import CryptoKit
import Foundation

public final class SubsonicProvider: MediaProvider, MusicProvider, CapabilityReporting,
    MusicFeedbackProviding, ProviderHTTPResourceResolving, AuthenticatedArtworkProviding, Sendable {
    public let kind: ProviderKind = .subsonic
    public let session: UserSession
    public var capabilities: ProviderCapability { [.music] }
    private let context: ProviderResolutionContext
    private let client: SubsonicClient
    private let trackCatalog: SubsonicTrackCatalog
    private let listeningSession = SubsonicListeningSession()

    public static let defaultHTTP: any HTTPClient = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        return URLSessionHTTPClient(session: OfflineNetworkSession.make(configuration: configuration))
    }()

    public init(context: ProviderResolutionContext, http: any HTTPClient = SubsonicProvider.defaultHTTP) throws {
        guard context.session.server.provider == .subsonic else { throw AppError.invalidResponse }
        self.context = context
        session = context.session
        client = SubsonicClient(
            baseURL: try SubsonicClient.normalizeAddress(context.session.server.baseURL.absoluteString),
            credential: try SubsonicCredential.decode(context.session.accessToken), http: http
        )
        trackCatalog = SubsonicTrackCatalog(client: client)
    }

    public static func signIn(
        address: String, username: String, password: String, usesAPIKey: Bool,
        deviceID: String, http: any HTTPClient = SubsonicProvider.defaultHTTP
    ) async throws -> UserSession {
        let username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty, !password.isEmpty else { throw AppError.invalidCredentials }
        let baseURL = try SubsonicClient.normalizeAddress(address)
        let credential = usesAPIKey
            ? SubsonicCredential(username: username, token: nil, salt: nil, apiKey: password)
            : .password(username: username, password: password)
        let client = SubsonicClient(baseURL: baseURL, credential: credential, http: http)
        _ = try await client.request("ping")
        var userID = username
        if usesAPIKey {
            guard let user = try await client.request("getUser", [
                .init(name: "username", value: username)
            ]).user, user.username.caseInsensitiveCompare(username) == .orderedSame else {
                throw AppError.unauthorized
            }
            userID = user.username
        }
        // The API has no universal server UUID; keep identity tied to the exact origin and subpath.
        let identity = SHA256.hash(data: Data(baseURL.absoluteString.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return UserSession(
            server: MediaServer(id: identity, name: baseURL.host ?? "Subsonic",
                                baseURL: baseURL, provider: .subsonic),
            userID: userID, userName: userID, deviceID: deviceID,
            accessToken: try credential.encoded()
        )
    }

    public func libraries() async throws -> [MediaLibrary] { try await musicLibraries() }

    public func musicLibraries() async throws -> [MediaLibrary] {
        _ = try await client.request("ping")
        return [MediaLibrary(id: "music", title: session.server.name, kind: .folder, isMusic: true)]
    }

    public func musicItems(
        in containerID: String, kind: MusicItemKind, page: PageRequest, libraryIDs: [String]?
    ) async throws -> MusicPage {
        guard libraryIDs?.contains("music") != false else {
            return MusicPage(startIndex: page.startIndex)
        }
        return try await musicItems(in: containerID, kind: kind, page: page)
    }

    public func musicItems(in containerID: String, kind: MusicItemKind, page: PageRequest) async throws -> MusicPage {
        guard page.startIndex >= 0, page.startIndex < Int.max - 501, page.limit > 0 else {
            throw AppError.invalidResponse
        }
        let limit = min(page.limit, 500)
        switch kind {
        case .artist:
            let response = try await client.request("getArtists")
            guard let artists = response.artists else { throw AppError.invalidResponse }
            let all = (artists.index ?? []).flatMap { $0.artist ?? [] }
            return MusicPage(artists: slice(all, page).map(mapArtist), startIndex: page.startIndex,
                             totalCount: all.count)
        case .album:
            if !containerID.isEmpty {
                let all = try await artistNode(containerID).albums ?? []
                return MusicPage(albums: slice(all, page).map(mapAlbum), startIndex: page.startIndex,
                                 totalCount: all.count)
            }
            let response = try await client.request("getAlbumList2", [
                .init(name: "type", value: page.sort.field == .dateAdded ? "newest" : "alphabeticalByName"),
                .init(name: "size", value: String(limit)), .init(name: "offset", value: String(page.startIndex))
            ])
            guard let list = response.albumList2 else { throw AppError.invalidResponse }
            let values = list.album ?? []
            return MusicPage(albums: values.map(mapAlbum), startIndex: page.startIndex,
                             totalCount: page.startIndex + values.count + (values.isEmpty ? 0 : 1))
        case .track:
            if !containerID.isEmpty {
                let all = try await tracks(in: containerID)
                return MusicPage(tracks: slice(all, page), startIndex: page.startIndex, totalCount: all.count)
            }
            let result = try await trackCatalog.page(start: page.startIndex, limit: limit)
            return MusicPage(tracks: result.nodes.map(mapTrack), startIndex: page.startIndex,
                             totalCount: result.total)
        case .playlist:
            let response = try await client.request("getPlaylists")
            guard let playlists = response.playlists else { throw AppError.invalidResponse }
            let all = playlists.playlist ?? []
            return MusicPage(playlists: slice(all, page).map {
                MusicPlaylist(id: "playlist:" + $0.id, title: $0.name ?? "",
                              artworkURL: artwork($0.coverArt), trackCount: $0.songCount,
                              totalDuration: $0.duration)
            }, startIndex: page.startIndex, totalCount: all.count)
        case .genre:
            let response = try await client.request("getGenres")
            guard let genres = response.genres else { throw AppError.invalidResponse }
            let all = genres.genre ?? []
            return MusicPage(genres: slice(all, page).map { MusicGenre(id: $0.value, name: $0.value) },
                             startIndex: page.startIndex, totalCount: all.count)
        }
    }

    public func artist(id: String) async throws -> MusicArtist { mapArtist(try await artistNode(id)) }
    public func album(id: String) async throws -> MusicAlbum { mapAlbum(try await albumNode(id)) }

    public func tracks(in containerID: String) async throws -> [MusicTrack] {
        if containerID.hasPrefix("playlist:") {
            let response = try await client.request("getPlaylist", [
                .init(name: "id", value: String(containerID.dropFirst("playlist:".count)))
            ])
            guard let playlist = response.playlist else { throw AppError.notFound }
            return (playlist.entry ?? []).map(mapTrack)
        }
        return (try await albumNode(containerID).song ?? []).map(mapTrack)
    }

    private func artistNode(_ id: String) async throws -> SubsonicNode {
        guard let node = try await client.request("getArtist", [.init(name: "id", value: id)]).artist else {
            throw AppError.notFound
        }
        return node
    }

    private func albumNode(_ id: String) async throws -> SubsonicNode {
        guard let node = try await client.request("getAlbum", [.init(name: "id", value: id)]).album else {
            throw AppError.notFound
        }
        return node
    }

    private func songNode(_ id: String) async throws -> SubsonicNode {
        guard let node = try await client.request("getSong", [.init(name: "id", value: id)]).song else {
            throw AppError.notFound
        }
        return node
    }

    public func audioPlaybackInfo(for trackID: String, queueContext: [String]?) async throws -> AudioPlaybackRequest {
        let song = try await songNode(trackID)
        let direct = ["mp3", "aac", "m4a", "flac", "alac", "wav", "aiff", "aif", "mp4"]
            .contains(song.suffix?.lowercased() ?? "")
        let resource = try AuthenticatedHTTPResource(pathBase: .configuredBaseURL, path: "rest/stream.view", queryItems: [
            .init(name: "id", value: trackID),
            .init(name: "format", value: direct ? "raw" : "mp3")
        ])
        let locator = try AuthenticatedHTTPPlaybackLocator(
            provider: .subsonic, accountID: context.accountID, credentialRevision: context.credentialRevision,
            itemID: trackID, deliveryMode: direct ? .directFile : .serverTranscode,
            formatHint: MediaFormatHint(container: direct ? song.suffix : "mp3"),
            purpose: .audioStream, resource: resource
        )
        return AudioPlaybackRequest(
            track: mapTrack(song), playbackSource: .authenticatedHTTP(locator),
            isTranscoding: !direct,
            quality: PlaybackQuality(isDirectPlay: direct, codec: song.suffix, container: song.suffix,
                                     bitrate: direct ? song.bitRate.flatMap {
                                         (0...Int.max / 1000).contains($0) ? $0 * 1000 : nil
                                     } : nil,
                                     sampleRate: direct ? song.samplingRate : nil,
                                     bitDepth: direct ? song.bitDepth : nil,
                                     channels: song.channelCount, transcodeCodec: direct ? nil : "mp3")
        )
    }

    public func resolveHTTPResource(_ locator: AuthenticatedHTTPPlaybackLocator) async throws -> URL {
        guard locator.provider == kind, locator.accountID == context.accountID,
              locator.credentialRevision == context.credentialRevision,
              locator.purpose == .audioStream,
              locator.resource.pathBase == .configuredBaseURL,
              locator.resource.path == "rest/stream.view",
              locator.resource.queryItems.count == 2,
              locator.resource.queryItems.contains(where: { $0.name == "id" && $0.value == locator.itemID }),
              locator.resource.queryItems.contains(where: {
                  $0.name == "format" && ["raw", "mp3"].contains($0.value ?? "")
              }),
              let url = client.url("stream", locator.resource.queryItems.map {
                  URLQueryItem(name: $0.name, value: $0.value)
              }) else { throw AppError.unauthorized }
        return url
    }

    public var musicFeedbackKind: MusicFeedbackKind { .favorite }
    public func musicFeedback(for trackID: String) async throws -> MusicFeedback {
        .favorite(try await songNode(trackID).starred != nil)
    }
    public func setMusicFeedback(_ feedback: MusicFeedback, for trackID: String) async throws {
        guard case let .favorite(value) = feedback else { throw AppError.invalidResponse }
        _ = try await client.request(value ? "star" : "unstar", [.init(name: "id", value: trackID)])
    }

    public func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {
        let submit = await listeningSession.shouldSubmit(progress, event: event)
        if event == .start {
            _ = try await client.request("scrobble", [
                .init(name: "id", value: progress.itemID), .init(name: "submission", value: "false")
            ])
        } else if submit {
            _ = try await client.request("scrobble", [
                .init(name: "id", value: progress.itemID), .init(name: "submission", value: "true")
            ])
        }
    }

    public func musicImageURL(id: String, maxWidth: Int?) -> URL? { artwork(id, size: maxWidth) }
    public func ownsPersistedImageURL(_ persistedURL: URL) -> Bool {
        AuthenticatedArtworkReference(url: persistedURL)?.accountID == context.accountID
    }
    public func reauthenticatedImageURL(_ persistedURL: URL, maxWidth: Int?) -> URL? {
        guard let reference = AuthenticatedArtworkReference(url: persistedURL),
              reference.accountID == context.accountID else { return nil }
        return artwork(reference.resourceID, size: maxWidth ?? reference.size)
    }
    public func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
    private func artwork(_ id: String?, size: Int? = 600) -> URL? {
        guard let id, !id.isEmpty else { return nil }
        return AuthenticatedArtworkReference(
            accountID: context.accountID, credentialRevision: context.credentialRevision,
            resourceID: id, size: size
        ).url
    }

    public func artworkData(for reference: AuthenticatedArtworkReference) async throws -> Data {
        guard reference.accountID == context.accountID,
              reference.credentialRevision == context.credentialRevision else { throw AppError.unauthorized }
        let endpoint = Endpoint(
            path: "/rest/getCoverArt.view",
            queryItems: client.query([
                .init(name: "id", value: reference.resourceID),
                .init(name: "size", value: String(min(max(reference.size ?? 600, 1), 2000)))
            ]),
            headers: ["Cache-Control": "no-store"],
            redirectPolicy: .sameOrigin, allowsAutomaticAddressRetry: false
        )
        return try await client.http.send(endpoint, baseURL: client.baseURL).0
    }

    private func mapArtist(_ node: SubsonicNode) -> MusicArtist {
        MusicArtist(id: node.id, name: node.name ?? "", artworkURL: artwork(node.coverArt),
                    albumCount: node.albumCount)
    }
    private func mapAlbum(_ node: SubsonicNode) -> MusicAlbum {
        MusicAlbum(id: node.id, title: node.name ?? node.title ?? "", artistName: node.artist,
                   artistID: node.artistId, year: node.year, artworkURL: artwork(node.coverArt),
                   trackCount: node.songCount, totalDuration: node.duration,
                   genres: node.genre.map { [$0] } ?? [])
    }
    private func mapTrack(_ node: SubsonicNode) -> MusicTrack {
        MusicTrack(id: node.id, title: node.title ?? node.name ?? "", albumTitle: node.album,
                   albumID: node.albumId, artistName: node.artist, artistID: node.artistId,
                   trackNumber: node.track, discNumber: node.discNumber,
                   duration: node.duration, artworkURL: artwork(node.coverArt))
    }
    private func slice<T>(_ values: [T], _ page: PageRequest) -> [T] {
        Array(values.dropFirst(page.startIndex).prefix(page.limit))
    }

    // Music-only accounts have no video catalogue. No video endpoint is contacted.
    public func continueWatching(limit: Int) async throws -> [MediaItem] { [] }
    public func latest(limit: Int) async throws -> [MediaItem] { [] }
    public func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
    public func item(id: String) async throws -> MediaItem { throw AppError.notFound }
    public func children(of itemID: String) async throws -> [MediaItem] { throw AppError.notFound }
    public func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        throw AppError.notFound
    }
    public func playbackInfo(for itemID: String) async throws -> PlaybackRequest { throw AppError.notFound }
}
