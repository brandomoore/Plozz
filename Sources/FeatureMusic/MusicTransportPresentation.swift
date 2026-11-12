import Observation

@MainActor
@Observable
final class MusicTransportPresentation {
    var queueRevision = 0
    var transportGeneration = 0
    var lastTransportWasBackward = false
    var playbackFailed = false
    var isResolving = false
    var isWaitingForData = false
}
