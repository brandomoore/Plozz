import Foundation
import CoreModels
import CoreNetworking

public struct SiloDownloadReference: Codable, Hashable, Sendable {
    public let id: String
    public let revision: Int
    public init(id: String, revision: Int) { self.id = id; self.revision = revision }
}

public struct SiloDownloadResolution: Sendable {
    public let reference: SiloDownloadReference
    public let url: URL
    public let headers: [String: String]
    public let expectedBytes: Int64
    public let duration: Double
    public let manifest: Data
    public let metadata: MediaSourceMetadata
}

public struct SiloOfflineAsset: Sendable {
    public let file: OfflineSubtitleFile
    public let bytes: Data
}

public struct SiloDownloadCapability: Decodable, Sendable {
    public let allowed: Bool
    public let state: String
    public let quality_presets: [String]
    public let file_delivery: Bool
    public let bounded_creation: Bool
    public let bounded_manifests: Bool
    public let ordered_status: Bool
    public let proxy_delivery: Bool?
}

struct SiloDownloadEntry: Decodable, Sendable {
    let id: String
    let content_id: String
    let episode_id: String?
    let media_file_id: String
    let file_size: Int64
    let status: String
    let quality: String
    let delivery_format: String
    let revision: Int
}

struct SiloDownloadManifest: Decodable, Sendable {
    struct Integrity: Decodable, Sendable { let expected_bytes: Int64; let metadata_etag: String }
    let download_id: String
    let media_file_id: String
    let revision: Int
    let file_size: Int64
    let duration_seconds: Double
    let container: String
    let codec_video: String?
    let codec_audio: String?
    let hdr: Bool?
    let integrity: Integrity?
}

extension SiloProvider {
    public func downloadSubtitleAssets(manifest data: Data, reference: SiloDownloadReference) async throws -> [SiloOfflineAsset] {
        struct Subtitle: Decodable {
            let language: String?
            let format: String
            let forced: Bool
            let hearing_impaired: Bool
            let fetch_url: String
        }
        struct Manifest: Decodable { let subtitles: [Subtitle] }
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        var result: [SiloOfflineAsset] = []
        for (index, subtitle) in manifest.subtitles.enumerated() {
            guard ["srt", "vtt", "ass", "ssa", "subrip", "webvtt"].contains(subtitle.format.lowercased()) else { continue }
            guard let url = resourceURL(subtitle.fetch_url),
                  let path = MediaProviderURLIdentity.relativeResourcePath(of: url, under: session.server.baseURL),
                  path.hasPrefix("/api/v2/downloads/\(try SiloAPI.pathComponent(reference.id))/subtitles/"),
                  url.query == nil, url.fragment == nil else { throw AppError.invalidResponse }
            let (bytes, _) = try await client.send(String(path.dropFirst("/api/v2".count)), deviceID: session.deviceID)
            guard bytes.count <= 16 * 1_048_576 else { throw AppError.invalidResponse }
            let file = OfflineSubtitleFile(fileName: "silo-subtitle-\(index).\(subtitle.format.lowercased())",
                                           language: subtitle.language, codec: subtitle.format,
                                           forced: subtitle.forced, hearingImpaired: subtitle.hearing_impaired)
            result.append(SiloOfflineAsset(file: file, bytes: bytes))
        }
        return result
    }

    public func downloadCapability() async throws -> SiloDownloadCapability {
        let result: SiloDownloadCapability = try await client.request("/capabilities/downloads")
        guard result.allowed, result.state == "available", result.file_delivery,
              result.bounded_creation, result.bounded_manifests, result.ordered_status else {
            throw AppError.unauthorized
        }
        return result
    }

    public func prepareDownload(
        itemID: String, fileID: String, quality: String, maximumHeight: Int?,
        reference: SiloDownloadReference?,
        requiresAllAudioTracks: Bool = false,
        persistReference: @escaping @Sendable (SiloDownloadReference) async throws -> Void
    ) async throws -> SiloDownloadResolution {
        let capability = try await downloadCapability()
        guard capability.quality_presets.contains(quality) else { throw AppError.invalidResponse }
        let deviceID = session.deviceID
        var entries = try await downloadEntries()
        var selected: SiloDownloadEntry?
        if let reference {
            selected = entries.first { $0.id == reference.id }
            guard let selected, selected.revision == reference.revision,
                  selected.media_file_id == fileID,
                  (selected.episode_id ?? selected.content_id) == itemID,
                  selected.quality == quality else { throw AppError.conflict }
        } else {
            selected = entries.first {
                $0.media_file_id == fileID && ($0.episode_id ?? $0.content_id) == itemID && $0.quality == quality
            }
        }
        if selected == nil || ["failed", "revoked"].contains(selected?.status ?? "") {
                let previous = selected ?? entries.first {
                    $0.media_file_id == fileID && ($0.episode_id ?? $0.content_id) == itemID
                }
                let item = try await item(id: itemID)
                struct Caps: Encodable {
                    let codecs_video: [String]
                    let codecs_audio: [String]
                    let containers = ["mp4", "mkv", "mov", "m4v", "ts", "mpegts"]
                    let max_resolution: String
                    let hdr: Bool
                }
                struct Body: Encodable {
                    let content_id: String
                    let episode_id: String?
                    let media_file_id: String
                    let quality: String
                    let expected_revision: Int
                    let expected_download_id: String?
                    let caps: Caps
                }
                struct Created: Decodable, Sendable { let items: [SiloDownloadEntry] }
                let body = Body(
                    content_id: item.kind == .episode ? (item.seriesID ?? itemID) : itemID,
                    episode_id: item.kind == .episode ? itemID : nil,
                    media_file_id: fileID, quality: quality,
                    expected_revision: previous?.revision ?? 0, expected_download_id: previous?.id,
                    caps: .init(codecs_video: capabilitiesSnapshot.allowedDirectPlayVideoCodecs.map(\.rawValue),
                                codecs_audio: ["aac", "ac3", "eac3", "alac", "flac", "mp3", "opus", "dts", "truehd"],
                                max_resolution: "\(maximumHeight ?? 2160)p",
                                hdr: capabilitiesSnapshot.supportsHDR10 || capabilitiesSnapshot.supportsHLG))
                // Creation has no replay receipt. A later retry lists the registry
                // first; it never blindly repeats an uncertain POST.
                let created: Created = try await client.request("/downloads", method: .post,
                                                                body: JSONEncoder().encode(body), deviceID: deviceID)
                guard created.items.count == 1 else { throw AppError.invalidResponse }
                selected = created.items[0]
        }
        guard let selected, selected.media_file_id == fileID,
              (selected.episode_id ?? selected.content_id) == itemID,
              selected.quality == quality, selected.revision > 0 else { throw AppError.invalidResponse }
        let reference = SiloDownloadReference(id: selected.id, revision: selected.revision)
        try await persistReference(reference)
        var current = selected
        let deadline = ContinuousClock.now.advanced(by: .seconds(900))
        while !["ready", "downloading", "completed"].contains(current.status) {
            guard ["pending", "queued", "preparing"].contains(current.status) else { throw AppError.invalidResponse }
            guard ContinuousClock.now < deadline else { throw AppError.serverUnreachable }
            try await Task.sleep(for: .seconds(2))
            entries = try await downloadEntries()
            guard let updated = entries.first(where: { $0.id == reference.id }),
                  updated.revision == reference.revision else { throw AppError.conflict }
            current = updated
        }
        guard !requiresAllAudioTracks || current.delivery_format == "original" else {
            throw AppError.invalidResponse
        }
        let manifestPath = "/downloads/\(try SiloAPI.pathComponent(reference.id))/manifest"
        let (manifestData, _) = try await client.send(manifestPath, deviceID: deviceID)
        guard manifestData.count <= 1_048_576 else { throw AppError.invalidResponse }
        let manifest: SiloDownloadManifest
        do { manifest = try JSONDecoder().decode(SiloDownloadManifest.self, from: manifestData) }
        catch { throw AppError.decoding }
        guard manifest.download_id == reference.id, manifest.revision == reference.revision,
              manifest.media_file_id == fileID, manifest.file_size > 0 else { throw AppError.invalidResponse }
        guard manifest.integrity.map({ $0.expected_bytes == manifest.file_size }) != false else {
            throw AppError.invalidResponse
        }
        try await reportDownload(reference, status: "downloading", at: Date())
        let fileRoute = capability.proxy_delivery == true ? "file-proxy" : "file"
        let path = "/api/v2/downloads/\(try SiloAPI.pathComponent(reference.id))/\(fileRoute)"
        guard var components = URLComponents(url: session.server.baseURL, resolvingAgainstBaseURL: false) else {
            throw AppError.invalidResponse
        }
        let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = (basePath.isEmpty ? "" : "/" + basePath) + path
        guard let url = components.url else { throw AppError.invalidResponse }
        return SiloDownloadResolution(reference: reference, url: url,
                                      headers: try await client.downloadHeaders(deviceID: deviceID),
                                      expectedBytes: manifest.file_size,
                                      duration: manifest.duration_seconds, manifest: manifestData,
                                      metadata: MediaSourceMetadata(
                                        container: manifest.container, fileSizeBytes: manifest.file_size,
                                        sourceRevision: "silo-download:\(reference.id):\(reference.revision)",
                                        video: .init(codec: manifest.codec_video, videoRange: manifest.hdr.map { $0 ? "HDR" : "SDR" }),
                                        audio: .init(codec: manifest.codec_audio)))
    }

    public func reportDownload(_ reference: SiloDownloadReference, status: String, at date: Date) async throws {
        struct Body: Encodable { let status: String; let revision: Int; let updated_at: String }
        let result: SiloDownloadEntry = try await client.request(
            "/downloads/\(try SiloAPI.pathComponent(reference.id))", method: .patch,
            body: JSONEncoder().encode(Body(status: status, revision: reference.revision,
                                            updated_at: date.ISO8601Format(.iso8601(timeZone: .gmt, includingFractionalSeconds: true)))),
            deviceID: session.deviceID)
        guard result.id == reference.id, result.revision == reference.revision else { throw AppError.conflict }
    }

    public func validateDownloadCompletion(_ reference: SiloDownloadReference, manifest original: Data) async throws {
        let expected = try JSONDecoder().decode(SiloDownloadManifest.self, from: original)
        let current: SiloDownloadManifest = try await client.request(
            "/downloads/\(try SiloAPI.pathComponent(reference.id))/manifest", deviceID: session.deviceID)
        guard current.download_id == reference.id, current.revision == reference.revision,
              current.media_file_id == expected.media_file_id, current.file_size == expected.file_size,
              current.integrity?.metadata_etag == expected.integrity?.metadata_etag else {
            throw AppError.conflict
        }
    }

    public func removeDownload(_ reference: SiloDownloadReference) async throws {
        let entries = try await downloadEntries()
        guard let entry = entries.first(where: { $0.id == reference.id }) else { return }
        guard entry.revision == reference.revision else {
            PlozzLog.networking.info("Retired Silo download removal no longer names the current revision")
            return
        }
        do {
            try await client.send("/downloads/\(try SiloAPI.pathComponent(reference.id))",
                                  method: .delete, deviceID: session.deviceID)
        } catch AppError.notFound { return }
    }

    private func downloadEntries() async throws -> [SiloDownloadEntry] {
        var entries: [SiloDownloadEntry] = []
        var cursor: String?
        var seen = Set<String>()
        repeat {
            var query = [URLQueryItem(name: "limit", value: "100")]
            if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
            let page: SiloCollection<SiloDownloadEntry> = try await client.request(
                "/downloads", query: query, deviceID: session.deviceID)
            entries += page.items
            cursor = try page.nextCursor()
            if let cursor, !seen.insert(cursor).inserted { throw AppError.invalidResponse }
        } while cursor != nil
        return entries
    }
}
