import CoreModels
@testable import CoreUI
@testable import FeatureLiveTV
import FeatureLiveTVCore
import SwiftUI
import UIKit
import Vision
import XCTest

@MainActor
final class LiveTVInitialLoadingHostedTests: XCTestCase {
    func testSavedLibraryChannelsNeverShowSetupWhileTheirCatalogIsPending() async throws {
        let profileID = ProfileStore.defaultProfileID
        let definitions = InitialLibraryDefinitions()
        let cache = LibraryChannelSnapshotStore(databaseURL: nil)
        let context = LibraryChannelProviderContext(
            accountID: "account", authorizationID: "fixture",
            provider: InitialLibraryProvider(), allowedLibraryIDs: ["library"]
        )
        let prepared = LibraryChannelService(profileID: profileID, store: definitions, snapshotStore: cache)
        prepared.setContexts([context])
        try await prepared.load()
        let now = Date()
        let preview = try await prepared.preview(
            recipe: LibraryChannelRecipe(name: "Saved movie channel",
                                         libraries: [.init(accountID: "account", libraryID: "library")],
                                         includesEpisodes: false),
            at: now
        )
        _ = try await prepared.publish(preview, at: now)
        let cold = LibraryChannelService(profileID: profileID, store: definitions, snapshotStore: cache)
        cold.setContexts([context])
        XCTAssertFalse(cold.isLoaded)

        let scene = try await foregroundScene()
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let sources = InitialEmptySources()
        let name = "LiveTVInitialLoading.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let approval = LiveTVSourceApprovalContext(
            profile: Profile(id: profileID, name: "Fixture"), parentalPIN: nil, activeAccountIDs: ["account"]
        )
        let host = UIHostingController(rootView: LiveTVPrototypeView(
            sourceStore: sources,
            profileID: profileID, preferencesNamespace: name,
            libraryService: cold,
            libraryHistory: LibraryChannelHistorySettings(defaults: defaults),
            sourceApprovalContext: { approval }
        ) { _ in Color.black }
            .environment(\.themePalette, .dark)
            .environment(\.colorScheme, .dark))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
            defaults.removePersistentDomain(forName: name)
        }
        // The persisted-source read finishes first; library loading is held here.
        try await Task.sleep(for: .milliseconds(300))
        window.layoutIfNeeded()
        let pending = try text(in: window)
        XCTAssertFalse(pending.contains("Add your channels"), pending)
        XCTAssertFalse(pending.contains("No channels available"), pending)
        XCTAssertFalse(pending.contains("Loading your channels"), pending)
        XCTAssertFalse(pending.contains("Find your next channel"), pending)
        let skeleton = XCTAttachment(image: DetailTransitionSnapshot.image(of: window))
        skeleton.name = "Live TV loading layout"
        skeleton.lifetime = .keepAlways
        add(skeleton)

        try await cold.load()
        let deadline = ContinuousClock.now + .seconds(5)
        var loaded = ""
        while ContinuousClock.now < deadline {
            await Task.yield()
            window.layoutIfNeeded()
            loaded = try text(in: window)
            if loaded.contains("Saved movie channel") { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(loaded.contains("Saved movie channel"), loaded)
        XCTAssertFalse(loaded.contains("Add your channels"), loaded)
        let content = XCTAttachment(image: DetailTransitionSnapshot.image(of: window))
        content.name = "Live TV loaded layout"
        content.lifetime = .keepAlways
        add(content)

        try definitions.save([])
        try await cold.load()
        let emptyDeadline = ContinuousClock.now + .seconds(5)
        var empty = ""
        while ContinuousClock.now < emptyDeadline {
            await Task.yield()
            window.layoutIfNeeded()
            empty = try text(in: window)
            if empty.contains("Add your channels") { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(empty.contains("Add your channels"), "A confirmed empty catalog must still offer setup: \(empty)")
    }

    private func text(in window: UIWindow) throws -> String {
        let image = DetailTransitionSnapshot.image(of: window)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    private func foregroundScene() async throws -> UIWindowScene {
        let deadline = ContinuousClock.now + .seconds(5)
        while !UIApplication.shared.connectedScenes.contains(where: { $0.activationState == .foregroundActive }),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        return try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
    }
}

private final class InitialEmptySources: LiveTVSourcesStoring, @unchecked Sendable {
    func load() throws -> LiveTVSourcesConfiguration { .empty }
    func save(_ configuration: LiveTVSourcesConfiguration) throws {}
}

private final class InitialLibraryDefinitions: LibraryChannelDefinitionStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var definitions: [LibraryChannelDefinition] = []
    func load() throws -> [LibraryChannelDefinition] { lock.withLock { definitions } }
    func save(_ values: [LibraryChannelDefinition]) throws { lock.withLock { definitions = values } }
}

private struct InitialLibraryProvider: LibraryChannelCatalogProviding {
    let kind = ProviderKind.jellyfin
    let session = UserSession(
        server: MediaServer(id: "fixture", name: "Fixture", baseURL: URL(string: "https://fixture.invalid")!, provider: .jellyfin),
        userID: "fixture", userName: "Fixture", deviceID: "fixture", accessToken: "fixture"
    )
    func libraryChannelItems(in libraryID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        var item = MediaItem(id: "movie", title: "Fixture movie", kind: .movie, runtime: 3600)
        item.libraryID = libraryID
        return MediaPage(items: [item], startIndex: page.startIndex, totalCount: 1)
    }
    func libraries() async throws -> [MediaLibrary] { [] }
    func continueWatching(limit: Int) async throws -> [MediaItem] { [] }
    func latest(limit: Int) async throws -> [MediaItem] { [] }
    func item(id: String) async throws -> MediaItem { throw AppError.notFound }
    func children(of itemID: String) async throws -> [MediaItem] { [] }
    func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage { throw AppError.notFound }
    func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
    func playbackInfo(for itemID: String) async throws -> PlaybackRequest { throw AppError.notFound }
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {}
    func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
}
