import CoreModels
import CryptoKit
import CoreNetworking
import Foundation

enum IPTVMapping {
    static func listEntry(_ value: IPTVObject, library: String, categories: [String: String] = [:]) throws -> IPTVRecord {
        let kind: MediaItemKind = library == "series" ? .series : library == "movies" ? .movie : .video
        guard let nativeID = value.text(kind == .series ? "series_id" : "stream_id"),
              nativeID.allSatisfy(\.isNumber), let name = value.text("name") else {
            throw IPTVError.malformed
        }
        let prefix = kind == .series ? "series" : kind == .movie ? "movie" : "live"
        var record = IPTVRecord(
            item: MediaItem(
                id: prefix + ":" + nativeID, title: name, kind: kind,
                tags: Array(Set((value.array("category_ids").compactMap(\.text)
                    + (value.text("category_id").map { [$0] } ?? [])).compactMap { categories[$0] })).sorted(),
                posterURL: artwork(value.text("stream_icon") ?? value.text("cover")),
                libraryID: library,
                librarySortValues: LibrarySortValues(dateAdded: (value.number("added") ?? value.number("last_modified"))
                    .map { Date(timeIntervalSince1970: $0) })
            ),
            streamID: nativeID, container: value.text("container_extension"),
            guideID: value.text("epg_channel_id"), isLive: library == "live"
        )
        record = enrich(record, with: value)
        return record
    }

    static func enrich(_ record: IPTVRecord, with value: IPTVObject) -> IPTVRecord {
        var result = record
        result.item.overview = value.text("plot") ?? value.text("description") ?? record.item.overview
        if value.integer("is_adult") == 1 { result.item.officialRating = "18+" }
        result.item.posterURL = artwork(value.text("movie_image") ?? value.text("cover")) ?? record.item.posterURL
        result.item.backdropURL = value.array("backdrop_path").first?.text.flatMap(artwork)
            ?? artwork(value.text("backdrop_path")) ?? record.item.backdropURL
        if let genres = value.text("genre") {
            result.item.genres = genres.components(separatedBy: CharacterSet(charactersIn: ",/"))
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        if let tmdb = value.text("tmdb_id") ?? value.text("tmdb"), Int(tmdb).map({ $0 > 0 }) == true {
            result.item.providerIDs["tmdb"] = tmdb
        }
        if let imdb = value.text("imdb_id"), imdb.hasPrefix("tt") { result.item.providerIDs["imdb"] = imdb }
        if let duration = value.number("duration_secs"), duration > 0 { result.item.runtime = duration }
        else if let text = value.text("duration") {
            let parts = text.split(separator: ":").compactMap { Double($0) }
            if parts.count == 3 { result.item.runtime = parts[0] * 3_600 + parts[1] * 60 + parts[2] }
        }
        let date = value.text("releasedate") ?? value.text("releaseDate") ?? value.text("release_date")
        result.item.productionYear = date.flatMap { Int($0.prefix(4)) } ?? value.integer("year") ?? record.item.productionYear
        if let cast = value.text("cast") {
            result.item.people = cast.split(separator: ",").prefix(100).map {
                let name = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                return MediaPerson(id: "iptv-person:" + digest(name), name: name)
            }
        }
        return result
    }

    static func season(_ series: IPTVRecord, number: Int) -> IPTVRecord {
        let nativeID = series.streamID ?? series.item.id
        return IPTVRecord(
            item: MediaItem(
                id: "season:\(nativeID):\(number)", title: String(localized: "Season \(number)"), kind: .season,
                parentTitle: series.item.title, seasonNumber: number, seriesID: series.item.id,
                posterURL: series.item.posterURL, seriesPosterURL: series.item.posterURL,
                libraryID: "series"
            ), parentID: series.item.id
        )
    }

    static func episode(_ value: IPTVObject, series: IPTVRecord, season: IPTVRecord) throws -> IPTVRecord {
        guard let nativeID = value.text("id"), nativeID.allSatisfy(\.isNumber),
              let seriesID = series.streamID else { throw IPTVError.malformed }
        let number = value.integer("episode_num")
        let title = value.text("title") ?? number.map(String.init) ?? nativeID
        let result = IPTVRecord(
            item: MediaItem(
                id: "episode:\(seriesID):\(nativeID)", title: title, kind: .episode,
                parentTitle: series.item.title, seasonNumber: season.item.seasonNumber, episodeNumber: number,
                seriesID: series.item.id, seasonID: season.item.id,
                seriesPosterURL: series.item.posterURL, backdropURL: series.item.backdropURL, libraryID: "series"
            ), parentID: season.item.id, streamID: nativeID, container: value.text("container_extension")
        )
        return enrich(result, with: value.object("info"))
    }

    static func playlistEntry(_ entry: M3UPlaylistParser.CatalogEntry) -> [IPTVRecord] {
        let channel = entry.channel
        guard let url = channel.streamURL else { return [] }
        let attributes = entry.attributes
        let contentType = (attributes["tvg-type"] ?? attributes["type"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let path = url.path.lowercased()
        let episode = episodeIdentity(channel.name, attributes: attributes)
        let explicitlyLive = contentType == "live"
        let isSeries = !explicitlyLive && (
            contentType == "series" || contentType == "episode" || path.contains("/series/") || episode != nil
        )
        // A channel can serve a looping file; its container does not identify a movie.
        let isMovie = !explicitlyLive && (
            contentType == "movie" || contentType == "vod" || path.contains("/movie/") || (entry.duration ?? 0) > 0
        )
        let identity = digest([channel.guideID ?? "", channel.name, channel.groups.joined(separator: ";"),
                               url.lastPathComponent].joined(separator: "\u{1F}"))
        if isSeries, let episode {
            let seriesID = "series:" + digest(episode.title + "\u{1F}" + channel.groups.joined(separator: ";"))
            let series = IPTVRecord(item: MediaItem(
                id: seriesID, title: episode.title, kind: .series, posterURL: artwork(channel.logoURL?.absoluteString),
                libraryID: "series"
            ))
            let season = season(series, number: episode.season)
            let item = MediaItem(
                id: "episode:" + identity, title: channel.name, kind: .episode,
                parentTitle: episode.title, seasonNumber: episode.season, episodeNumber: episode.number,
                seriesID: seriesID, seasonID: season.item.id, runtime: entry.duration,
                seriesPosterURL: series.item.posterURL, libraryID: "series"
            )
            return [series, season, IPTVRecord(item: item, parentID: season.item.id, streamURL: url,
                                              headers: channel.httpHeaders)]
        }
        let live = !isMovie && !isSeries
        let item = MediaItem(
            id: (live ? "live:" : "movie:") + identity, title: channel.name, kind: live ? .video : .movie,
            tags: channel.groups, runtime: entry.duration, posterURL: artwork(channel.logoURL?.absoluteString),
            libraryID: live ? "live" : "movies"
        )
        return [IPTVRecord(item: item, streamURL: url, headers: channel.httpHeaders,
                           guideID: channel.guideID, channelNumber: channel.number, isLive: live)]
    }

    private static func episodeIdentity(_ name: String, attributes: [String: String])
        -> (title: String, season: Int, number: Int)? {
        if let title = attributes["series-name"], let season = attributes["season-number"].flatMap(Int.init),
           let number = attributes["episode-number"].flatMap(Int.init) { return (title, season, number) }
        let expression = try? NSRegularExpression(pattern: #"(?i)^(.+?)[ ._-]+S(\d{1,3})[ ._-]*E(\d{1,4})(?:\b|[ ._-])"#)
        guard let match = expression?.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
              let titleRange = Range(match.range(at: 1), in: name),
              let seasonRange = Range(match.range(at: 2), in: name),
              let episodeRange = Range(match.range(at: 3), in: name),
              let season = Int(name[seasonRange]), let number = Int(name[episodeRange]) else { return nil }
        return (String(name[titleRange]), season, number)
    }

    static func programme(_ value: IPTVObject, channelID: String, from: Date, to: Date) -> ServerLiveTVProgramme? {
        guard let start = value.number("start_timestamp"),
              let end = value.number("stop_timestamp") ?? value.number("end_timestamp"),
              end > start, start < to.timeIntervalSince1970, end > from.timeIntervalSince1970 else { return nil }
        func decoded(_ text: String?) -> String? {
            guard let text else { return nil }
            return Data(base64Encoded: text).flatMap { String(data: $0, encoding: .utf8) } ?? text
        }
        guard let title = decoded(value.text("title")), !title.isEmpty else { return nil }
        return ServerLiveTVProgramme(
            id: value.text("id") ?? "\(channelID):\(start)", channelID: channelID,
            title: title, overview: decoded(value.text("description")),
            startDate: Date(timeIntervalSince1970: start), endDate: Date(timeIntervalSince1970: end)
        )
    }

    static func artwork(_ text: String?) -> URL? {
        guard let text, let url = URL(string: text), LiveTVPlaylistSource.isSupportedURL(url) else { return nil }
        // Ordinary item caches must never become a credential store.
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              !(parts.queryItems ?? []).contains(where: { SensitiveQueryPolicy.isSensitive($0.name) }),
              !url.path.lowercased().contains("/live/"),
              !url.path.lowercased().contains("/movie/"),
              !url.path.lowercased().contains("/series/") else { return nil }
        return url
    }

    static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
