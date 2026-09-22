import Foundation

struct SiloLibrary: Decodable, Sendable {
    let id: String
    let name: String
    let type: String
    let poster_url: String?
}

struct SiloCatalogPage: Decodable, Sendable {
    let items: [SiloItem]
    let total: Int
    let total_exact: Bool
    let window_cursor: String
    let page: SiloPage?
}

struct SiloItem: Decodable, Sendable {
    let content_id: String
    let type: String?
    let title: String
    let original_title: String?
    let overview: String?
    let year: Int?
    let runtime: Double?
    let duration_seconds: Double?
    let position_seconds: Double?
    let progress_updated_at: String?
    let added_at: String?
    let poster_url: String?
    let backdrop_url: String?
    let logo_url: String?
    let still_url: String?
    let series_id: String?
    let play_content_id: String?
    let series_title: String?
    let season_number: Int?
    let episode_number: Int?
    let genres: [String]?
    let studios: [String]?
    let content_rating: String?
    let release_date: String?
    let air_date: String?
    let imdb_id: String?
    let tmdb_id: String?
    let tvdb_id: String?
    let user_state: SiloUserState?
    let user_data: SiloWatchRollup?
    let versions: [SiloFileVersion]?
    let cast: [SiloCastCredit]?
    let intro: SiloMarker?
    let credits: SiloMarker?
    let recap: SiloMarker?
    let preview: SiloMarker?
}

struct SiloCastCredit: Decodable, Sendable {
    let name: String
    let person_id: String?
    let character: String?
    let photo_url: String?
}

struct SiloUserState: Decodable, Sendable {
    let played: Bool
    let is_favorite: Bool
    let in_watchlist: Bool
}

struct SiloWatchRollup: Decodable, Sendable {
    let played: Bool
    let position_seconds: Double?
    let duration_seconds: Double?
}

struct SiloFileVersion: Decodable, Sendable {
    let file_id: String
    let file_name: String?
    let edition_raw: String?
    let resolution: String
    let hdr: Bool?
    let codec_video: String
    let codec_audio: String
    let container: String
    let file_size: Int64
    let duration: Double
    let bitrate: Int
    let video_tracks: [SiloVideoTrack]?
    let audio_tracks: [SiloAudioTrack]?
    let subtitle_tracks: [SiloSubtitleTrack]?
}

struct SiloVideoTrack: Decodable, Sendable {
    let codec: String?
    let width: Int?
    let height: Int?
    let video_range: String?
    let video_range_type: String?
    let hdr10_plus: Bool?
    let dv_profile: Int?
}

struct SiloAudioTrack: Decodable, Sendable {
    let codec: String?
    let channels: Int?
    let layout: String?
    let profile: String?
    let language: String?
    let title: String?
    let `default`: Bool
}

struct SiloSubtitleTrack: Decodable, Sendable {
    let index: Int?
    let codec: String?
    let language: String?
    let title: String?
    let forced: Bool
    let `default`: Bool
    let external: Bool
}

struct SiloMarker: Decodable, Sendable {
    let start: Double
    let end: Double
}

struct SiloSections: Decodable, Sendable {
    let sections: [SiloSection]
}

struct SiloSection: Decodable, Sendable {
    let id: String
    let section_type: String
    let items: [SiloItem]
}

struct SiloProgressEntry: Decodable, Sendable {
    let media_item_id: String
    let position_seconds: Double
    let duration_seconds: Double
    let completed: Bool
    let updated_at: String
}
