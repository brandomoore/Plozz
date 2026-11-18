import CoreModels
import CryptoKit
import Foundation

public enum DownloadSubtitleStatus: String, Codable, Sendable {
    case saved
    case unavailable
}

public struct OfflineSubtitleAsset: Sendable {
    public let track: MediaTrack
    public let data: Data
    public let format: String

    public init(track: MediaTrack, data: Data, format: String) {
        self.track = track
        self.data = data
        self.format = format
    }
}

/// Sidecars share the video's version/profile folder and replacement/deletion lifecycle.
public enum OfflineSubtitleStore {
    public static let maximumFileBytes = 16 * 1_024 * 1_024
    public static let maximumTotalBytes = 64 * 1_024 * 1_024
    public static let maximumTracks = 64

    public static func supportedFormat(_ format: String?) -> String? {
        switch format?.lowercased() {
        case "srt", "subrip": "srt"
        case "vtt", "webvtt": "vtt"
        case "ass": "ass"
        case "ssa": "ssa"
        default: nil
        }
    }

    public static func save(
        _ assets: [OfflineSubtitleAsset], beside mediaURL: URL, preservingExisting: Bool = false
    ) throws {
        guard assets.count <= maximumTracks else { throw CocoaError(.fileReadTooLarge) }
        let folder = mediaURL.deletingLastPathComponent()
        let indexURL = mediaURL.appendingPathExtension("subtitles.json")
        let previous: [OfflineSubtitleFile]
        do {
            previous = try files(beside: mediaURL)
        } catch is DecodingError {
            NSLog("Replacing an unreadable offline subtitle index")
            previous = []
        }
        var files: [OfflineSubtitleFile] = []
        var written: [URL] = []
        var total = 0
        do {
            for asset in assets {
                try Task.checkCancellation()
                total += asset.data.count
                guard asset.data.count <= maximumFileBytes, total <= maximumTotalBytes,
                      let format = supportedFormat(asset.format),
                      let text = SubtitleCueParser.decodeText(asset.data),
                      !SubtitleCueParser.parseCues(text).isEmpty else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                let digest = SHA256.hash(data: asset.data).map { String(format: "%02x", $0) }.joined()
                let name = "offline-subtitle-\(digest).\(format)"
                let url = folder.appendingPathComponent(name)
                let existed = FileManager.default.fileExists(atPath: url.path)
                if existed {
                    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                    guard values.isRegularFile == true, values.isSymbolicLink != true else {
                        throw CocoaError(.fileWriteInvalidFileName)
                    }
                }
                try asset.data.write(to: url, options: .atomic)
                if !existed { written.append(url) }
                files.append(OfflineSubtitleFile(
                    fileName: name, language: asset.track.language, codec: format,
                    forced: asset.track.isForced, hearingImpaired: asset.track.isHearingImpaired,
                    displayTitle: asset.track.displayTitle
                ))
            }
            if preservingExisting {
                let names = Set(files.map(\.fileName))
                for file in previous where !names.contains(file.fileName) {
                    guard let url = localURL(for: file, beside: mediaURL) else { continue }
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    total += size
                    guard size > 0, size <= maximumFileBytes, total <= maximumTotalBytes,
                          files.count < maximumTracks else { throw CocoaError(.fileReadTooLarge) }
                    files.append(file)
                }
            }
            try Task.checkCancellation()
            let index = try JSONEncoder().encode(files)
            guard index.count <= 1_048_576 else { throw CocoaError(.fileWriteOutOfSpace) }
            try index.write(to: indexURL, options: .atomic)
        } catch {
            for url in written {
                do { try FileManager.default.removeItem(at: url) }
                catch { NSLog("Offline subtitle staging cleanup failed") }
            }
            throw error
        }
        let retained = Set(files.map(\.fileName))
        for old in previous where !retained.contains(old.fileName) {
            guard old.fileName.hasPrefix("offline-subtitle-"),
                  let url = localURL(for: old, beside: mediaURL) else { continue }
            do { try FileManager.default.removeItem(at: url) }
            catch { NSLog("Offline subtitle replacement cleanup failed") }
        }
    }

    public static func files(beside mediaURL: URL) throws -> [OfflineSubtitleFile] {
        let url = mediaURL.appendingPathExtension("subtitles.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size <= 1_048_576 else { throw CocoaError(.fileReadTooLarge) }
        return try JSONDecoder().decode([OfflineSubtitleFile].self, from: Data(contentsOf: url))
            .filter { localURL(for: $0, beside: mediaURL) != nil }
    }

    public static func localURL(for file: OfflineSubtitleFile, beside mediaURL: URL) -> URL? {
        guard !file.fileName.isEmpty, !file.fileName.contains("/"), !file.fileName.contains("\\"),
              file.fileName != ".", file.fileName != ".." else { return nil }
        let url = mediaURL.deletingLastPathComponent().appendingPathComponent(file.fileName)
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
        return url
    }
}
