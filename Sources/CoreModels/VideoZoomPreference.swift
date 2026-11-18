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
    public static let onDemandDefault = VideoZoomPreference(mode: .fit)
    public var mode: Mode
    public let customPercent: Int
    public var pictureFitsInsideSafeArea: Bool

    public init(mode: Mode = .fit, customPercent: Int = 100, pictureFitsInsideSafeArea: Bool = false) {
        self.mode = mode
        self.customPercent = min(max(customPercent, Self.customPercentRange.lowerBound),
                                 Self.customPercentRange.upperBound)
        self.pictureFitsInsideSafeArea = pictureFitsInsideSafeArea
    }

    private enum CodingKeys: String, CodingKey {
        case mode, customPercent, pictureFitsInsideSafeArea, schemaVersion
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0
        let savedMode = try values.decode(Mode.self, forKey: .mode)
        // Reset pre-opt-in Auto-crop choices, including transferred title preferences.
        self.init(mode: version < 1 && savedMode == .picture ? .fit : savedMode,
                  customPercent: try values.decodeIfPresent(Int.self, forKey: .customPercent) ?? 100,
                  pictureFitsInsideSafeArea: try values.decodeIfPresent(Bool.self, forKey: .pictureFitsInsideSafeArea) ?? false)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(1, forKey: .schemaVersion)
        try values.encode(mode, forKey: .mode)
        try values.encode(customPercent, forKey: .customPercent)
        try values.encode(pictureFitsInsideSafeArea, forKey: .pictureFitsInsideSafeArea)
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
