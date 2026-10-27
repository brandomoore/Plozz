#if os(iOS)
import CoreModels
import CoreNetworking
import CoreUI
import Foundation
import MediaDownloads
import MetadataKit
import UIKit

enum PlozziOSDownloadArtwork {
    enum Failure: Error {
        case unavailable
        case invalidImage
    }

    static func references(
        for item: MediaItem, policy: ArtworkPresentationPolicy = .init(area: .downloads)
    ) -> [ArtworkReference] {
        let policy = policy.forArea(.downloads)
        var seen = Set<ArtworkReference>()
        return placements(for: item).flatMap { policy.references(for: item, placement: $0) }
            .filter { seen.insert($0).inserted }
    }

    static func placements(for item: MediaItem) -> [ArtworkPlacement] {
        switch item.kind {
        case .episode: [.detailBackdrop, .episodeThumbnail, .poster, .seriesPoster]
        case .season: [.detailBackdrop, .poster, .seriesPoster]
        default: [.detailBackdrop, .poster]
        }
    }

    static func lookup(for item: MediaItem, router: ArtworkRouter = .shared) async -> URL? {
        await ArtworkSession.artworkResolveLimiter.run {
            guard !Task.isCancelled else { return nil }
            return await router.artworkURL(for: item, placements: placements(for: item))
        }
    }

    static func load(
        for item: MediaItem, policy: ArtworkPresentationPolicy = .init(area: .downloads),
        router: ArtworkRouter = .shared
    ) async throws -> Data {
        let policy = policy.forArea(.downloads)
        try Task.checkCancellation()
        guard let artwork = await ArtworkFirstPaintResolver.resolve(
            references: references(for: item, policy: policy),
            variant: .landscapeCard,
            asyncOnlineURL: { await lookup(for: item, router: router) },
            prefersOnlineArtwork: policy.prefersOnlineArtwork,
            background: true
        ) else { throw Failure.unavailable }
        let data = await Task.detached(priority: .utility) {
            artwork.image.jpegData(compressionQuality: 0.85)
        }.value
        try Task.checkCancellation()
        guard let data, !data.isEmpty, data.count <= 15_000_000 else { throw Failure.invalidImage }
        return data
    }

    static func isValid(_ data: Data) -> Bool {
        !data.isEmpty && data.count <= 15_000_000
            && ArtworkImageCache.downsample(data, maxPixelSize: 64) != nil
    }

    static func isValidFile(at url: URL) async -> Bool {
        await Task.detached(priority: .utility) {
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size > 0, size <= 15_000_000,
                  let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return false }
            return isValid(data)
        }.value
    }
}

actor PlozziOSDownloadArtworkIndex {
    struct Entry: Sendable, Equatable {
        let createdAt: Date
        let fileName: String
        let url: URL?

        func matches(_ record: DownloadedMediaRecord) -> Bool {
            createdAt == record.createdAt && fileName == record.snapshot.artworkFileName
        }
    }

    private var entries: [String: Entry] = [:]

    func snapshot(
        records: [DownloadedMediaRecord],
        storage: any DownloadStorageLocating,
        refreshing: Bool
    ) throws(CancellationError) -> [String: Entry] {
        var next: [String: Entry] = [:]
        for record in records {
            guard !Task.isCancelled else { throw CancellationError() }
            guard let fileName = record.snapshot.artworkFileName else { continue }
            if !refreshing, let cached = entries[record.identityKey], cached.matches(record) {
                next[record.identityKey] = cached
            } else {
                next[record.identityKey] = Entry(
                    createdAt: record.createdAt, fileName: fileName,
                    url: existingURL(fileName: fileName, identityKey: record.identityKey, storage: storage)
                )
            }
        }
        entries = next
        return next
    }

    func write(
        _ data: Data, for record: DownloadedMediaRecord, storage: any DownloadStorageLocating
    ) throws -> URL {
        try Task.checkCancellation()
        guard PlozziOSDownloadArtwork.isValid(data) else {
            throw PlozziOSDownloadArtwork.Failure.invalidImage
        }
        let folder = try storage.pinnedFolderURL(forKey: record.identityKey)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("artwork-\(UUID().uuidString).jpg", isDirectory: false)
        try Task.checkCancellation()
        try data.write(to: url, options: .atomic)
        return url
    }

    func removeUnattachedFile(at url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            PlozzLog.networking.error("An unattached download artwork file could not be removed")
        }
    }

    private func existingURL(
        fileName: String, identityKey: String, storage: any DownloadStorageLocating
    ) -> URL? {
        guard !fileName.isEmpty,
              fileName == URL(fileURLWithPath: fileName, isDirectory: false).lastPathComponent,
              fileName != ".", fileName != ".." else {
            PlozzLog.networking.error("A pinned download artwork filename is invalid")
            return nil
        }
        do {
            let folder = try storage.pinnedFolderURL(forKey: identityKey)
            let url = folder.appendingPathComponent(fileName, isDirectory: false)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        } catch {
            PlozzLog.networking.error("Download artwork storage could not be resolved")
            return nil
        }
    }
}
#endif
