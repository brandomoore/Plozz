import Foundation
import CoreModels

/// Only server-issued URLs may refresh a persisted, credential-free image.
final class SiloArtworkStore: @unchecked Sendable {
    private let lock = NSLock()
    private var signed: [URL: URL] = [:]
    private var order: [URL] = []
    private var byItem: [String: [ImageKind: URL]] = [:]

    func record(_ url: URL?, itemID: String, kind: ImageKind) {
        guard let url else { return }
        lock.lock()
        defer { lock.unlock() }
        let key = SyncURLSanitizer.sanitize(url)
        signed[key] = url
        order.removeAll { $0 == key }
        order.append(key)
        byItem[itemID, default: [:]][kind] = key
        while order.count > 2048 {
            signed[order.removeFirst()] = nil
        }
        if byItem.count > 1024 {
            byItem = byItem.filter { $0.value.values.contains { signed[$0] != nil } }
            for key in byItem.keys.sorted().prefix(max(0, byItem.count - 2048)) {
                byItem[key] = nil
            }
        }
    }

    func url(itemID: String, kind: ImageKind) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        return byItem[itemID]?[kind].flatMap { signed[$0] }
    }

    func refreshed(_ url: URL) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        return signed[SyncURLSanitizer.sanitize(url)]
    }
}
