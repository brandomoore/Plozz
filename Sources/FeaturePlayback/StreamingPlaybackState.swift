import CoreModels
import Observation

@MainActor
@Observable
final class StreamingPlaybackState {
    var options: StreamingPlaybackOptions?
    var error: StreamingQualityError?
    var preparation: StreamingPreparationPhase = .requesting
    var fallbackCodec: StreamingCodecPreference?
    var sourceWasHDR = false
}
