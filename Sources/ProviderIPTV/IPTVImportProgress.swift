import Foundation

public struct IPTVImportProgress: Sendable, Equatable {
    public enum Stage: Sendable { case playlist, channels, movies, series }
    public let stage: Stage
    public let entries: Int

    public var message: LocalizedStringResource {
        switch stage {
        case .playlist: "Reading playlist: \(entries) entries"
        case .channels: "Adding live channels: \(entries)"
        case .movies: "Adding movies: \(entries)"
        case .series: "Adding series: \(entries)"
        }
    }
}
