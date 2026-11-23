import CoreModels
import Foundation
import XCTest

/// A unique profile for a real service façade backed by the recording transport.
final class TrackerPauseFixture {
    let namespace = UUID().uuidString
    let item = MediaItem(id: "movie", title: "Movie", kind: .movie, providerIDs: ["Tmdb": "1", "anilist": "2", "mal": "3"])

    deinit {
        for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasSuffix("." + namespace) {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    @MainActor
    func pause(_ service: any TrackerHistorySyncReading, http: RecordingHTTPClient,
               playback: () async throws -> Void) async throws {
        let identity = try XCTUnwrap(service.historySyncIdentity)
        let original = try XCTUnwrap(service.historyActivationID)
        try service.setTrackerEnabled(false)
        XCTAssertFalse(service.trackerEnabled)
        XCTAssertNil(service.historyActivationID)
        XCTAssertEqual(service.historySyncIdentity, identity)
        let before = http.sentPaths
        try await playback()
        XCTAssertEqual(http.sentPaths, before)
        try service.setTrackerEnabled(true)
        XCTAssertNotEqual(try XCTUnwrap(service.historyActivationID), original)
        try service.setTrackerEnabled(false)
    }
}
