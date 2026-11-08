import Foundation

public enum ExternalPlayer: String, Codable, CaseIterable, Sendable {
    case builtIn, nativePlayer, infuse, vlc, custom

    public var name: String {
        switch self {
        case .builtIn: "Plozz"
        case .nativePlayer: "Native Player"
        case .infuse: "Infuse"
        case .vlc: "VLC"
        case .custom: "Custom"
        }
    }

    public var scheme: String? {
        switch self {
        case .nativePlayer: "nativeplayer"
        case .infuse: "infuse"
        case .vlc: "vlc-x-callback"
        case .builtIn, .custom: nil
        }
    }

    public var returnsProgress: Bool { self == .nativePlayer || self == .infuse }

    public static var supported: [Self] {
        #if os(tvOS)
        [.builtIn, .nativePlayer, .infuse, .vlc]
        #else
        [.builtIn, .infuse, .vlc]
        #endif
    }
}

public struct ExternalPlayerSettings: Codable, Equatable, Sendable {
    public var player: ExternalPlayer
    public var customURLTemplate: String

    public init(player: ExternalPlayer = .builtIn, customURLTemplate: String = "") {
        self.player = player
        self.customURLTemplate = customURLTemplate
    }
}

public extension MediaItem {
    func requestingExternalPlayer(_ player: ExternalPlayer) -> MediaItem {
        var selection = self
        selection.externalPlayerOverride = player
        selection.discPlaybackOverride = .playVideo
        selection.explicitSourceSelection = true
        return selection
    }

    func effectiveExternalPlayer(default settings: ExternalPlayerSettings) -> ExternalPlayerSettings {
        var selection = settings
        if let externalPlayerOverride { selection.player = externalPlayerOverride }
        return selection
    }
}

public enum ExternalPlayerError: Error, Equatable, Sendable {
    case unavailable, unsupportedSource, invalidTemplate, invalidCallback, expiredCallback, persistence, preparationFailed
    case playbackFailed, progressSyncFailed, settingsPersistence

    public var message: LocalizedStringResource {
        switch self {
        case .unavailable:
            "The selected player isn't available on this device. You can play this video in Plozz instead."
        case .unsupportedSource:
            "This source needs Plozz's built-in player. External players require a directly accessible HTTP or HTTPS video without a separate audio stream or server conversion."
        case .invalidTemplate:
            "Enter an app URL with exactly one {url} placeholder, such as myplayer://play?url={url}. Web, file, and Plozz URLs aren't supported."
        case .invalidCallback:
            "The external player returned an invalid playback result. Your saved progress hasn't been changed."
        case .expiredCallback:
            "This external playback session has expired. Your saved progress hasn't been changed."
        case .persistence:
            "Plozz couldn't save the external playback session. Please try again."
        case .settingsPersistence:
            "Plozz couldn't load or save the player preference. Please select your player again."
        case .preparationFailed:
            "Plozz couldn't prepare this video for the selected app. You can try playing it in Plozz instead."
        case .playbackFailed:
            "The external player couldn't play this video. Your saved progress hasn't been changed."
        case .progressSyncFailed:
            "Plozz couldn't save the returned progress yet. It will retry when you return to the app."
        }
    }
}

/// App links contain authenticated media URLs. Never persist or log the result.
public enum ExternalPlayerURL {
    public static func isSupportedMediaURL(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil else { return false }
        let normalizedHost = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return !["localhost", "::1", "0.0.0.0", "0", "2130706433"].contains(normalizedHost)
            && !normalizedHost.hasPrefix("127.") && !normalizedHost.hasPrefix("::ffff:127.")
            && !normalizedHost.hasSuffix(".localhost")
            && url.pathExtension.lowercased() != "mpd"
    }

    public static func validateCustomTemplate(_ template: String) throws {
        guard template.count <= 2048,
              template.components(separatedBy: "{url}").count == 2,
              !template.contains(where: \.isWhitespace),
              let components = URLComponents(string: template.replacingOccurrences(of: "{url}", with: "media")),
              let scheme = components.scheme?.lowercased(),
              !["http", "https", "file", "data", "javascript"].contains(scheme),
              !scheme.hasPrefix("plozz"),
              !scheme.hasSuffix(".external-player"),
              components.user == nil, components.password == nil,
              let colon = template.firstIndex(of: ":"),
              let placeholder = template.range(of: "{url}"),
              placeholder.lowerBound > colon,
              !template.replacingOccurrences(of: "{url}", with: "").contains(where: { $0 == "{" || $0 == "}" })
        else { throw ExternalPlayerError.invalidTemplate }
    }

    public static func make(
        settings: ExternalPlayerSettings, mediaURL: URL, title: String,
        position: TimeInterval, subtitles: [URL] = [], callbackScheme: String, nonce: UUID
    ) throws -> URL {
        guard isSupportedMediaURL(mediaURL), position.isFinite, position >= 0,
              position < Double(Int.max) else { throw ExternalPlayerError.unsupportedSource }
        if settings.player == .custom {
            try validateCustomTemplate(settings.customURLTemplate)
            let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
            guard let encoded = mediaURL.absoluteString.addingPercentEncoding(withAllowedCharacters: unreserved),
                  let url = URL(string: settings.customURLTemplate.replacingOccurrences(of: "{url}", with: encoded))
            else { throw ExternalPlayerError.invalidTemplate }
            return url
        }
        guard let scheme = settings.player.scheme else { throw ExternalPlayerError.unavailable }
        var components = URLComponents()
        components.scheme = scheme
        components.host = "x-callback-url"
        components.path = settings.player == .vlc ? "/stream" : "/play"
        var query = [
            URLQueryItem(name: "url", value: mediaURL.absoluteString),
            URLQueryItem(name: "filename", value: title)
        ]
        if settings.player.returnsProgress {
            query.append(URLQueryItem(name: "position", value: String(Int(position))))
            for outcome in ["success", "error"] {
                var callback = URLComponents()
                callback.scheme = callbackScheme
                callback.host = "external-player"
                callback.path = "/" + outcome
                callback.queryItems = [URLQueryItem(name: "session", value: nonce.uuidString)]
                guard let url = callback.url else { throw ExternalPlayerError.invalidCallback }
                query.append(URLQueryItem(name: "x-" + outcome, value: url.absoluteString))
            }
        }
        let supportedSubtitles = subtitles.filter(isSupportedMediaURL)
        for url in supportedSubtitles.prefix(settings.player == .vlc ? 1 : 8) {
            query.append(URLQueryItem(name: "sub", value: url.absoluteString))
        }
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        components.percentEncodedQueryItems = query.map {
            URLQueryItem(name: $0.name, value: $0.value?.addingPercentEncoding(withAllowedCharacters: unreserved))
        }
        guard let url = components.url else { throw ExternalPlayerError.invalidTemplate }
        return url
    }
}
