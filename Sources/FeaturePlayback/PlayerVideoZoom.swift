#if canImport(UIKit)
import CoreGraphics
import Foundation
import Observation

public struct PlayerVideoZoom: Equatable, Sendable {
    public enum Mode: Int, CaseIterable, Sendable {
        case fit, fill, stretch, custom

        public var title: LocalizedStringResource {
            switch self {
            case .fit: "Normal"
            case .fill: "Crop"
            case .stretch: "Stretch"
            case .custom: "Custom"
            }
        }

        public var menuTitle: LocalizedStringResource {
            self == .fit ? "Normal (Default)" : title
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

    func scaleFactors(in bounds: CGRect, aspectRatio: Double?) -> CGVector {
        switch mode {
        case .fit: return CGVector(dx: 1, dy: 1)
        case .custom:
            let scale = CGFloat(customPercent) / 100
            return CGVector(dx: scale, dy: scale)
        case .fill, .stretch:
            guard let fitted = SubtitleOverlayGeometry.aspectFitRect(
                in: bounds, aspectRatio: aspectRatio.map { CGFloat($0) }
            ) else { return CGVector(dx: 1, dy: 1) }
            let horizontal = bounds.width / fitted.width
            let vertical = bounds.height / fitted.height
            if mode == .stretch { return CGVector(dx: horizontal, dy: vertical) }
            let scale = max(horizontal, vertical)
            return CGVector(dx: scale, dy: scale)
        }
    }

    func surfaceFrame(in bounds: CGRect, aspectRatio: Double?) -> CGRect {
        scaled(bounds, around: bounds, by: scaleFactors(in: bounds, aspectRatio: aspectRatio))
    }

    func videoRect(in bounds: CGRect, aspectRatio: Double?) -> CGRect? {
        guard let fitted = SubtitleOverlayGeometry.aspectFitRect(
            in: bounds, aspectRatio: aspectRatio.map { CGFloat($0) }
        ) else { return nil }
        return scaled(fitted, around: bounds, by: scaleFactors(in: bounds, aspectRatio: aspectRatio))
    }

    private func scaled(_ rect: CGRect, around bounds: CGRect, by scale: CGVector) -> CGRect {
        CGRect(x: bounds.midX + (rect.minX - bounds.midX) * scale.dx,
               y: bounds.midY + (rect.minY - bounds.midY) * scale.dy,
               width: rect.width * scale.dx, height: rect.height * scale.dy)
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
