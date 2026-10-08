import Foundation

public struct IPTVImportProgress: Sendable, Equatable {
    public enum Stage: Sendable { case playlist, channels, movies, series, catalogCommit }
    public let stage: Stage
    public let entries: Int

    public var message: LocalizedStringResource {
        switch stage {
        case .playlist: "Reading playlist: \(entries.formatted())"
        case .channels: "Adding live channels: \(entries.formatted())"
        case .movies: "Adding movies: \(entries.formatted())"
        case .series: "Adding series: \(entries.formatted())"
        case .catalogCommit: "Updating library"
        }
    }
}
