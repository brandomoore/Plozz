import AetherEngine
import AVFoundation
import CoreModels
import FeaturePlayback

@MainActor
public final class PlozzigenNativePictureAnalyzer: NativeVideoActivePictureAnalyzing {
    private let analyzer = NativeActivePictureAnalyzer()

    public init() {}

    public func sample(player: AVPlayer, generation: UInt64, dynamicRange: SourceDynamicRange?) async -> VideoActivePictureState {
        let format: VideoFormat?
        switch dynamicRange {
        case .sdr: format = .sdr
        case .hdr10: format = .hdr10
        case .hdr10Plus: format = .hdr10Plus
        case .hlg: format = .hlg
        case .dolbyVision: format = .dolbyVision
        case nil: format = nil
        }
        return VideoActivePictureState(engineState: await analyzer.sample(player: player, generation: generation, videoFormat: format))
    }

    public func stop() { analyzer.stop() }
}

extension VideoActivePictureState {
    init(engineState: ActivePictureState) {
        switch engineState {
        case .unknown(.unsupportedColor), .unknown(.unsupportedGeometry): self = .unsupported
        case .unknown: self = .unavailable
        case .measured(let observation):
            self = .measured(normalizedRect: observation.normalizedRect, displaySize: observation.displaySize)
        }
    }
}
