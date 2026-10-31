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
        // A bare key/value query is not a display label, even without a URL prefix.
        let isQueryOnly = value.range(
            of: #"^[^/?&#\\:\s=]+\s*="#, options: .regularExpression
        ) != nil
        guard isQueryOnly || value.contains("?") || value.contains("://")
                || value.hasPrefix("//") || value.hasPrefix("file:") else { return value }
        // Raw line breaks make Foundation re-escape existing percent sequences.
        // Remove display wrapping before decoding, never decode the result twice.
        let locator = value.components(separatedBy: .newlines).joined()
        guard let components = URLComponents(string: isQueryOnly ? "?" + locator : locator) else {
            return nil
        }
        if !components.path.hasSuffix("/"),
           let fileName = basename(components.path),
           !(fileName as NSString).pathExtension.isEmpty {
            return fileName
        }
        return queryFileName(from: components)
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
                  let fileName = basename(value) else { return nil }
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

    private static func hasMediaExtension(_ value: String) -> Bool {
        ["mkv", "mp4", "m4v", "avi", "mov", "wmv", "ts", "m2ts", "mts",
         "webm", "mpg", "mpeg", "vob", "iso", "strm", "flv"]
            .contains((value as NSString).pathExtension.lowercased())
    }
}
