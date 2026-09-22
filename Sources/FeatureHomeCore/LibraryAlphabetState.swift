import CoreModels
import Foundation
import Observation

public struct LibraryAlphabetDestination: Equatable, Sendable {
    public let index: Int
    public let focusesItem: Bool
    public let id = UUID()
}

@MainActor
@Observable
public final class LibraryAlphabetState {
    public internal(set) var entries: [LibraryLetterIndexEntry] = []
    public internal(set) var isLoading = false
    public internal(set) var jumpingTo: String?
    public internal(set) var message: LocalizedStringResource?
    public internal(set) var destination: LibraryAlphabetDestination?
    public private(set) var positionLetter: String?
    public private(set) var isPositionLoading = false
    @ObservationIgnored var jumpTask: Task<Int?, Never>?
    @ObservationIgnored var jumpID = UUID()
    @ObservationIgnored var landingPage: Int?
    @ObservationIgnored var focusesItem = true

    func updatePosition(_ letter: String?) {
        if let letter { positionLetter = letter }
        isPositionLoading = letter == nil
    }

    public func completeDestination(_ id: UUID) {
        guard destination?.id == id else { return }
        destination = nil
    }

    public var isVisible: Bool { !entries.isEmpty || isLoading || message != nil }

    func cancelJump() {
        jumpID = UUID()
        jumpTask?.cancel()
        jumpTask = nil
        jumpingTo = nil
        landingPage = nil
    }

    func reset() {
        cancelJump()
        entries = []
        isLoading = false
        message = nil
        destination = nil
        positionLetter = nil
        isPositionLoading = false
    }
}
