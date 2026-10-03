#if canImport(UIKit)
import CoreGraphics
import Foundation
import Observation

public struct PlayerVideoZoom: Equatable, Sendable {
    public enum Mode: Int, CaseIterable, Sendable {
        case fit, fill, custom

        public var title: LocalizedStringResource {
            switch self {
            case .fit: "Fit"
            case .fill: "Fill"
            case .custom: "Custom"
            }
        }
    }

    public static let customPercentRange = 50...200
    public var mode: Mode
    public let customPercent: Int

    public init(mode: Mode = .fit, customPercent: Int = 100) {
        self.mode = mode
        self.customPercent = min(max(customPercent, Self.customPercentRange.lowerBound),
                                 Self.customPercentRange.upperBound)
    }

    func scale(in bounds: CGRect, aspectRatio: Double?) -> CGFloat {
        switch mode {
        case .fit: return 1
        case .custom: return CGFloat(customPercent) / 100
        case .fill:
            guard let fitted = SubtitleOverlayGeometry.aspectFitRect(
                in: bounds, aspectRatio: aspectRatio.map { CGFloat($0) }
            ) else { return 1 }
            return max(bounds.width / fitted.width, bounds.height / fitted.height)
        }
    }

    func surfaceFrame(in bounds: CGRect, aspectRatio: Double?) -> CGRect {
        scaled(bounds, around: bounds, by: scale(in: bounds, aspectRatio: aspectRatio))
    }

    func videoRect(in bounds: CGRect, aspectRatio: Double?) -> CGRect? {
        guard let fitted = SubtitleOverlayGeometry.aspectFitRect(
            in: bounds, aspectRatio: aspectRatio.map { CGFloat($0) }
        ) else { return nil }
        return scaled(fitted, around: bounds, by: scale(in: bounds, aspectRatio: aspectRatio))
    }

    private func scaled(_ rect: CGRect, around bounds: CGRect, by scale: CGFloat) -> CGRect {
        CGRect(x: bounds.midX + (rect.minX - bounds.midX) * scale,
               y: bounds.midY + (rect.minY - bounds.midY) * scale,
               width: rect.width * scale, height: rect.height * scale)
    }
}

/// Playback-session presentation, never persisted as a profile/global preference.
@MainActor
@Observable
public final class PlayerVideoZoomModel {
    public var settings = PlayerVideoZoom()

    public init() {}

    public func cycleMode(forward: Bool) {
        let count = PlayerVideoZoom.Mode.allCases.count
        let index = (settings.mode.rawValue + (forward ? 1 : count - 1)) % count
        settings.mode = PlayerVideoZoom.Mode.allCases[index]
    }

    public func setCustomPercent(_ percent: Int) {
        settings = PlayerVideoZoom(mode: .custom, customPercent: percent)
    }
}
#endif
