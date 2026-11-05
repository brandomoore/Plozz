import Foundation

public enum DiscPlaybackBehavior: String, Codable, CaseIterable, Sendable {
    case playVideo
    case openMenu

    public var title: LocalizedStringResource {
        switch self {
        case .playVideo: "Play video"
        case .openMenu: "Open disc menu"
        }
    }

    public var alternative: Self { self == .playVideo ? .openMenu : .playVideo }
}

public enum DiscMenuAvailability: Codable, Equatable, Hashable, Sendable {
    case unknown
    case available
    case unavailable(DiscMenuUnavailableReason)

    public var canAttempt: Bool {
        if case .unavailable = self { return false }
        return true
    }
}

public enum DiscMenuUnavailableReason: String, Codable, Equatable, Hashable, Sendable {
    case missingMenu
    case unsupportedRuntime
    case unsupportedSource
    case incompleteMenu

    public var message: LocalizedStringResource {
        switch self {
        case .missingMenu: "This disc has no menu."
        case .unsupportedRuntime: "This disc's menu format is not supported."
        case .unsupportedSource: "This source does not provide access to disc menus."
        case .incompleteMenu: "Files needed to open the disc menu are missing."
        }
    }
}
public struct DiscPlaybackChoice: Equatable, Sendable {
    public let primary: DiscPlaybackBehavior
    public let alternative: DiscPlaybackBehavior?
    public let unavailableReason: DiscMenuUnavailableReason?

    public init(default behavior: DiscPlaybackBehavior, availability: DiscMenuAvailability) {
        if case .unavailable(let reason) = availability {
            primary = .playVideo
            alternative = nil
            unavailableReason = reason
        } else {
            primary = behavior
            alternative = behavior.alternative
            unavailableReason = nil
        }

    }
}

public extension MediaItem {
    func requestingDiscPlayback(_ behavior: DiscPlaybackBehavior) -> MediaItem {
        var selection = self
        selection.discPlaybackOverride = behavior
        selection.explicitSourceSelection = true
        return selection
    }

    func effectiveDiscPlayback(default behavior: DiscPlaybackBehavior) -> DiscPlaybackBehavior {
        if let discPlaybackOverride { return discPlaybackOverride }
        return discMenuAvailability?.canAttempt == true ? behavior : .playVideo
    }

    var discMenuAvailability: DiscMenuAvailability? {
        let version = selectedVersion ?? (versions.count == 1 ? versions.first : nil)
        let container = (version?.container ?? mediaInfo?.container)?.lowercased()
        guard container == "bdmv" else { return nil }
        let availability = version?.discMenuAvailability ?? .unknown
        // Older library snapshots classified all Java menus as unsupported.
        return availability == .unavailable(.unsupportedRuntime) ? .unknown : availability
    }
}

public enum DiscMenuInspection {
    /// Reads the top-menu declaration only. Malformed or unfamiliar metadata
    /// remains attemptable; a valid HDMV declaration is not a compatibility guarantee.
    public static func availability(index: Data) -> DiscMenuAvailability {
        guard index.count >= 40, index.count <= 2 * 1_024 * 1_024 else { return .unknown }
        let bytes = [UInt8](index)
        let header = String(decoding: bytes.prefix(8), as: UTF8.self)
        guard ["INDX0100", "INDX0200", "INDX0240", "INDX0300"].contains(header) else { return .unknown }
        func word(_ offset: Int) -> Int {
            bytes[offset..<offset + 4].reduce(0) { ($0 << 8) | Int($1) }
        }
        let offset = word(8)
        guard offset >= 40, offset <= bytes.count - 30 else { return .unknown }
        let length = word(offset)
        guard length >= 26, length <= bytes.count - offset - 4 else { return .unknown }
        let titles = Int(bytes[offset + 28]) << 8 | Int(bytes[offset + 29])
        guard titles <= (length - 26) / 12 else { return .unknown }
        switch bytes[offset + 16] >> 6 {
        case 1:
            let object = Int(bytes[offset + 22]) << 8 | Int(bytes[offset + 23])
            return object == 0xffff ? .unavailable(.missingMenu) : .unknown
        case 2:
            return .unknown
        default:
            return .unknown
        }
    }
}
