import Foundation

/// Display-only names from provider labels, file paths, or streaming locators.
/// Never use the result to construct a playback URL or provider identity.
public enum MediaSourceDisplayName {
    private static let fileNameQueryKeys: Set<String> = ["filename", "file_name"]

    public static func name(from rawValue: String?) -> String? {
        guard let value = nonempty(rawValue) else { return nil }
        let lines = value.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: .newlines)
        if lines.count > 1,
           let releaseIndex = lines.lastIndex(where: {
               let line = $0.trimmingCharacters(in: .whitespaces)
               return line.unicodeScalars.first.map { ["🗂", "📁", "📂"].contains(String($0)) } ?? false
           }) {
            let release = String(lines[releaseIndex].trimmingCharacters(in: .whitespaces).dropFirst())
                .trimmingCharacters(in: .whitespaces)
            var wrapped = release
            for line in lines.dropFirst(releaseIndex + 1) {
                if hasMediaExtension(wrapped) { break }
                let continuation = line.trimmingCharacters(in: .whitespaces)
                guard let first = continuation.unicodeScalars.first,
                      !first.properties.isEmojiPresentation else { break }
                wrapped += continuation
            }
            // Only join continuation text when it completes a file, not another description field.
            return name(from: hasMediaExtension(wrapped) ? wrapped : release)
        }
        if lines.count > 1, !value.contains("://"), !value.contains("?") {
            let trimmed = lines.map { $0.trimmingCharacters(in: .whitespaces) }
            let files = Set(trimmed.filter(hasMediaExtension))
            if files.count == 1, let file = files.first {
                return name(from: file)
            }
            if let fieldsStart = trimmed.firstIndex(where: isDescriptionField) {
                // Structured descriptions can have a decorated title but no filename.
                // Keep that title, not repeated language, quality or source-status rows.
                return trimmed[..<fieldsStart].lazy
                    .filter { !$0.isEmpty && !isResolutionHeader($0) }
                    .compactMap { name(from: undecoratedTitle($0)) }
                    .first
            }
        }
        // A bare key/value query is not a display label, even without a URL prefix.
        let isQueryOnly = value.range(
            of: #"^[^/?&#\\:\s=]+\s*="#, options: .regularExpression
        ) != nil
        guard isQueryOnly || value.contains("?") || value.contains("://")
                || value.hasPrefix("//") || value.hasPrefix("file:") else {
            guard let component = basename(value), !isOpaqueComponent(component) else { return nil }
            return value
        }
        // Raw line breaks make Foundation re-escape existing percent sequences.
        // Remove display wrapping before decoding, never decode the result twice.
        let locator = value.components(separatedBy: .newlines).joined()
        guard let components = URLComponents(string: isQueryOnly ? "?" + locator : locator) else {
            return nil
        }
        if !components.path.hasSuffix("/"),
           let fileName = basename(components.path),
           hasMediaExtension(fileName) {
            return fileName
        }
        return queryFileName(from: components)
    }

    private static func isDescriptionField(_ line: String) -> Bool {
        line.range(
            of: #"^(?:Audio(?: languages?)?|Languages?|Langues?|Subtitles?|Sous[ -]?titres?)\s*[:•|]\s*"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    private static func isResolutionHeader(_ line: String) -> Bool {
        // Ratings use partial circles, emoji variation selectors and fractions,
        // not just full circles. Require the entire suffix to be decoration.
        line.range(
            of: #"^(?:[248]K|[0-9]{3,4}[pi]|UHD|FHD|HD|SD)[\s\p{S}\p{P}\p{M}\p{No}]*$"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    private static func undecoratedTitle(_ line: String) -> String {
        func isDecoration(_ character: Character) -> Bool {
            character.isWhitespace || "•·|".contains(character)
                || character.unicodeScalars.first?.properties.isEmojiPresentation == true
        }
        var title = line[...]
        if title.first == "[", let end = title.firstIndex(of: "]") {
            let remainder = title[title.index(after: end)...].drop(while: \.isWhitespace)
            if remainder.first?.unicodeScalars.first?.properties.isEmojiPresentation == true {
                title = remainder
            }
        }
        return String(title.drop(while: isDecoration))
    }

    private static func queryFileName(from components: URLComponents) -> String? {
        var candidates = Set<String>()
        for item in components.queryItems ?? [] {
            let key = item.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard fileNameQueryKeys.contains(key) else { continue }
            // Decode once through URLComponents. Never guess a filename from
            // unrelated values or display a nested locator as a filename.
            guard let value = nonempty(item.value),
                  !value.hasPrefix("//"), !value.contains("?"),
                  value.rangeOfCharacter(from: .controlCharacters) == nil,
                  let fileName = basename(value), !isOpaqueComponent(fileName) else { return nil }
            let windowsPath = value.range(of: #"^[A-Za-z]:[\\/]"#, options: .regularExpression) != nil
            guard URLComponents(string: value)?.scheme == nil || windowsPath else { return nil }
            candidates.insert(fileName)
        }
        return candidates.count == 1 ? candidates.first : nil
    }

    public static func fileName(from path: String?) -> String? {
        name(from: path).flatMap(basename)
    }

    /// Invisible break opportunities for long dot/underscore-separated filenames; never a stored filename.
    public static func wrappingFileName(_ value: String) -> String {
        value.replacingOccurrences(of: ".", with: ".\u{200B}")
            .replacingOccurrences(of: "_", with: "_\u{200B}")
    }

    /// Compact presentation only. The sanitized original remains available as file details.
    public static func releaseTitle(from fileName: String) -> String {
        guard hasMediaExtension(fileName), !fileName.contains("\n"),
              !fileName.contains("/"), !fileName.contains("\\") else { return fileName }
        let stem = (fileName as NSString).deletingPathExtension
        guard let resolution = stem.range(
            of: #"(?<![\p{L}\p{N}])(?:[248]K|(?:480|576|720|1080|1440|2160|4320)[pi])(?![\p{L}\p{N}])"#,
            options: [.regularExpression, .caseInsensitive]
        ) else { return fileName }

        var prefix = String(stem[..<resolution.lowerBound])
            .trimmingCharacters(in: releaseSeparators)
        var removedTags = ""
        // Only trim release tags next to the technical suffix, never words inside a title.
        let trailingTag = #"(?i)[ ._]+(?:MULTI|DUAL|WEB[ ._-]?DL|WEBRIP|BLU[ ._-]?RAY|REMUX|HDTV|NF|AMZN|ATV|ATVP|DSNP|HMAX|REPACK|PROPER|RERIP)$"#
        while let tag = prefix.range(of: trailingTag, options: .regularExpression) {
            removedTags += " " + prefix[tag]
            prefix = String(prefix[..<tag.lowerBound]).trimmingCharacters(in: releaseSeparators)
        }
        guard !prefix.isEmpty else { return fileName }

        var parts: [String]
        if let episode = prefix.range(
            of: #"(?<![\p{L}\p{N}])S[0-9]{1,2}E[0-9]{1,3}(?:(?:E|-E?)[0-9]{1,3})*(?![\p{L}\p{N}])"#,
            options: [.regularExpression, .caseInsensitive]
        ) {
            let title = releaseWords(String(prefix[..<episode.lowerBound]))
            guard !title.isEmpty else { return fileName }
            parts = [title, prefix[episode].uppercased()]
            let episodeTitle = releaseWords(String(prefix[episode.upperBound...]))
            if !episodeTitle.isEmpty { parts.append(episodeTitle) }
        } else {
            parts = [releaseWords(prefix)]
        }

        var suffix = String(stem[resolution.upperBound...])
        var group: String?
        if let groupRange = suffix.range(of: #"-[\p{L}\p{N}_]+$"#, options: .regularExpression) {
            let candidate = String(suffix[groupRange].dropFirst())
            // These are compound technical tokens, not release groups (WEB-DL, DTS-HD).
            if !["DL", "HD", "MA", "REPACK", "PROPER", "RERIP"].contains(candidate.uppercased()) {
                group = candidate
                suffix = String(suffix[..<groupRange.lowerBound])
            }
        }
        let tokens = suffix.uppercased().components(separatedBy: releaseSeparators).filter { !$0.isEmpty }
        // Unknown suffixes may be edition or episode text. Keep the original rather
        // than silently collapse two different releases into the same short title.
        guard tokens.allSatisfy({ releaseTechnicalTokens.contains($0) }) else { return fileName }
        let qualifiers = removedTags + " " + suffix
        for qualifier in ["REPACK", "PROPER", "RERIP"] {
            if qualifiers.range(
                of: #"(?<![\p{L}\p{N}])"# + qualifier + #"(?![\p{L}\p{N}])"#,
                options: [.regularExpression, .caseInsensitive]
            ) != nil {
                parts.append(qualifier)
            }
        }
        if let group { parts.append(group) }
        return parts.joined(separator: " · ")
    }

    private static let releaseTechnicalTokens: Set<String> = [
        "ATV", "ATVP", "AMZN", "NF", "DSNP", "HMAX", "WEB", "WEB-DL", "WEBDL", "WEBRIP",
        "BLURAY", "BLU-RAY", "REMUX", "HDTV", "HDR", "HDR10", "HDR10+", "DV", "DOVI", "SDR",
        "HEVC", "AVC", "H264", "H265", "X264", "X265", "H", "264", "265", "AV1", "VP9",
        "DD", "DDP", "DDP2", "DDP5", "DDP7", "DD2", "DD5", "DD7", "AAC", "AAC2", "AAC5", "AAC7",
        "AC3", "EAC3", "E-AC3", "DTS", "DTS-HD", "MA", "TRUEHD", "FLAC", "ATMOS",
        "0", "1", "2", "5", "6", "7", "8", "10BIT", "8BIT", "MULTI", "DUAL",
        "REPACK", "PROPER", "RERIP"
    ]

    private static let releaseSeparators = CharacterSet.whitespacesAndNewlines
        .union(CharacterSet(charactersIn: "._"))

    private static func releaseWords(_ value: String) -> String {
        value.replacingOccurrences(of: ".", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Named languages in an explicit source-description field, not inferred tracks or filename hints.
    public static func declaredAudioLanguages(from rawValue: String?) -> [String] {
        guard let description = nonempty(rawValue) else { return [] }
        var languages: [String] = []
        for rawLine in description.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let first = line.first else { continue }
            if ["🗂", "🗂️", "📁", "📂"].contains(String(first)) { break }
            if let declared = compactSourceAudioLanguages(from: line) {
                for code in declared where !languages.contains(code) { languages.append(code) }
                continue
            }
            let field: String
            if ["🌍", "🌎", "🌏", "🌐"].contains(String(first)) {
                field = String(line.dropFirst())
            } else if let prefix = line.range(
                of: #"^(?:Audio(?: languages?)?|Languages?)\s*[:•|]\s*"#,
                options: [.regularExpression, .caseInsensitive]
            ) {
                field = String(line[prefix.upperBound...])
            } else {
                continue
            }
            let tokens = field.components(separatedBy: CharacterSet(charactersIn: "|•,"))
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                .filter { !$0.isEmpty && $0 != "multi" && $0 != "multilingual" }
            let codes = tokens.compactMap { declaredLanguageCodes[$0] }
            // A globe alone also labels regions, subtitles, and mixed technical rows.
            guard codes.count == tokens.count else { continue }
            for code in codes where !languages.contains(code) { languages.append(code) }
        }
        return languages
    }

    private static func compactSourceAudioLanguages(from line: String) -> [String]? {
        let fields = line.components(separatedBy: "•")
        guard fields.count > 1,
              fields[1].trimmingCharacters(in: .whitespaces).hasPrefix("💾"),
              declaredFileSizeBytes(from: fields[1]) != nil else { return nil }
        let header = fields[0].filter { !$0.isWhitespace }
        let markers: Set<Character> = ["🌍", "🌎", "🌏", "🌐", "✓", "✅", "💬"]
        guard !header.isEmpty, header.allSatisfy({ character in
            markers.contains(character) || (
                character.unicodeScalars.count == 2
                    && character.unicodeScalars.allSatisfy { (0x1F1E6...0x1F1FF).contains($0.value) }
            )
        }) else { return nil }
        return header.compactMap { compactAudioFlagLanguages[$0] }
    }

    // Language flags in the bridge's explicit "<flags> • 💾 <size>" header, not country inference.
    // Ambiguous regional variants such as Canada do not add a distinct language.
    private static let compactAudioFlagLanguages: [Character: String] = [
        "🇫🇷": "fr", "🇬🇧": "en", "🇺🇸": "en", "🇪🇸": "es", "🇩🇪": "de",
        "🇮🇹": "it", "🇵🇹": "pt", "🇧🇷": "pt", "🇳🇱": "nl", "🇸🇪": "sv",
        "🇳🇴": "no", "🇩🇰": "da", "🇫🇮": "fi", "🇵🇱": "pl", "🇷🇺": "ru",
        "🇯🇵": "ja", "🇰🇷": "ko", "🇨🇳": "zh", "🇹🇼": "zh", "🇸🇦": "ar",
        "🇹🇷": "tr", "🇨🇿": "cs", "🇬🇷": "el", "🇮🇱": "he", "🇹🇭": "th",
        "🇺🇦": "uk", "🇭🇺": "hu", "🇷🇴": "ro", "🇮🇩": "id", "🇻🇳": "vi"
    ]

    private static let declaredLanguageCodes: [String: String] = {
        let locale = Locale(identifier: "en_US_POSIX")
        var result: [String: String] = [:]
        for language in Locale.LanguageCode.isoLanguageCodes {
            let code = LanguageMatch.normalized(language.identifier(.alpha2) ?? language.identifier)
                ?? language.identifier
            guard !["und", "mul", "zxx"].contains(code) else { continue }
            result[language.identifier.lowercased()] = code
            if let alpha3 = language.identifier(.alpha3) { result[alpha3.lowercased()] = code }
            result[code] = code
            if let name = locale.localizedString(forLanguageCode: code) {
                result[name.lowercased()] = code
            }
        }
        return result
    }()

    /// An explicitly byte-unit size in a source description, never a bitrate or filename token.
    public static func declaredFileSizeBytes(from rawValue: String?) -> Int64? {
        guard var description = nonempty(rawValue) else { return nil }
        for marker in ["🗂", "📁", "📂"] {
            if let range = description.range(of: marker) {
                description = String(description[..<range.lowerBound])
            }
        }
        let pattern = #"(?<![\p{L}\p{N}_.,+\-])([0-9]+(?:[.,][0-9]+)?)[\p{Zs}\t]+(?:TiB|TB|To|GiB|GB|Go|MiB|MB|Mo|KiB|KB|Ko)(?![\p{L}\p{N}_./]|\s*/)"#
        var sizes = Set<Int64>()
        for line in description.components(separatedBy: .newlines) {
            guard !line.contains("://"), !line.contains("?"), !line.contains("="),
                  !hasMediaExtension(line) else { continue }
            var remaining = line.startIndex..<line.endIndex
            while let range = line.range(of: pattern, options: .regularExpression, range: remaining) {
                let parts = line[range].split(whereSeparator: \.isWhitespace)
                guard parts.count == 2,
                      let amount = Double(parts[0].replacingOccurrences(of: ",", with: ".")) else { return nil }
                let multiplier: Double
                switch parts[1] {
                case "TB", "To": multiplier = 1_000_000_000_000
                case "TiB": multiplier = 1_099_511_627_776
                case "GB", "Go": multiplier = 1_000_000_000
                case "GiB": multiplier = 1_073_741_824
                case "MB", "Mo": multiplier = 1_000_000
                case "MiB": multiplier = 1_048_576
                case "KB", "Ko": multiplier = 1_000
                case "KiB": multiplier = 1_024
                default: return nil
                }
                let bytes = amount * multiplier
                guard bytes.isFinite, bytes >= 1, bytes < Double(Int64.max) else { return nil }
                sizes.insert(Int64(bytes.rounded()))
                remaining = range.upperBound..<line.endIndex
            }
        }
        return sizes.count == 1 ? sizes.first : nil
    }

    private static func basename(_ value: String) -> String? {
        let path = value.replacingOccurrences(of: "\\", with: "/")
        guard let result = nonempty((path as NSString).lastPathComponent),
              result != "/", result != ".", result != ".." else { return nil }
        return result
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func isOpaqueComponent(_ value: String) -> Bool {
        // Preserve real filenames, Unicode and prose. Only long, unbroken
        // identifier-shaped components are excluded from display.
        guard !hasMediaExtension(value) else { return false }
        let unwrapped = value.components(separatedBy: .newlines).joined()
        guard unwrapped.utf8.count >= 64,
              unwrapped.range(of: #"^[A-Za-z0-9_.=\-]+$"#, options: .regularExpression) != nil else {
            return false
        }
        return unwrapped.split(separator: ".").contains { segment in
            guard segment.utf8.count >= 64 else { return false }
            return segment.allSatisfy(\.isHexDigit)
                || (segment.contains(where: \.isUppercase)
                    && segment.contains(where: \.isLowercase)
                    && segment.contains(where: \.isNumber))
        }
    }

    private static func hasMediaExtension(_ value: String) -> Bool {
        ["mkv", "mp4", "m4v", "avi", "mov", "wmv", "ts", "m2ts", "mts",
         "webm", "mpg", "mpeg", "vob", "iso", "strm", "flv", "m2t", "3gp", "3g2",
         "ogv", "asf", "rm", "rmvb", "mp3", "m4a", "m4b", "aac", "flac", "wav",
         "aif", "aiff", "ogg", "oga", "opus", "wma", "mka", "m3u", "m3u8", "mpd"]
            .contains((value as NSString).pathExtension.lowercased())
    }
}
