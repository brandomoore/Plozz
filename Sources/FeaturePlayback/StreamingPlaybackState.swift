import CoreModels
import Observation

@MainActor
@Observable
final class StreamingPlaybackState {
    var options: StreamingPlaybackOptions?
    var forceTranscodingSelected = false
    var error: StreamingQualityError?
    var failureReport: PlaybackDiagnosticReport?
    var preparation: StreamingPreparationPhase = .requesting
    var fallbackCodec: StreamingCodecPreference?
    var sourceWasHDR = false
    var currentStream = PlaybackStreamDetails()
}
