import Foundation

public enum MusicFeedback: Equatable, Sendable {
    case favorite(Bool)
    /// Stars on a five-star scale; nil clears the rating.
    case rating(Double?)
}

public enum MusicFeedbackKind: Sendable {
    case favorite, rating
}

public protocol MusicFeedbackProviding: Sendable {
    var musicFeedbackKind: MusicFeedbackKind { get }
    func musicFeedback(for trackID: String) async throws -> MusicFeedback
    func setMusicFeedback(_ feedback: MusicFeedback, for trackID: String) async throws
}
