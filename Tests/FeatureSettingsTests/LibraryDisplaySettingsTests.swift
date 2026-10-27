import CoreModels
import Foundation
import SwiftUI
import XCTest
@testable import FeatureSettings

@MainActor
final class LibraryDisplaySettingsTests: XCTestCase {
    func testCollectionDirectoriesExposeCoversWithoutRecommendedRows() throws {
        try withModel { model in
            for provider: ProviderKind in [.jellyfin, .emby, .plex, .silo] {
                let page = page(kind: .collection, provider: provider, model: model, capable: false)
                XCTAssertTrue(page.showsCollectionCovers)
                XCTAssertFalse(page.showsRecommendedRows)
                XCTAssertEqual(page.collectionCoverSelection.wrappedValue, .auto)
            }
        }
    }

    func testOnlyCapableMovieAndSeriesLibrariesExposeCollectionBrowserAppearance() throws {
        try withModel { model in
            for kind: MediaItemKind in [.movie, .series, .video] {
                for capable in [false, true] {
                    let page = page(kind: kind, model: model, capable: capable)
                    XCTAssertEqual(page.showsCollectionCovers, capable && kind != .video)
                    XCTAssertTrue(page.showsRecommendedRows)
                }
            }
        }
    }

    func testSettingsEditTheExistingBrowserKeyWithoutResettingOtherRowsOrLibraries() throws {
        try withModel { model in
            let address = LibraryPresentationSettings.collectionCoverAddress(accountID: "account", libraryID: "library")
            let home = LibraryPresentationSettings.collectionCoverAddress(for: .library(key: "account:library", section: "recent"))
            let recommended = LibraryPresentationSettings.collectionCoverAddress(
                accountID: "account", libraryID: "library", rowID: "recommended"
            )
            model.settings.collectionCoverLayouts[address] = .landscape
            model.settings.collectionCoverLayouts[home] = .landscape
            model.settings.collectionCoverLayouts[recommended] = .poster
            let settings = page(kind: .collection, model: model)
            XCTAssertEqual(settings.collectionCoverSelection.wrappedValue, .landscape)
            settings.collectionCoverSelection.wrappedValue = .poster
            XCTAssertEqual(model.settings.collectionCoverLayout(at: address), .poster)
            XCTAssertEqual(model.settings.collectionCoverLayout(at: home), .landscape)
            XCTAssertEqual(model.settings.collectionCoverLayout(at: recommended), .poster)
            XCTAssertEqual(page(kind: .collection, model: model, libraryID: "other").collectionCoverSelection.wrappedValue, .auto)
        }
    }

    private func withModel(_ check: (LibraryPresentationSettingsModel) throws -> Void) throws {
        let suite = "LibraryDisplaySettingsTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try check(LibraryPresentationSettingsModel(store: LibraryPresentationSettingsStore(defaults: defaults)))
    }

    private func page(
        kind: MediaItemKind, provider: ProviderKind = .jellyfin,
        model: LibraryPresentationSettingsModel, capable: Bool = true, libraryID: String = "library"
    ) -> LibraryDisplaySettingsView {
        let provider = CoverSettingsProvider(kind: provider, supportsCollections: capable)
        return LibraryDisplaySettingsView(
            library: .init(
                accountID: "account", accountName: "Viewer", serverName: "Server", providerKind: provider.kind,
                library: .init(id: libraryID, title: "Library", kind: kind)
            ),
            account: .init(account: Account(id: "account", from: provider.session), provider: provider),
            model: model, loader: EmptyCoverSettingsLoader()
        )
    }
}

private struct EmptyCoverSettingsLoader: LibraryPresentationLoading {
    func libraries(accounts: [ResolvedAccount]) async -> LibraryPresentationDiscovery {
        .init(libraries: [], failures: [:])
    }
    func recommendations(library: AggregatedLibrary, account: ResolvedAccount) async -> LibraryPresentationRecommendations {
        .init(state: .empty, diagnostic: nil)
    }
}

private struct CoverSettingsProvider: MediaProvider, CapabilityReporting {
    let kind: ProviderKind
    let supportsCollections: Bool
    var capabilities: ProviderCapability { supportsCollections ? [.libraryCollections] : [] }
    var session: UserSession {
        .init(
            server: .init(id: "server", name: "Server", baseURL: URL(string: "https://settings.example")!, provider: kind),
            userID: "user", userName: "Viewer", deviceID: "device", accessToken: "test-token"
        )
    }
    func libraries() async throws -> [MediaLibrary] { [] }
    func continueWatching(limit: Int) async throws -> [MediaItem] { [] }
    func latest(limit: Int) async throws -> [MediaItem] { [] }
    func item(id: String) async throws -> MediaItem { throw AppError.notFound }
    func children(of itemID: String) async throws -> [MediaItem] { [] }
    func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        throw AppError.notFound
    }
    func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
    func playbackInfo(for itemID: String) async throws -> PlaybackRequest { throw AppError.notFound }
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {}
    func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
}
