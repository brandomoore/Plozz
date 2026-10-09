import Foundation

public struct IPTVImportProgress: Sendable, Equatable {
    public enum Stage: Sendable { case connecting, playlist, channels, movies, series, catalogCommit }
    public let stage: Stage
    public let entries: Int

    public init(stage: Stage, entries: Int = 0) {
        self.stage = stage
        self.entries = entries
    }

    public var message: LocalizedStringResource {
        switch stage {
        case .connecting: "Connecting to your provider"
        case .playlist: "Reading playlist: \(entries.formatted())"
        case .channels: "Adding live channels: \(entries.formatted())"
        case .movies: "Adding movies: \(entries.formatted())"
        case .series: "Adding series: \(entries.formatted())"
        case .catalogCommit: "Updating library"
        }
    }

    public var title: LocalizedStringResource {
        switch stage {
        case .connecting: "Connecting to your provider"
        case .playlist: "Reading your playlist"
        case .channels: "Reading live channels"
        case .movies: "Reading movies"
        case .series: "Reading TV shows"
        case .catalogCommit: "Saving your library"
        }
    }

    public var detail: LocalizedStringResource {
        switch stage {
        case .connecting: "Waiting for your provider to respond."
        case .playlist, .channels, .movies, .series:
            "Keep Plozz open while your channels and titles are organized."
        case .catalogCommit: "Finishing this import before you choose your libraries."
        }
    }

    public var countLabel: LocalizedStringResource {
        switch stage {
        case .connecting, .playlist: "Playlist entries read"
        case .channels: "Live channels read"
        case .movies: "Movies read"
        case .series: "TV shows read"
        case .catalogCommit: "Library records saved"
        }
    }
}
