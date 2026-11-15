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

/// Presentation keeps confirmed framing while the detector rebuilds evidence after a seek.
struct VideoActivePicturePresentation {
    private(set) var normalizedRect: CGRect?
    private(set) var displayAspectRatio: Double?
    private var sourceID: UUID?

    mutating func reconcile(sourceID: UUID?, aspectRatio: Double?) {
        if self.sourceID != sourceID {
            clear()
            self.sourceID = sourceID
        }
        if let aspectRatio,
           !aspectRatio.isFinite || aspectRatio <= 0
            || displayAspectRatio.map({ abs($0 - aspectRatio) >= 0.01 }) == true {
            clear()
        }
    }

    mutating func receive(_ result: VideoActivePictureState, sourceID: UUID?, aspectRatio: Double?) {
        reconcile(sourceID: sourceID, aspectRatio: aspectRatio)
        switch result {
        case .unavailable:
            if sourceID == nil { clear() }
        case .unsupported:
            clear()
        case let .measured(rect, size):
            guard VideoActivePictureGeometry.isValid(rect),
                  size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
                clear()
                return
            }
            guard let aspectRatio else {
                if sourceID == nil { clear() }
                return
            }
            guard aspectRatio.isFinite, aspectRatio > 0, abs(size.width / size.height - aspectRatio) < 0.01 else {
                clear()
                return
            }
            normalizedRect = rect
            displayAspectRatio = aspectRatio
        }
    }

    private mutating func clear() {
        normalizedRect = nil
        displayAspectRatio = nil
    }
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
