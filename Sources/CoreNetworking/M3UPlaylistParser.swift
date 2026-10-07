import CryptoKit
import CoreModels
import Foundation

public struct M3UPlaylistImport: Codable, Sendable {
    public let channels: [M3UPlaylistChannel]
    public let entryCount: Int
    public let skippedEntryCount: Int
    public let declaredGuideURLs: [URL]
    public let permitsPersistence: Bool
    public let originURL: URL?

    public init(
        channels: [M3UPlaylistChannel],
        entryCount: Int,
        skippedEntryCount: Int,
        declaredGuideURLs: [URL] = [],
        permitsPersistence: Bool = true, originURL: URL? = nil
    ) {
        self.channels = channels
        self.entryCount = entryCount
        self.skippedEntryCount = skippedEntryCount
        self.declaredGuideURLs = declaredGuideURLs
        self.permitsPersistence = permitsPersistence
        self.originURL = originURL
    }
}

public enum LiveTVSourceImportError: Error, Equatable, Sendable {
    case cancelled
    case downloadFailed
    case invalidResponse
    case responseTooLarge
    case invalidPlaylist
    case emptyPlaylist
    case streamManifest
    case invalidGuide
    case guideTooLarge
    case guideSourceLimitReached
    case cacheFailed
    case unsafeGuideOrigin
    case guideWithoutPlaylist
    case authenticationRequired, temporarilyUnavailable, tooManyRequests, redirectBlocked

    public var userDescription: LocalizedStringResource {
        switch self {
        case .cancelled:
            "The Live TV import was cancelled."
        case .downloadFailed:
            "Plozz couldn't download the Live TV source."
        case .invalidResponse:
            "The Live TV source returned an invalid response."
        case .responseTooLarge:
            "The Live TV playlist is too large to import safely."
        case .invalidPlaylist:
            "This isn't a valid M3U playlist. Use a playlist file or a direct playlist download link, not a web page."
        case .emptyPlaylist:
            "This playlist contains no channels or videos. Ask your provider for an updated playlist."
        case .streamManifest:
            "This link is a video stream, not a channel playlist. Use your provider's M3U channel-list link."
        case .invalidGuide:
            "The Live TV guide isn't a supported XMLTV file."
        case .guideTooLarge:
            "The Live TV guide is too large to import safely."
        case .guideSourceLimitReached:
            "Some playlist-declared guides weren't added automatically. Use up to 32 preferred guide URLs for this source; its channels are still available."
        case .cacheFailed:
            "Your saved Live TV catalog couldn't be updated. The previous catalog has been kept."
        case .unsafeGuideOrigin:
            "This playlist declares a guide on another origin. Add that guide address explicitly in Sources to allow it."
        case .guideWithoutPlaylist:
            "This address contains a program guide, not playable channels. Add it to an existing playlist's guide sources."
        case .authenticationRequired:
            "This source rejected access. Check its address or credentials in Sources."
        case .temporarilyUnavailable:
            "This source is temporarily unavailable. Previously loaded channels and listings have been kept."
        case .tooManyRequests:
            "This source is limiting requests. Wait before refreshing again."
        case .redirectBlocked:
            "This source redirects outside its allowed origin. Add the destination address explicitly if you trust it."
        }
    }

    public var errorDescription: LocalizedStringResource {
        userDescription
    }
}

public struct M3UPlaylistParser: Sendable {
    public static let maximumBytes = 128 * 1_024 * 1_024
    public static let maximumEntries = 100_000
    public static let maximumLineBytes = 64 * 1_024
    // Contrast hints must not pull the regression channel catalog into shipping builds.
    private static let darkLogoURLs = Set(
        ["https://i.imgur.com/xP7Ehn8.png"].compactMap { URL(string: $0) }
    )

    private let baseURL: URL?
    private let permitsAuthenticationHeaders: Bool

    public init(baseURL: URL? = nil, permitsAuthenticationHeaders: Bool = false) {
        self.baseURL = baseURL
        self.permitsAuthenticationHeaders = permitsAuthenticationHeaders
    }

    public func parse(_ data: Data) throws -> M3UPlaylistImport {
        try Task.checkCancellation()
        guard data.count <= Self.maximumBytes else {
            throw limitExceeded(.inputBytes, observed: data.count, maximum: Self.maximumBytes)
        }
        var stream = makeStream()
        try stream.append(data)
        return try stream.finish()
    }

    public func parse(_ text: String) throws -> M3UPlaylistImport {
        guard text.utf8.count <= Self.maximumBytes else {
            throw limitExceeded(.decodedBytes, observed: text.utf8.count, maximum: Self.maximumBytes)
        }
        var stream = makeStream()
        for byte in text.utf8 { try stream.append(byte) }
        return try stream.finish()
    }

    public func makeStream() -> Stream { Stream(parser: self) }

    /// Consumers must drain entries after each bounded input chunk and persist
    /// them in an index. This mode never accumulates the complete catalogue.
    public func makeCatalogStream() -> Stream { Stream(parser: self, indexesCatalog: true) }

    public struct CatalogEntry: Sendable {
        public let channel: M3UPlaylistChannel
        public let attributes: [String: String]
        public let duration: TimeInterval?
        public let hasExplicitName: Bool
    }

    public struct Stream: Sendable {
        private let parser: M3UPlaylistParser
        private let indexesCatalog: Bool
        private var catalogEntries: [CatalogEntry] = []
        private var lineBuffer = Data()
        private var lineByteCount = 0
        private var previousByte: UInt8 = 0
        private var penultimateByte: UInt8 = 0
        private var hasPlaylistStart = false
        private var isHLS = false
        public private(set) var hasPlayableHLSTag = false
        public private(set) var byteCount = 0
        private var channels: [M3UPlaylistChannel] = []
        private var pending: PendingEntry?
        private var awaitingURL = false
        private var pendingHeaders: [String: String] = [:]
        private var defaultGroups: String?
        private var entryCount = 0
        private var skippedEntryCount = 0
        private var fallbackNumber = 0
        private var importedIDs = Set<String>()
        private var declaredGuideURLs: [URL] = []

        fileprivate init(parser: M3UPlaylistParser, indexesCatalog: Bool = false) {
            self.parser = parser
            self.indexesCatalog = indexesCatalog
        }

        public mutating func takeCatalogEntries() -> [CatalogEntry] {
            let result = catalogEntries
            catalogEntries.removeAll(keepingCapacity: true)
            return result
        }

        public var bufferedByteCount: Int { lineBuffer.count }

        public mutating func append(_ data: Data) throws {
            for byte in data { try append(byte) }
        }

        public mutating func append(_ byte: UInt8) throws {
            if byteCount.isMultiple(of: 16_384) { try Task.checkCancellation() }
            byteCount += 1
            guard indexesCatalog || byteCount <= M3UPlaylistParser.maximumBytes else {
                throw parser.limitExceeded(.inputBytes, observed: byteCount, maximum: M3UPlaylistParser.maximumBytes)
            }
            let separatorLength: Int
            if (10...13).contains(byte) {
                separatorLength = 1
            } else if byte == 0x85, previousByte == 0xC2 {
                separatorLength = 2
            } else if (byte == 0xA8 || byte == 0xA9), previousByte == 0x80, penultimateByte == 0xE2 {
                separatorLength = 3
            } else {
                separatorLength = 0
            }
            penultimateByte = previousByte
            previousByte = byte
            lineByteCount += 1
            if lineBuffer.count < M3UPlaylistParser.maximumLineBytes + 3 { lineBuffer.append(byte) }
            if separatorLength > 0 {
                if lineByteCount == lineBuffer.count { lineBuffer.removeLast(separatorLength) }
                lineByteCount -= separatorLength
                try consumeBufferedLine()
            }
        }

        public mutating func finish() throws -> M3UPlaylistImport {
            try Task.checkCancellation()
            if lineByteCount > 0 { try consumeBufferedLine() }
            if isHLS { throw LiveTVSourceImportError.streamManifest }
            if pending != nil { skippedEntryCount += 1; pending = nil }
            guard hasPlaylistStart else { throw LiveTVSourceImportError.emptyPlaylist }
            return M3UPlaylistImport(
                channels: channels, entryCount: entryCount, skippedEntryCount: skippedEntryCount,
                declaredGuideURLs: declaredGuideURLs, originURL: parser.baseURL
            )
        }

        private mutating func consumeBufferedLine() throws {
            defer {
                lineBuffer.removeAll(keepingCapacity: true)
                lineByteCount = 0
                previousByte = 0
                penultimateByte = 0
            }
            guard lineByteCount <= M3UPlaylistParser.maximumLineBytes else {
                if !hasPlaylistStart {
                    if indexesCatalog, lineBuffer.starts(with: Data("#EXTM3U ".utf8))
                        || lineBuffer.starts(with: Data("#EXTM3U\t".utf8)) {
                        // Optional guide declarations can exceed the line budget;
                        // they must not reject an otherwise valid channel list.
                        try consumeLine("#EXTM3U")
                        PlozzLog.networking.error("IPTV header metadata exceeded the line limit; add a guide URL explicitly")
                        return
                    }
                    throw parser.limitExceeded(.headerLineBytes, observed: lineByteCount,
                                               maximum: M3UPlaylistParser.maximumLineBytes)
                }
                if lineBuffer.starts(with: Data("#EXTINF:".utf8)) {
                    try countEntry()
                    skippedEntryCount += 1
                    awaitingURL = true
                } else {
                    awaitingURL = false
                }
                if pending != nil { skippedEntryCount += 1; pending = nil }
                pendingHeaders.removeAll()
                return
            }
            guard let rawLine = String(data: lineBuffer, encoding: .utf8)
                ?? String(data: lineBuffer, encoding: .isoLatin1) else {
                throw LiveTVSourceImportError.invalidPlaylist
            }
            for line in rawLine.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
                try consumeLine(String(line))
            }
        }

        private mutating func consumeLine(_ rawLine: String) throws {
            var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if !hasPlaylistStart, line.hasPrefix("\u{FEFF}") { line.removeFirst() }
            guard !line.isEmpty else { return }
            if !hasPlaylistStart, line == "#EXTM3U"
                || line.hasPrefix("#EXTM3U ") || line.hasPrefix("#EXTM3U\t") {
                hasPlaylistStart = true
                let attributes = parser.parseAttributes(String(line.dropFirst("#EXTM3U".count)))
                for key in ["url-tvg", "x-tvg-url"] {
                    for address in (attributes[key] ?? "").split(separator: ",") {
                        if let url = parser.supportedURL(
                            address.trimmingCharacters(in: .whitespacesAndNewlines), relativeTo: parser.baseURL
                        ), !declaredGuideURLs.contains(url) { declaredGuideURLs.append(url) }
                    }
                }
                return
            }
            if line.hasPrefix("#EXT-X-") {
                isHLS = true
                hasPlayableHLSTag = hasPlayableHLSTag || line.hasPrefix("#EXT-X-STREAM-INF:")
                    || line.hasPrefix("#EXT-X-TARGETDURATION:")
                channels.removeAll(keepingCapacity: false)
                catalogEntries.removeAll(keepingCapacity: false)
                importedIDs.removeAll(keepingCapacity: false)
                pending = nil
                pendingHeaders.removeAll()
                return
            }
            guard !isHLS else { return }
            if line.hasPrefix("#EXTINF:") {
                hasPlaylistStart = true
                if pending != nil { skippedEntryCount += 1 }
                try countEntry()
                pending = parser.parseEXTINF(line)
                awaitingURL = true
                if let entry = pending {
                    pending?.headers = pendingHeaders.merging(entry.headers) { _, entryValue in entryValue }
                }
                pendingHeaders.removeAll()
                if pending == nil { skippedEntryCount += 1 }
                return
            }
            if line.hasPrefix("#EXTGRP:") {
                defaultGroups = parser.clean(String(line.dropFirst("#EXTGRP:".count)))
                return
            }
            if line.hasPrefix("#EXTVLCOPT:") {
                guard let header = parser.parseVLCOption(line) else { return }
                if pending != nil {
                    pending?.headers[header.name] = header.value
                } else if !awaitingURL {
                    pendingHeaders[header.name] = header.value
                }
                return
            }
            guard !line.hasPrefix("#") else { return }
            if !awaitingURL {
                // Without EXTINF, only an absolute HTTP URL establishes a channel.
                // Arbitrary text must never become a relative URL from an error page.
                guard parser.isAbsoluteHTTPAddress(line) else {
                    if !hasPlaylistStart || entryCount == 0 { throw LiveTVSourceImportError.invalidPlaylist }
                    return
                }
                try countEntry()
                pending = PendingEntry(name: "", attributes: [:], duration: nil, headers: pendingHeaders)
                hasPlaylistStart = true
            }
            awaitingURL = false
            pendingHeaders.removeAll()
            guard var entry = pending else { return }
            pending = nil
            let pipe = line.firstIndex(of: "|")
            var address = pipe.map { String(line[..<$0]) } ?? line
            if parser.permitsAuthenticationHeaders,
               var parts = URLComponents(string: address), let user = parts.user {
                entry.headers["Authorization"] = "Basic " + Data((user + ":" + (parts.password ?? "")).utf8)
                    .base64EncodedString()
                parts.user = nil
                parts.password = nil
                address = parts.string ?? address
            }
            guard let streamURL = parser.supportedURL(address, relativeTo: parser.baseURL) else {
                skippedEntryCount += 1
                return
            }
            if let pipe {
                for header in parser.parsePipeHeaders(line[line.index(after: pipe)...]) {
                    entry.headers[header.name] = header.value
                }
            }
            fallbackNumber += 1
            let tvgID = parser.clean(entry.attributes["tvg-id"])
            let logoURL = parser.clean(entry.attributes["tvg-logo"])
                .flatMap { parser.supportedURL($0, relativeTo: parser.baseURL) }
            let groups = parser.categoryNames(from: entry.attributes["group-title"] ?? defaultGroups)
            let groupDescription = groups.isEmpty ? "Other" : groups.joined(separator: " • ")
            let digestInput = [tvgID ?? "", entry.name, streamURL.absoluteString].joined(separator: "\u{1F}")
            let digest = SHA256.hash(data: Data(digestInput.utf8)).map { String(format: "%02x", $0) }.joined()
            let channelID = "iptv-\(digest)"
            guard indexesCatalog || importedIDs.insert(channelID).inserted else { skippedEntryCount += 1; return }
            let channel = M3UPlaylistChannel(
                id: channelID, number: parser.validChannelNumber(entry.attributes["tvg-chno"]) ?? fallbackNumber,
                name: entry.name.isEmpty ? String(localized: "Channel \(fallbackNumber)") : entry.name, // l10n:content - fallback channel title stored in the imported catalogue.
                category: groups.first ?? "Other", symbol: parser.symbol(for: groupDescription),
                accent: parser.accent(for: digest), tagline: groupDescription,
                logoURL: logoURL, streamURL: streamURL,
                logoNeedsDarkBackground: logoURL.map(M3UPlaylistParser.darkLogoURLs.contains) ?? false,
                guideID: tvgID, guideName: parser.clean(entry.attributes["tvg-name"]), httpHeaders: entry.headers,
                language: parser.clean(entry.attributes["tvg-language"]),
                country: parser.clean(entry.attributes["tvg-country"]), groups: groups
            )
            if indexesCatalog {
                catalogEntries.append(CatalogEntry(
                    channel: channel, attributes: entry.attributes, duration: entry.duration,
                    hasExplicitName: !entry.name.isEmpty
                ))
            } else {
                channels.append(channel)
            }
        }

        private mutating func countEntry() throws {
            entryCount += 1
            guard indexesCatalog || entryCount <= M3UPlaylistParser.maximumEntries else {
                throw parser.limitExceeded(.entries, observed: entryCount, maximum: M3UPlaylistParser.maximumEntries)
            }
        }
    }

    private func limitExceeded(
        _ limit: LiveTVPlaylistLimitDiagnostic.Limit, observed: Int, maximum: Int
    ) -> LiveTVSourceImportError {
        LiveTVPlaylistLimitDiagnostic(limit: limit, observed: Int64(observed), maximum: Int64(maximum)).publish()
        return .responseTooLarge
    }

    private struct PendingEntry {
        let name: String
        let attributes: [String: String]
        let duration: TimeInterval?
        var headers: [String: String] = [:]
    }

    private func parseEXTINF(_ line: String) -> PendingEntry? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let payload = line[line.index(after: colon)...]
        guard let comma = firstUnquotedComma(in: payload) else { return nil }
        let metadata = payload[..<comma]
        let rawName = payload[payload.index(after: comma)...]
        let attributes = parseAttributes(String(metadata))
        let name = clean(String(rawName)) ?? clean(attributes["tvg-name"]) ?? ""
        guard name.count <= 1_024 else { return nil }
        var headers: [String: String] = [:]
        for (key, name) in [
            ("http-user-agent", "User-Agent"), ("user-agent", "User-Agent"),
            ("http-referrer", "Referer"), ("http-referer", "Referer"),
            ("referer", "Referer"), ("referrer", "Referer")
        ] {
            if let value = attributes[key], let header = header(named: name, value: value) {
                headers[header.name] = header.value
            }
        }
        return PendingEntry(
            name: name,
            attributes: attributes,
            duration: metadata.split(whereSeparator: \.isWhitespace).first
                .flatMap { Double($0) }.flatMap { $0.isFinite && $0 > 0 ? $0 : nil },
            headers: headers
        )
    }

    private func firstUnquotedComma(in text: Substring) -> String.Index? {
        var quote: Character?
        var escaped = false
        for index in text.indices {
            let character = text[index]
            if (character == "\"" || character == "'") && !escaped {
                if quote == character { quote = nil }
                else if quote == nil { quote = character }
            }
            if character == "," && quote == nil {
                return index
            }
            escaped = character == "\\" && !escaped
            if character != "\\" { escaped = false }
        }
        return nil
    }

    private func parseAttributes(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        var index = text.startIndex
        while index < text.endIndex {
            while index < text.endIndex, text[index].isWhitespace {
                index = text.index(after: index)
            }
            let keyStart = index
            while index < text.endIndex,
                  text[index] != "=",
                  !text[index].isWhitespace {
                index = text.index(after: index)
            }
            guard keyStart < index else { break }
            let key = text[keyStart..<index].lowercased()
            let keyEnd = index
            while index < text.endIndex, text[index].isWhitespace {
                index = text.index(after: index)
            }
            guard index < text.endIndex, text[index] == "=" else {
                // A bare duration/token must not consume the attribute after it.
                index = keyEnd
                continue
            }
            index = text.index(after: index)
            while index < text.endIndex, text[index].isWhitespace {
                index = text.index(after: index)
            }
            guard index < text.endIndex else { break }

            var value = ""
            if text[index] == "\"" || text[index] == "'" {
                let quote = text[index]
                index = text.index(after: index)
                while index < text.endIndex, text[index] != quote {
                    if text[index] == "\\" {
                        let next = text.index(after: index)
                        if next < text.endIndex, text[next] == quote || text[next] == "\\" {
                            index = next
                        }
                    }
                    value.append(text[index])
                    index = text.index(after: index)
                }
                if index < text.endIndex {
                    index = text.index(after: index)
                }
            } else {
                while index < text.endIndex, !text[index].isWhitespace {
                    value.append(text[index])
                    index = text.index(after: index)
                }
            }
            if value.count <= 8_192 {
                result[key] = value
            }
        }
        return result
    }

    private func parseVLCOption(_ line: String) -> (name: String, value: String)? {
        let prefix = "#EXTVLCOPT:"
        guard let separator = line.firstIndex(of: "=") else { return nil }
        let keyStart = line.index(line.startIndex, offsetBy: prefix.count)
        let key = line[keyStart..<separator].lowercased()
        let value = line[line.index(after: separator)...]
        switch key {
        case "http-referrer", "http-referer":
            return header(named: "Referer", value: String(value))
        case "http-user-agent":
            return header(named: "User-Agent", value: String(value))
        case "http-cookie" where permitsAuthenticationHeaders:
            return header(named: "Cookie", value: String(value))
        case "http-authorization" where permitsAuthenticationHeaders:
            return header(named: "Authorization", value: String(value))
        default:
            return nil
        }
    }

    private func parsePipeHeaders(_ suffix: Substring) -> [(name: String, value: String)] {
        suffix.split(separator: "&").compactMap { pair in
            guard let separator = pair.firstIndex(of: "=") else { return nil }
            let key = pair[..<separator]
                .trimmingCharacters(in: .whitespaces).lowercased()
            let rawValue = String(pair[pair.index(after: separator)...])
            let value = rawValue.removingPercentEncoding ?? rawValue
            switch key {
            case "user-agent":
                return header(named: "User-Agent", value: value)
            case "referer", "referrer":
                return header(named: "Referer", value: value)
            default:
                return permitsAuthenticationHeaders ? header(named: String(pair[..<separator]), value: value) : nil
            }
        }
    }

    private func header(named name: String, value: String) -> (name: String, value: String)? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        // Scalars, not Characters: "\r\n" is one grapheme and would slip past `contains("\r")`.
        guard !value.isEmpty, value.count <= 4_096,
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { return nil }
        switch name {
        case "Referer":
            guard let url = URL(string: value),
                  ["http", "https"].contains(url.scheme?.lowercased()),
                  url.host != nil,
                  url.user == nil,
                  url.password == nil
            else { return nil }
            return ("Referer", value)
        case "User-Agent":
            return ("User-Agent", value)
        default:
            guard permitsAuthenticationHeaders else { return nil }
            do { try IPTVCredential.validate(headers: [name: value]); return (name, value) }
            catch { return nil }
        }
    }

    private func isAbsoluteHTTPAddress(_ line: String) -> Bool {
        let address = line.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)[0]
        guard let parts = URLComponents(string: String(address)),
              let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = parts.host, !host.isEmpty else { return false }
        return true
    }

    private func supportedURL(_ text: String, relativeTo baseURL: URL?) -> URL? {
        // Availability notices are not relative paths, even when Foundation can encode them as one.
        guard text.count <= 16_384,
              !(text.hasPrefix("[") && text.hasSuffix("]")),
              let url = URL(string: text, relativeTo: baseURL)?.absoluteURL,
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host != nil,
              url.user == nil,
              url.password == nil
        else { return nil }
        return url
    }

    private func validChannelNumber(_ text: String?) -> Int? {
        guard let text, let number = Int(text), number > 0 else { return nil }
        return number
    }

    private func categoryNames(from value: String?) -> [String] {
        guard let value else { return [] }
        var seen = Set<String>()
        return value.split(separator: ";").compactMap { component in
            let category = component.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !category.isEmpty,
                  category.count <= 256,
                  seen.insert(category.lowercased()).inserted
            else { return nil }
            return category
        }
    }

    private func clean(_ value: String?) -> String? {
        guard let cleaned = value?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !cleaned.isEmpty
        else { return nil }
        return cleaned
    }

    private func accent(for digest: String) -> Int {
        Int(digest.prefix(2), radix: 16).map { $0 % 6 } ?? 0
    }

    private func symbol(for group: String) -> String {
        let lower = group.lowercased()
        if lower.contains("news") { return "newspaper.fill" }
        if lower.contains("sport") { return "sportscourt.fill" }
        if lower.contains("music") { return "music.note" }
        if lower.contains("kids") || lower.contains("animation") {
            return "sparkles.tv.fill"
        }
        if lower.contains("relig") { return "building.columns.fill" }
        return "tv.fill"
    }
}
