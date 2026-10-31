#if canImport(UIKit)
import CoreGraphics
import Foundation
import Observation

public struct PlayerVideoZoom: Equatable, Sendable {
    public enum Mode: Int, CaseIterable, Sendable {
        case fit, fill, stretch, custom, picture

        public var title: LocalizedStringResource {
            switch self {
            case .fit: "Normal"
            case .fill: "Crop"
            case .stretch: "Stretch"
            case .custom: "Custom"
            case .picture: "Fit picture"
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

    /// `fitBounds` constrains Normal and Custom's base, never Crop or Stretch.
    /// Both rectangles use the presentation view's coordinate space.
    func scaleFactors(in bounds: CGRect, aspectRatio: Double?, fitBounds: CGRect? = nil,
                      activePicture: CGRect? = nil) -> CGVector {
        if let transform = pictureTransform(in: bounds, aspectRatio: aspectRatio,
                                            fitBounds: fitBounds, activePicture: activePicture) {
            return CGVector(dx: transform.scale, dy: transform.scale)
        }
        switch mode {
        case .fit, .custom, .picture:
            let viewport = fittingBounds(in: bounds, fitBounds: fitBounds)
            let custom = mode == .custom ? CGFloat(customPercent) / 100 : 1
            guard viewport != bounds else { return CGVector(dx: custom, dy: custom) }
            let fitted = SubtitleOverlayGeometry.aspectFitRect(
                in: bounds, aspectRatio: aspectRatio.map { CGFloat($0) }
            ) ?? bounds
            guard fitted.width > 0, fitted.height > 0 else { return CGVector(dx: 1, dy: 1) }
            let normal = min(viewport.width / fitted.width, viewport.height / fitted.height)
            let scale = normal * custom
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

    func surfaceFrame(in bounds: CGRect, aspectRatio: Double?, fitBounds: CGRect? = nil,
                      activePicture: CGRect? = nil) -> CGRect {
        scaled(bounds, around: bounds, to: surfaceCenter(in: bounds, fitBounds: fitBounds,
                                                        aspectRatio: aspectRatio, activePicture: activePicture),
               by: scaleFactors(in: bounds, aspectRatio: aspectRatio, fitBounds: fitBounds, activePicture: activePicture))
    }

    func videoRect(in bounds: CGRect, aspectRatio: Double?, fitBounds: CGRect? = nil,
                   activePicture: CGRect? = nil) -> CGRect? {
        guard let fitted = SubtitleOverlayGeometry.aspectFitRect(
            in: bounds, aspectRatio: aspectRatio.map { CGFloat($0) }
        ) else { return nil }
        return scaled(fitted, around: bounds, to: surfaceCenter(in: bounds, fitBounds: fitBounds,
                                                              aspectRatio: aspectRatio, activePicture: activePicture),
                      by: scaleFactors(in: bounds, aspectRatio: aspectRatio, fitBounds: fitBounds, activePicture: activePicture))
    }

    func surfaceCenter(in bounds: CGRect, fitBounds: CGRect? = nil,
                       aspectRatio: Double? = nil, activePicture: CGRect? = nil) -> CGPoint {
        if let transform = pictureTransform(in: bounds, aspectRatio: aspectRatio,
                                            fitBounds: fitBounds, activePicture: activePicture) {
            return transform.center
        }
        let viewport = mode == .fit || mode == .custom || mode == .picture
            ? fittingBounds(in: bounds, fitBounds: fitBounds) : bounds
        return CGPoint(x: viewport.midX, y: viewport.midY)
    }

    private func pictureTransform(in bounds: CGRect, aspectRatio: Double?, fitBounds: CGRect?,
                                  activePicture: CGRect?) -> (scale: CGFloat, center: CGPoint)? {
        guard mode == .picture, let activePicture, VideoActivePictureGeometry.isValid(activePicture),
              let fitted = SubtitleOverlayGeometry.aspectFitRect(in: bounds, aspectRatio: aspectRatio.map { CGFloat($0) })
        else { return nil }
        let active = VideoActivePictureGeometry.map(activePicture, into: fitted)
        let viewport = fittingBounds(in: bounds, fitBounds: fitBounds)
        let scale = min(viewport.width / active.width, viewport.height / active.height)
        guard scale.isFinite, scale > 0, scale <= 2 else { return nil }
        return (scale, CGPoint(x: viewport.midX - (active.midX - bounds.midX) * scale,
                               y: viewport.midY - (active.midY - bounds.midY) * scale))
    }

    private func fittingBounds(in bounds: CGRect, fitBounds: CGRect?) -> CGRect {
        guard let fitBounds,
              fitBounds.minX.isFinite, fitBounds.minY.isFinite,
              fitBounds.width.isFinite, fitBounds.height.isFinite else { return bounds }
        let clipped = bounds.intersection(fitBounds)
        return clipped.isNull || clipped.isEmpty ? bounds : clipped
    }

    private func scaled(_ rect: CGRect, around bounds: CGRect, to center: CGPoint, by scale: CGVector) -> CGRect {
        CGRect(x: center.x + (rect.minX - bounds.midX) * scale.dx,
               y: center.y + (rect.minY - bounds.midY) * scale.dy,
               width: rect.width * scale.dx, height: rect.height * scale.dy)
    }
}

/// Playback-session presentation, never persisted as a profile/global preference.
@MainActor
@Observable
public final class PlayerVideoZoomModel {
    public var settings = PlayerVideoZoom()
    public var supportsActivePicture = false
    public var availableModes: [PlayerVideoZoom.Mode] {
        supportsActivePicture ? [.fit, .picture, .fill, .stretch, .custom] : [.fit, .fill, .stretch, .custom]
    }

    public init() {}

    public func cycleMode(forward: Bool) {
        let modes = availableModes
        let index = ((modes.firstIndex(of: settings.mode) ?? 0) + (forward ? 1 : modes.count - 1)) % modes.count
        settings.mode = modes[index]
    }

    public func setCustomPercent(_ percent: Int) {
        settings = PlayerVideoZoom(mode: .custom, customPercent: percent)
    }
}
#endif
