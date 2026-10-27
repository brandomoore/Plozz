import Foundation

/// An explicit source-discovery action whose identity changes with its owner,
/// account, or playable target, so a presented picker cannot retain old choices.
public struct MediaVersionInventoryLoader: Identifiable, Sendable {
    public let id: String
    public let load: @MainActor @Sendable () async throws -> [MediaVersion]

    public init(id: String, load: @escaping @MainActor @Sendable () async throws -> [MediaVersion]) {
        self.id = id
        self.load = load
    }
}
