import CoreModels
import CoreNetworking
import CryptoKit
import Foundation

/// One bounded, credential-free snapshot per profile; scope changes cannot reuse it.
public actor UpcomingFeedCache {
    public static let shared = UpcomingFeedCache(
        directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("plozz-upcoming-v1", isDirectory: true)
    )

    public struct Snapshot: Codable, Sendable {
        public var releases: [UpcomingRelease]
        public var failedSourceCount: Int
        public var savedAt: Date
        var scope: String
    }

    private let directory: URL?
    private let maximumBytes = 16 * 1024 * 1024

    public init(directory: URL?) {
        self.directory = directory
    }

    public func load(scope: String, namespace: String?, now: Date = Date()) -> Snapshot? {
        guard let file = file(namespace: namespace),
              FileManager.default.fileExists(atPath: file.path) else { return nil }
        do {
            let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= maximumBytes else { throw AppError.invalidResponse }
            let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: file))
            guard snapshot.scope == Self.digest(scope),
                  now.timeIntervalSince(snapshot.savedAt) >= 0,
                  now.timeIntervalSince(snapshot.savedAt) < 7 * 24 * 60 * 60 else { return nil }
            return snapshot
        } catch {
            PlozzLog.networking.error("Upcoming cache could not be read; refreshing releases")
            return nil
        }
    }

    public func save(
        releases: [UpcomingRelease], failedSourceCount: Int,
        scope: String, namespace: String?, savedAt: Date
    ) {
        guard let directory, let file = file(namespace: namespace) else { return }
        do {
            let sanitized = releases.map { release in
                var release = release
                release.item = release.item.sanitizingArtworkCredentials()
                return release
            }
            let snapshot = Snapshot(
                releases: sanitized, failedSourceCount: failedSourceCount,
                savedAt: savedAt, scope: Self.digest(scope)
            )
            let data = try JSONEncoder().encode(snapshot)
            guard data.count <= maximumBytes else { throw AppError.invalidResponse }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
        } catch {
            PlozzLog.networking.error("Upcoming cache could not be saved")
        }
    }

    private func file(namespace: String?) -> URL? {
        directory?.appendingPathComponent(Self.digest(namespace.map { "profile:\($0)" } ?? "default") + ".json")
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
