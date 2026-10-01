import Foundation

/// Non-secret instructions describing how one network-share root should be
/// presented and indexed.
///
/// The configuration is optional on ``MediaServer`` so accounts written before
/// this feature continue to decode and retain the legacy automatic behavior.
public struct MediaShareLibraryConfiguration: Codable, Hashable, Sendable {
    public enum ContentType: String, Codable, Hashable, CaseIterable, Sendable {
        /// Infer movies and episodic content from the selected root and filenames.
        case automatic
        /// Treat playable files as movies, even when their names contain episode-like tokens.
        case movies
        /// Index files with episode evidence as television episodes.
        case tvShows
        /// Infer anime films and episodes, using anime parsing and metadata context.
        case anime
        /// Keep files browsable and playable without external movie/show matching.
        case personalVideos
    }

    /// User-visible name for the selected library root.
    public var name: String
    public var contentType: ContentType
    /// Retained for saved configurations from the former independent Anime toggle.
    public var isAnime: Bool

    public var usesAnimeMetadata: Bool {
        contentType == .anime || isAnime
    }

    public init(
        name: String,
        contentType: ContentType = .automatic,
        isAnime: Bool = false
    ) {
        self.name = name
        self.contentType = contentType
        self.isAnime = isAnime
    }
}
