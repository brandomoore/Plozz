import CoreModels
import XCTest
@testable import FeatureHomeCore

final class CollectionSectionLoadingTests: XCTestCase {
    private func section(viewer: String = "viewer") -> CollectionSection {
        .init(id: "section", source: .init(
            accountID: "account", libraryID: "movies", collectionID: "collection",
            title: "Collection", serverUserID: viewer
        ))
    }

    private func visibility(_ section: CollectionSection) -> HomeLibraryVisibility {
        .init(
            rowCustomization: .init(defaults: .custom, order: [section.rowID], shown: [section.rowID]),
            collectionSections: [section]
        )
    }

    func testBothProvidersKeepCollectionOrderAndBoundRequests() async throws {
        for kind in [ProviderKind.plex, .jellyfin] {
            let provider = SectionProvider(kind: kind)
            let account = ResolvedAccount(account: Account(id: "account", from: provider.session), provider: provider)
            var section = section()
            section.cardStyle = .featured
            let content = await HomeAggregator().unmergedContent(
                from: [account], perLibraryLimit: 5, visibility: visibility(section)
            )
            let row = try XCTUnwrap(content.collectionRows.first)
            XCTAssertEqual(row.items.map(\.id), ["item-0", "item-1", "item-2", "item-3", "item-4"])
            XCTAssertTrue(row.items.allSatisfy { $0.sourceAccountID == "account" })
            XCTAssertNil(row.failure)
            XCTAssertFalse(row.isLoading)
            let requests = await provider.requests
            XCTAssertEqual(requests.map(\.startIndex), [0, 2, 4])
            XCTAssertEqual(requests.map(\.limit), [5, 3, 1])
            XCTAssertEqual(row.row.browseItem?.id, "collection")
            XCTAssertEqual(row.row.browseItem?.sourceAccountID, "account")
            XCTAssertEqual(row.row.collectionCardStyle, .featured)
        }
    }

    func testHiddenDisabledAndOtherViewerSourcesAreNotRequested() async {
        let provider = SectionProvider()
        let account = ResolvedAccount(account: Account(id: "account", from: provider.session), provider: provider)
        for reason in ["hidden", "disabled", "viewer"] {
            let section = section(viewer: reason == "viewer" ? "another-viewer" : "viewer")
            var visibility = visibility(section)
            if reason == "hidden" { visibility.rowCustomization?.setVisible(false, for: section.rowID) }
            if reason == "disabled" { visibility.setEnabled(false, for: "account:movies") }
            let content = await HomeAggregator().unmergedContent(from: [account], visibility: visibility)
            XCTAssertTrue(content.collectionRows.isEmpty, reason)
        }
        let requests = await provider.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testFailureIsNotAnEmptyCollectionAndCancellationCannotPublishItems() async throws {
        let provider = SectionProvider(failure: .serverUnreachable)
        let account = ResolvedAccount(account: Account(id: "account", from: provider.session), provider: provider)
        let section = section()
        let content = await HomeAggregator().unmergedContent(from: [account], visibility: visibility(section))
        XCTAssertEqual(content.collectionRows.first?.failure, .serverUnreachable)
        XCTAssertFalse(try XCTUnwrap(content.collectionRows.first).isLoading)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await CollectionPreviewLoader.load(
                selection: section.source, limit: 5, provider: provider, visibility: .default
            )
        }
        do {
            _ = try await cancelled.value
            XCTFail("Cancelled previews must not succeed")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testPresentationUsesCurrentStyleButNeverAReplacedSourcesItems() {
        var section = section()
        let item = MediaItem(id: "movie", title: "Movie", kind: .movie).taggingSource("account")
        let content = HomeViewModel.Content(collectionRows: [.init(definition: section, items: [item])])
        section.name = "New title"
        section.cardStyle = .landscape
        let rows = HomePresentationRow.resolve(rows: [], content: content, visibility: visibility(section))
        XCTAssertEqual(rows.first?.choice.title, "New title")
        if case let .library(row) = rows.first?.source {
            XCTAssertEqual(row.section.style, .landscape)
            XCTAssertEqual(row.collectionCardStyle, .landscape)
            XCTAssertEqual(row.browseItem?.id, "collection")
        } else { XCTFail("Expected collection media row") }
        section.cardStyle = .featured
        if case let .library(row) = HomePresentationRow.resolve(
            rows: [], content: content, visibility: visibility(section)
        ).first?.source {
            XCTAssertEqual(row.collectionCardStyle, .featured)
            XCTAssertEqual(row.section.items, [item])
            XCTAssertEqual(row.browseItem?.id, "collection")
        } else { XCTFail("Expected authored Featured row") }
        section.source = .init(accountID: "account", collectionID: "another", title: "Another", serverUserID: "viewer")
        XCTAssertTrue(HomePresentationRow.resolve(rows: [], content: content, visibility: visibility(section)).isEmpty)
    }

    func testServerCollectionCoversUseUniformAutoShapeAndPerRowOverrides() throws {
        let definition = HomeServerRowDefinition(
            accountID: "account", serverName: "Server", providerKind: .jellyfin,
            section: .init(id: "recent-collections", kind: .recentlyAdded, title: "Movie Collections")
        )
        let covers = (0..<3).map {
            MediaItem(id: "collection-\($0)", title: "Collection", kind: .collection, primaryImageAspectRatio: 16.0 / 9)
        }
        let content = HomeViewModel.Content(serverRows: [.init(definition: definition, items: covers)])
        let visibility = HomeLibraryVisibility(rowCustomization: .init(
            defaults: .custom, order: [definition.id], shown: [definition.id], serverRows: [definition]
        ))
        func row(_ settings: LibraryPresentationSettings) throws -> HomeLibrarySectionGroup.Row {
            let entry = try XCTUnwrap(HomePresentationRow.resolve(
                rows: [], content: content, visibility: visibility, presentation: settings
            ).first)
            guard case let .library(row) = entry.source else { throw AppError.invalidResponse }
            return row
        }
        XCTAssertEqual(try row(.default).section.style, .landscape)
        var settings = LibraryPresentationSettings.default
        settings.collectionCoverLayouts[LibraryPresentationSettings.collectionCoverAddress(for: definition.id)] = .poster
        XCTAssertEqual(try row(settings).section.style, .poster)
        XCTAssertEqual(try row(settings).section.items, covers)
        XCTAssertNil(try row(settings).browseItem)
    }

    @MainActor
    func testWatchChangesUpdateCollectionCardsWithoutChangingMembership() async throws {
        let provider = SectionProvider()
        let account = ResolvedAccount(account: Account(id: "account", from: provider.session), provider: provider)
        let settings = visibility(section())
        let model = HomeViewModel(accounts: [account], currentVisibility: { settings })
        await model.load()
        let before = try XCTUnwrap(model.state.value?.collectionRows.first?.items)
        let item = try XCTUnwrap(before.first)
        model.applyWatchedState(.init(itemIDs: [item.id], played: true, favorite: true))
        let after = try XCTUnwrap(model.state.value)
        XCTAssertEqual(after.collectionRows.first?.items.map(\.id), before.map(\.id))
        XCTAssertEqual(after.collectionRows.first?.items.first?.isPlayed, true)
        XCTAssertEqual(after.collectionRows.first?.items.first?.isFavorite, true)
        XCTAssertEqual(after.watchlist.first?.id, item.id)
    }

    func testEmptyAndMalformedCollectionPagesRemainDistinct() async throws {
        let item = MediaItem(id: "movie", title: "Movie", kind: .movie)
        let invalidPages: [MediaPage] = [
            .init(items: [], startIndex: 0, totalCount: 1),
            .init(items: [item], startIndex: 1, totalCount: 2),
            .init(items: [item], startIndex: 0, totalCount: 0),
            .init(items: [item, item], startIndex: 0, totalCount: 2)
        ]
        for page in invalidPages {
            do {
                _ = try await CollectionPreviewLoader.load(
                    selection: section().source, limit: 5,
                    provider: SectionProvider(pageOverride: page), visibility: .default
                )
                XCTFail("Malformed membership must fail instead of showing an empty or partial success.")
            } catch {
                XCTAssertEqual(error as? AppError, .invalidResponse)
            }
        }
        let empty = try await CollectionPreviewLoader.load(
            selection: section().source, limit: 5,
            provider: SectionProvider(pageOverride: .init(items: [], startIndex: 0, totalCount: 0)),
            visibility: .default
        )
        XCTAssertTrue(empty.items.isEmpty)
        XCTAssertEqual(empty.totalCount, 0)
    }

    @MainActor
    func testHomeDiagnosticsPublishFailureEmptyAndRecoveryForBothProviders() async throws {
        for kind in [ProviderKind.plex, .jellyfin] {
            let provider = SectionProvider(kind: kind, failure: .serverUnreachable)
            let account = ResolvedAccount(account: Account(id: "account", from: provider.session), provider: provider)
            let settings = visibility(section())
            let diagnostics = HomeSectionDiagnosticsModel()
            let model = HomeViewModel(
                accounts: [account], currentVisibility: { settings }, sectionDiagnostics: diagnostics
            )
            await model.load()
            let failed = try XCTUnwrap(diagnostics.issues(accounts: [account], visibility: settings).first)
            XCTAssertEqual(failed.reason, .failed(.serverUnreachable))
            XCTAssertEqual(failed.providerKind, kind)
            let failedRows = HomePresentationRow.resolve(
                rows: [], content: try XCTUnwrap(model.state.value), visibility: settings
            )
            if case let .library(row) = failedRows.first?.source {
                XCTAssertEqual(row.issue, failed)
            } else { XCTFail("Missing content must retain a visible, ordered explanation.") }

            await provider.setResponse(failure: nil, page: .init(items: [], startIndex: 0, totalCount: 0))
            await diagnostics.retry(accounts: [account], visibility: settings)
            XCTAssertEqual(diagnostics.issues(accounts: [account], visibility: settings).first?.reason, .empty)
            let emptyRows = HomePresentationRow.resolve(
                rows: [], content: try XCTUnwrap(model.state.value), visibility: settings
            )
            if case let .library(row) = emptyRows.first?.source {
                XCTAssertEqual(row.browseItem?.id, "collection", "Warnings must retain collection browsing.")
            } else { XCTFail("Expected an empty collection notice.") }

            await provider.setResponse(failure: nil, page: nil)
            await diagnostics.retry(accounts: [account], visibility: settings)
            XCTAssertTrue(diagnostics.issues(accounts: [account], visibility: settings).isEmpty)
            XCTAssertFalse(try XCTUnwrap(model.state.value?.collectionRows.first).items.isEmpty)
            XCTAssertFalse(diagnostics.isLoading)
        }
    }

    @MainActor
    func testDiagnosticsRejectOtherViewersVisibilityChangesAndSupersededLoads() async throws {
        let provider = SectionProvider()
        let account = ResolvedAccount(account: Account(id: "account", from: provider.session), provider: provider)
        let other = SectionProvider(viewer: "other")
        let otherAccount = ResolvedAccount(account: account.account, provider: other)
        let settings = visibility(section())
        let issue = HomeSectionIssue(choice: .init(collectionSection: section()), reason: .empty)
        let diagnostics = HomeSectionDiagnosticsModel()
        var retries = 0
        let old = diagnostics.begin(accounts: [account], visibility: settings)
        let current = diagnostics.begin(accounts: [otherAccount], visibility: settings)
        diagnostics.finish(old, issues: [issue]) { retries += 1 }
        XCTAssertTrue(diagnostics.issues(accounts: [account], visibility: settings).isEmpty)
        XCTAssertTrue(diagnostics.isLoading)
        diagnostics.finish(current, issues: [issue]) { retries += 1 }
        let reauthenticated = ResolvedAccount(account: Account(id: "account", from: other.session), provider: other)
        XCTAssertTrue(diagnostics.issues(accounts: [reauthenticated], visibility: settings).isEmpty)
        await diagnostics.retry(accounts: [reauthenticated], visibility: settings)
        XCTAssertEqual(retries, 0)
        XCTAssertTrue(diagnostics.issues(accounts: [account], visibility: settings).isEmpty)
        await diagnostics.retry(accounts: [account], visibility: settings)
        XCTAssertEqual(retries, 0)
        var changed = settings
        changed.rowCustomization?.setVisible(false, for: section().rowID)
        XCTAssertTrue(diagnostics.issues(accounts: [otherAccount], visibility: changed).isEmpty)
        await diagnostics.retry(accounts: [otherAccount], visibility: changed)
        XCTAssertEqual(retries, 0)
        let cancelled = diagnostics.begin(accounts: [otherAccount], visibility: settings)
        diagnostics.cancel(cancelled)
        XCTAssertTrue(diagnostics.issues(accounts: [otherAccount], visibility: settings).isEmpty)
        XCTAssertFalse(diagnostics.isLoading)
    }

    @MainActor
    func testLibraryDiagnosticsDistinguishEmptyMissingAndFailedWithoutWarningForHiddenRows() async throws {
        let provider = SectionProvider()
        let account = ResolvedAccount(account: Account(id: "account", from: provider.session), provider: provider)
        let library = AggregatedLibrary(
            accountID: "account", accountName: "Viewer", serverName: "Server", providerKind: .plex,
            library: MediaLibrary(id: "movies", title: "Movies", kind: .movie)
        )
        let recent = HomeRowID.library(library.key, kind: .recentlyAdded)
        let missing = HomeRowID.library(key: library.key, section: "saved-hub")
        var settings = HomeLibraryVisibility(rowCustomization: .init(
            defaults: .custom, order: [recent, missing], shown: [recent, missing]
        ))
        var content = HomeViewModel.Content(libraries: [library], mergeLibraries: false)
        func issues() -> [HomeSectionIssue] {
            HomeSectionIssueResolver.resolve(content: content, failures: [:], visibility: settings, accounts: [account])
        }
        XCTAssertEqual(issues().first { $0.id == recent }?.reason, .empty)
        XCTAssertEqual(issues().first { $0.id == missing }?.reason, .notReturned)
        content.librarySections = [.init(library: library, sections: [], failures: [.hubs: .unauthorized])]
        XCTAssertEqual(issues().first { $0.id == missing }?.reason, .failed(.unauthorized))
        settings.rowCustomization?.setVisible(false, for: missing)
        XCTAssertNil(issues().first { $0.id == missing })
        settings.setEnabled(false, for: library.key)
        XCTAssertTrue(issues().isEmpty)
    }

    @MainActor
    func testCancelledRequestsAndOtherViewerCollectionsHaveNoFailureWarning() async throws {
        let provider = SectionProvider(failure: .cancelled)
        let account = ResolvedAccount(account: Account(id: "account", from: provider.session), provider: provider)
        let settings = visibility(section())
        let model = HomeViewModel(accounts: [account], currentVisibility: { settings })
        await model.load()
        XCTAssertTrue(try XCTUnwrap(model.state.value).sectionIssues.isEmpty)
        XCTAssertTrue(HomeSectionIssueResolver.resolve(
            content: .init(), failures: [:], visibility: visibility(section(viewer: "other")), accounts: [account]
        ).isEmpty)
    }

    @MainActor
    func testServerWarningOrderingAndStaleCollectionSourceSuppression() throws {
        let provider = SectionProvider(kind: .jellyfin)
        let account = ResolvedAccount(account: Account(id: "account", from: provider.session), provider: provider)
        let server = HomeServerRowDefinition(
            accountID: "account", serverName: "Server", providerKind: .jellyfin,
            section: .init(id: "custom", kind: .recommendations, title: "Top picks")
        )
        let section = section()
        var settings = HomeLibraryVisibility(
            rowCustomization: .init(
                defaults: .custom, order: [server.id, section.rowID], shown: [server.id, section.rowID],
                serverRows: [server]
            ),
            collectionSections: [section]
        )
        var content = HomeViewModel.Content(
            serverRows: [.init(definition: server, failure: .invalidResponse)],
            collectionRows: [.init(definition: section)]
        )
        content.sectionIssues = HomeSectionIssueResolver.resolve(
            content: content, failures: [:], visibility: settings, accounts: [account]
        )
        XCTAssertEqual(content.sectionIssues.first { $0.id == server.id }?.reason, .failed(.invalidResponse))
        XCTAssertEqual(HomePresentationRow.resolve(rows: [], content: content, visibility: settings).map(\.id),
                       [server.id, section.rowID])
        settings.collectionSections[0].source = .init(
            accountID: "account", collectionID: "different", title: "Different", serverUserID: "viewer"
        )
        XCTAssertEqual(HomePresentationRow.resolve(rows: [], content: content, visibility: settings).map(\.id), [server.id])
        settings.rowCustomization?.setVisible(false, for: server.id)
        XCTAssertTrue(HomePresentationRow.resolve(rows: [], content: content, visibility: settings).isEmpty)
    }
}

private actor SectionProvider: MediaProvider {
    nonisolated let kind: ProviderKind
    nonisolated let session: UserSession
    private var failure: AppError?
    private var pageOverride: MediaPage?
    private(set) var requests: [PageRequest] = []

    init(kind: ProviderKind = .plex, failure: AppError? = nil, pageOverride: MediaPage? = nil, viewer: String = "viewer") {
        self.kind = kind
        self.failure = failure
        self.pageOverride = pageOverride
        self.session = UserSession(
            server: MediaServer(id: "server", name: "Server", baseURL: URL(string: "https://example.com")!, provider: kind),
            userID: viewer, userName: "Viewer", deviceID: "device", accessToken: "test-token"
        )
    }

    func setResponse(failure: AppError?, page: MediaPage?) {
        self.failure = failure
        pageOverride = page
    }

    func collectionMembers(of collectionID: String, page: PageRequest) async throws -> MediaPage {
        requests.append(page)
        if let failure { throw failure }
        if let pageOverride { return pageOverride }
        let items = (0..<30).map {
            MediaItem(id: "item-\($0)", title: "Item \($0)", kind: .movie).taggingLibrary("movies")
        }
        return .init(items: Array(items.dropFirst(page.startIndex).prefix(min(2, page.limit))),
                     startIndex: page.startIndex, totalCount: items.count)
    }

    func libraries() async throws -> [MediaLibrary] { [.init(id: "movies", title: "Movies", kind: .movie)] }
    func continueWatching(limit: Int) async throws -> [MediaItem] { [] }
    func latest(limit: Int) async throws -> [MediaItem] { [] }
    func item(id: String) async throws -> MediaItem { throw AppError.notFound }
    func children(of itemID: String) async throws -> [MediaItem] { [] }
    func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage { throw AppError.notFound }
    func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
    func playbackInfo(for itemID: String) async throws -> PlaybackRequest { throw AppError.notFound }
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {}
    nonisolated func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
}
