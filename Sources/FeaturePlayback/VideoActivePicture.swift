import AVFoundation
import CoreModels

@MainActor
public protocol NativeVideoActivePictureAnalyzing: AnyObject {
    func sample(player: AVPlayer, generation: UInt64, dynamicRange: SourceDynamicRange?) async -> VideoActivePictureState
    func stop()
}

public enum VideoActivePictureState: Equatable, Sendable {
    case unsupported
    case unavailable
    case measured(normalizedRect: CGRect, displaySize: CGSize)
}

enum VideoActivePictureGeometry {
    static func isValid(_ rect: CGRect) -> Bool {
        rect.minX.isFinite && rect.minY.isFinite && rect.width.isFinite && rect.height.isFinite
            && rect.minX >= 0 && rect.minY >= 0 && rect.maxX <= 1 && rect.maxY <= 1
            && rect.width >= 0.5 && rect.height >= 0.5
    }

    static func map(_ normalized: CGRect?, into video: CGRect) -> CGRect {
        guard let normalized, isValid(normalized) else { return video }
        return CGRect(x: video.minX + normalized.minX * video.width,
                      y: video.minY + normalized.minY * video.height,
                      width: normalized.width * video.width, height: normalized.height * video.height)
    }
}
