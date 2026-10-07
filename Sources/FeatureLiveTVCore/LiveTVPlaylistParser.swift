import CoreNetworking
import Foundation

public typealias LiveTVSourceImportError = CoreNetworking.LiveTVSourceImportError

public struct LiveTVPlaylistImport: Codable, Sendable {
    public let channels: [LiveTVPrototypeChannel]
    public let entryCount: Int
    public let skippedEntryCount: Int
    public let declaredGuideURLs: [URL]
    public let permitsPersistence: Bool
    public let originURL: URL?

    public init(
        channels: [LiveTVPrototypeChannel], entryCount: Int, skippedEntryCount: Int,
        declaredGuideURLs: [URL] = [], permitsPersistence: Bool = true, originURL: URL? = nil
    ) {
        self.channels = channels
        self.entryCount = entryCount
        self.skippedEntryCount = skippedEntryCount
        self.declaredGuideURLs = declaredGuideURLs
        self.permitsPersistence = permitsPersistence
        self.originURL = originURL
    }

    fileprivate init(_ result: M3UPlaylistImport) {
        self.init(
            channels: result.channels.map {
                LiveTVPrototypeChannel(
                    id: $0.id, number: $0.number, name: $0.name, category: $0.category,
                    symbol: $0.symbol, accent: $0.accent, source: .iptv, tagline: $0.tagline,
                    logoURL: $0.logoURL, streamURL: $0.streamURL,
                    logoNeedsDarkBackground: $0.logoNeedsDarkBackground,
                    guideID: $0.guideID, guideName: $0.guideName, httpHeaders: $0.httpHeaders,
                    language: $0.language, country: $0.country, groups: $0.groups
                )
            },
            entryCount: result.entryCount, skippedEntryCount: result.skippedEntryCount,
            declaredGuideURLs: result.declaredGuideURLs, permitsPersistence: result.permitsPersistence,
            originURL: result.originURL
        )
    }
}

public struct LiveTVPlaylistParser: Sendable {
    public static let maximumBytes = M3UPlaylistParser.maximumBytes
    public static let maximumEntries = M3UPlaylistParser.maximumEntries
    public static let maximumLineBytes = M3UPlaylistParser.maximumLineBytes
    private let parser: M3UPlaylistParser

    public init(baseURL: URL? = nil) { parser = .init(baseURL: baseURL) }

    public func parse(_ data: Data) throws -> LiveTVPlaylistImport {
        try LiveTVPlaylistImport(parser.parse(data))
    }

    public func parse(_ text: String) throws -> LiveTVPlaylistImport {
        try LiveTVPlaylistImport(parser.parse(text))
    }

    public func makeStream() -> Stream { Stream(stream: parser.makeStream()) }

    public struct Stream: Sendable {
        fileprivate var stream: M3UPlaylistParser.Stream
        public var hasPlayableHLSTag: Bool { stream.hasPlayableHLSTag }
        public var byteCount: Int { stream.byteCount }
        var bufferedByteCount: Int { stream.bufferedByteCount }
        public mutating func append(_ data: Data) throws { try stream.append(data) }
        public mutating func append(_ byte: UInt8) throws { try stream.append(byte) }
        public mutating func finish() throws -> LiveTVPlaylistImport { try LiveTVPlaylistImport(stream.finish()) }
    }
}
