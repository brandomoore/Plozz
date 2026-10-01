#if DEBUG && os(tvOS)
import CoreModels
import Foundation

enum PlayerSkipMarkerScenario: String, CaseIterable {
    case hourEpisode, shortEpisode, longMovie, recording, tinyRecap

    var duration: TimeInterval {
        switch self {
        case .hourEpisode: 3_600
        case .shortEpisode: 1_440
        case .longMovie: 10_800
        case .recording: 5_400
        case .tinyRecap: 2_700
        }
    }

    var target: MediaSegment {
        switch self {
        case .hourEpisode: .init(id: "hour-intro", kind: .intro, start: 90, end: 120)
        case .shortEpisode: .init(id: "short-intro", kind: .intro, start: 40, end: 130)
        case .longMovie: .init(id: "movie-credits", kind: .credits, start: 10_680, end: 10_800)
        case .recording: .init(id: "recording-ad2", kind: .commercial, start: 1_800, end: 1_980)
        case .tinyRecap: .init(id: "tiny-recap", kind: .recap, start: 60, end: 68)
        }
    }

    var segments: [MediaSegment] {
        switch self {
        case .hourEpisode:
            [target, .init(id: "hour-credits", kind: .credits, start: 3_540, end: 3_600)]
        case .shortEpisode:
            [target, .init(id: "short-credits", kind: .credits, start: 1_350, end: 1_440)]
        case .longMovie:
            [target]
        case .recording:
            [.init(id: "recording-ad1", kind: .commercial, start: 900, end: 1_080), target,
             .init(id: "recording-ad3", kind: .commercial, start: 3_000, end: 3_180),
             .init(id: "recording-ad4", kind: .commercial, start: 4_200, end: 4_380)]
        case .tinyRecap:
            [target, .init(id: "tiny-intro", kind: .intro, start: 120, end: 180),
             .init(id: "tiny-credits", kind: .credits, start: 2_640, end: 2_700)]
        }
    }

    var positions: [TimeInterval] {
        [max(0, target.start - 15), target.start, (target.start + target.end) / 2,
         target.end - 2, min(duration, target.end + 15)]
    }

    var buffers: [TimeInterval] {
        [(target.start + target.end) / 2, target.end - 5,
         min(duration, target.end + 15), min(duration, target.end + 120)]
    }

    var next: Self {
        guard let index = Self.allCases.firstIndex(of: self) else { return .hourEpisode }
        return Self.allCases[(index + 1) % Self.allCases.count]
    }

    @MainActor
    func apply(to model: PlayerControlsModel) {
        model.duration = duration
        model.currentSeconds = positions[2]
        model.bufferedSeconds = max(model.currentSeconds, buffers[1])
        model.skipSegments.segments = segments
    }
}
#endif
