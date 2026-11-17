import Foundation

/// The viewer's framing choice, not a saved detector rectangle.
public struct VideoZoomPreference: Codable, Equatable, Sendable {
    public enum Mode: Int, Codable, CaseIterable, Sendable {
        case fit, fill, stretch, custom, picture

        public var title: LocalizedStringResource {
            switch self {
            case .fit: "Normal"
            case .fill: "Crop"
            case .stretch: "Stretch"
            case .custom: "Custom"
            case .picture: "Auto-crop black bars"
            }
        }

        public var menuTitle: LocalizedStringResource { title }
    }

    public static let customPercentRange = 50...200
    public static let onDemandDefault = VideoZoomPreference(mode: .picture)
    public var mode: Mode
    public let customPercent: Int

    public init(mode: Mode = .fit, customPercent: Int = 100) {
        self.mode = mode
        self.customPercent = min(max(customPercent, Self.customPercentRange.lowerBound),
                                 Self.customPercentRange.upperBound)
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(mode: try values.decode(Mode.self, forKey: .mode),
                  customPercent: try values.decodeIfPresent(Int.self, forKey: .customPercent) ?? 100)
    }
}

public struct VideoZoomDefaults: Codable, Equatable, Sendable {
    public enum Platform: String, CaseIterable, Sendable {
        case phone, tablet, television
    }

    public var phone: VideoZoomPreference
    public var tablet: VideoZoomPreference
    public var television: VideoZoomPreference

    public init(
        phone: VideoZoomPreference = .onDemandDefault,
        tablet: VideoZoomPreference = .onDemandDefault,
        television: VideoZoomPreference = .onDemandDefault
    ) {
        self.phone = phone
        self.tablet = tablet
        self.television = television
    }

    public subscript(platform: Platform) -> VideoZoomPreference {
        get {
            switch platform {
            case .phone: phone
            case .tablet: tablet
            case .television: television
            }
        }
        set {
            switch platform {
            case .phone: phone = newValue
            case .tablet: tablet = newValue
            case .television: television = newValue
            }
        }
    }

    private enum CodingKeys: String, CodingKey { case phone, tablet, television }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            phone: try values.decodeIfPresent(VideoZoomPreference.self, forKey: .phone) ?? .onDemandDefault,
            tablet: try values.decodeIfPresent(VideoZoomPreference.self, forKey: .tablet) ?? .onDemandDefault,
            television: try values.decodeIfPresent(VideoZoomPreference.self, forKey: .television) ?? .onDemandDefault
        )
    }
}
