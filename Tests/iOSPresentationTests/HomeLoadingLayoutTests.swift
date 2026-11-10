#if os(iOS)
import CoreModels
import CoreNetworking
import CoreUI
import FeatureAuth
@testable import FeatureHomeCore
import HeroUI
import Observation
import ProviderJellyfin
import ProviderPlex
import SwiftUI
import UIKit
import XCTest
@testable import AppShelliOS

@MainActor
final class HomeLoadingLayoutTests: XCTestCase {
    func testLiveJellyfinCompletedEpisodeRemainsOnHome() async throws {
        guard let address = ProcessInfo.processInfo.environment["PLOZZ_LIVE_REFRESH_BROKER"] else {
            throw XCTSkip("Requires the authorized internal history-mutation broker.")
        }
        guard let broker = URL(string: address), broker.scheme == "http", broker.host == "127.0.0.1",
              broker.port != nil, broker.user == nil, broker.password == nil,
              broker.query == nil, broker.fragment == nil else { throw AppError.invalidResponse }
        func operation(_ action: String) async throws -> Data {
            var request = URLRequest(url: broker.appendingPathComponent("jellyfin/\(action)/series"),
                                     timeoutInterval: 90)
            if action != "configuration" { request.httpMethod = "POST" }
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw AppError.invalidResponse }
            return data
        }
        struct Configuration: Decodable {
            let baseURL: URL
            let serverID: String
            let userID: String
            let username: String
            let deviceID: String
            let token: String
            let firstEpisodeID: String
            let secondEpisodeID: String
        }
        let config = try JSONDecoder().decode(Configuration.self, from: await operation("configuration"))
        let session = UserSession(
            server: .init(id: config.serverID, name: "Internal history", baseURL: config.baseURL, provider: .jellyfin),
            userID: config.userID, userName: config.username, deviceID: config.deviceID, accessToken: config.token
        )
        let provider = JellyfinProvider(session: session, http: LiveHomeReadOnlyHTTP())
        let accounts = [ResolvedAccount(account: Account(id: "live-jellyfin", from: session), provider: provider)]
        let retainedFixture = try Fixture()
        defer { retainedFixture.close() }
        let retainedVisibility = retainedFixture.app.settings.homeVisibility
        await retainedVisibility.prepareServerDefaults(accounts: accounts)
        retainedVisibility.setMergeNextUpIntoContinueWatching(true)
        let retained = HomeViewModel(
            accounts: accounts, profileNamespace: retainedFixture.profileID,
            layoutStore: InMemoryHomeLayoutStore(), contentStore: NoOpHomeContentStore(),
            currentVisibility: { retainedVisibility.visibility }
        )
        defer { retained.invalidate() }
        for action in ["prepare", "advance"] {
            _ = try await operation(action)
            let expected = action == "prepare" ? config.firstEpisodeID : config.secondEpisodeID
            let feed = try await provider.continueWatching(limit: .max)
            XCTAssertTrue(feed.contains { $0.id == expected }, "Expected episode must reach the provider feed.")
            XCTAssertTrue(ContinueWatchingPolicy.default.curated(feed).contains { $0.id == expected },
                          "Expected episode must survive progress eligibility.")
            await retained.load(showLoadingState: action == "prepare")
            XCTAssertTrue(retained.state.value?.continueWatching.contains { $0.id == expected } == true,
                          "The existing Home model must advance without a profile switch or cold start.")
            if action == "advance" {
                XCTAssertFalse(retained.state.value?.continueWatching.contains { $0.id == config.firstEpisodeID } == true,
                               "The completed episode must leave the refreshed row.")
            }
            for includeNextUp in [true, false] {
                let fixture = try Fixture()
                defer { fixture.close() }
                let visibility = fixture.app.settings.homeVisibility
                await visibility.prepareServerDefaults(accounts: accounts)
                visibility.setMergeNextUpIntoContinueWatching(includeNextUp)
                let model = HomeViewModel(
                    accounts: accounts, profileNamespace: fixture.profileID,
                    layoutStore: InMemoryHomeLayoutStore(), contentStore: NoOpHomeContentStore(),
                    currentVisibility: { visibility.visibility }
                )
                defer { model.invalidate() }
                await model.load()
                let content = try XCTUnwrap(model.state.value)
                let present = content.continueWatching.contains { $0.id == expected }
                XCTAssertEqual(present, action == "prepare" || includeNextUp,
                               "Home must include a paused episode, and include the next episode when enabled.")
                print("LIVE_SERIES_HISTORY phase=\(action) includeNextUp=\(includeNextUp) expectedOnHome=\(present) providerItems=\(feed.count) homeItems=\(content.continueWatching.count)")
            }
        }
    }

    func testLiveJellyfinLibraryRows() async throws {
        try await exerciseLiveRows(kinds: [.jellyfin])
    }

    func testLivePlexLibraryRows() async throws {
        try await exerciseLiveRows(kinds: [.plex])
    }

    func testLiveCombinedLibraryRows() async throws {
        try await exerciseLiveRows(kinds: [.jellyfin, .plex])
    }

    private func exerciseLiveRows(kinds: [ProviderKind]) async throws {
        guard let address = ProcessInfo.processInfo.environment["PLOZZ_LIVE_HOME_ROWS_BROKER"] else {
            throw XCTSkip("Requires an authorized, read-only internal Home broker.")
        }
        guard let broker = URL(string: address),
              broker.scheme == "http", broker.host == "127.0.0.1", broker.port != nil,
              broker.user == nil, broker.password == nil, broker.query == nil, broker.fragment == nil else {
            throw AppError.invalidResponse
        }
        let http = LiveHomeReadOnlyHTTP()
        var accounts: [ResolvedAccount] = []
        for kind in kinds {
            let (data, response) = try await URLSession.shared.data(for: URLRequest(
                url: broker.appendingPathComponent(kind.rawValue), timeoutInterval: 15
            ))
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw AppError.invalidResponse }
            let config = try JSONDecoder().decode(LiveHomeConfiguration.self, from: data)
            guard ["http", "https"].contains(config.baseURL.scheme),
                  config.baseURL.host != nil, config.baseURL.user == nil, config.baseURL.password == nil,
                  config.baseURL.query == nil, config.baseURL.fragment == nil, !config.token.isEmpty else {
                throw AppError.invalidResponse
            }
            let session = UserSession(
                server: .init(id: config.serverID, name: "Internal Home", baseURL: config.baseURL, provider: kind),
                userID: config.userID, userName: config.username, deviceID: config.deviceID, accessToken: config.token
            )
            let provider: any MediaProvider = kind == .plex
                ? PlexProvider(session: session, http: http) : JellyfinProvider(session: session, http: http)
            accounts.append(.init(account: Account(id: "live-\(kind.rawValue)", from: session), provider: provider))
        }
        let fixture = try Fixture()
        defer { fixture.close() }
        let metadata = fixture.app.metadataProviderSettingsModel.settings
        fixture.app.metadataProviderSettingsModel.settings = MetadataProviderSettings(
            orderMode: .custom, preferOnlineArtwork: false, disabledOrder: MetadataSourceAttribution.all.map(\.id)
        )
        defer { fixture.app.metadataProviderSettingsModel.settings = metadata }
        let visibility = fixture.app.settings.homeVisibility
        await visibility.prepareServerDefaults(accounts: accounts)
        XCTAssertTrue(visibility.serverMatchFailures.isEmpty, "Live server layout discovery must succeed.")
        let model = HomeViewModel(
            accounts: accounts, profileNamespace: fixture.profileID,
            layoutStore: InMemoryHomeLayoutStore(), contentStore: NoOpHomeContentStore(),
            currentVisibility: { visibility.visibility }
        )
        defer { model.invalidate() }
        await model.load()
        let content = try XCTUnwrap(model.state.value)
        XCTAssertFalse(content.libraries.isEmpty)
        XCTAssertTrue(content.serverRows.allSatisfy { !$0.isLoading && $0.failure == nil })
        let presentations = HomePresentationRow.resolve(rows: [], content: content, visibility: visibility.visibility)
        let libraryRows = presentations.filter { if case .library = $0.source { true } else { false } }
        XCTAssertGreaterThan(libraryRows.count, 1, "Real data must exercise multiple library rows.")
        let coordinator = FeaturedTrailerCoordinator()
        let controller = HeroTrailerController()
        var sampled: [(HomeRowChoice, RowState)] = []
        var checkedItems = 0
        var browsePages = 0
        for presentation in libraryRows.prefix(8) {
            guard case let .library(row) = presentation.source, !row.section.items.isEmpty else { continue }
            checkedItems += row.section.items.count
            let encoded = try JSONEncoder().encode(row.section.items)
            let copy = try JSONDecoder().decode([MediaItem].self, from: encoded)
            var decoded = row.section
            decoded.items = copy
            func view(_ value: HomeLibrarySectionGroup.Row) -> PlozziOSHomeLibraryPresentationRow {
                .init(choice: presentation.choice, row: value, appModel: fixture.app, viewModel: model,
                      coordinator: coordinator, controller: controller, isActive: false,
                      rowBrowser: .constant(nil), showingHomeCustomization: .constant(false))
            }
            // Boolean assertions keep real media and authenticated URLs out of failure logs.
            func decodedRow() -> HomeLibrarySectionGroup.Row {
                .init(section: decoded, isLoading: row.isLoading, failure: row.failure,
                      browseItem: row.browseItem, issue: row.issue, collectionCardStyle: row.collectionCardStyle)
            }
            XCTAssertTrue(view(row) == view(row))
            // Decoding normalizes persisted fields and omits transient selection state.
            let left = decodedRow()
            decoded.items = try JSONDecoder().decode([MediaItem].self, from: encoded)
            XCTAssertTrue(view(left) == view(decodedRow()), "Independently decoded live data must remain equal.")
            let last = decoded.items.count - 1
            if decoded.items[last].people.isEmpty {
                decoded.items[last].people = [
                    MediaPerson(id: "local-control", name: "Local control", role: "Actor",
                                kind: "Actor", biography: "Changed")
                ]
            } else {
                decoded.items[last].people[0].biography = "Local metadata invalidation control"
            }
            XCTAssertFalse(view(left) == view(decodedRow()), "Same identity must not hide a metadata change.")
            let rebuilt = HomePresentationRow(choice: presentation.choice, source: .library(row))
            XCTAssertTrue(rebuilt == presentation)
            if presentation.canBrowse && browsePages < 3 {
                let browse = model.browseRow(rebuilt)
                await browse.load()
                XCTAssertNil(browse.error)
                XCTAssertFalse(browse.items.isEmpty)
                let allowed = Set(accounts.map(\.account.id))
                XCTAssertTrue(browse.items.allSatisfy { $0.sourceAccountID.map(allowed.contains) == true })
                browsePages += 1
                browse.invalidate()
            }
            sampled.append((presentation.choice, RowState(row: row)))
        }
        XCTAssertGreaterThan(checkedItems, 0)
        XCTAssertGreaterThan(browsePages, 0, "At least one real paged shelf must be browsed.")
        let represented = Set(sampled.flatMap { $0.1.row.section.items.compactMap(\.sourceAccountID) })
        XCTAssertTrue(Set(accounts.map(\.account.id)).isSubset(of: represented),
                      "Mounted rows must contain data from every requested provider.")
        let width: CGFloat = UIDevice.current.userInterfaceIdiom == .pad ? 1024 : 390
        fixture.mount(PlozziOSHomeScrollView(heroActive: false) {
            EmptyView()
        } rows: {
            ForEach(sampled.indices, id: \.self) { index in
                ReservedLibraryRow(
                    choice: sampled[index].0, state: sampled[index].1, app: fixture.app,
                    model: model, coordinator: coordinator, controller: controller
                )
            }
        }, width: width)
        try await fixture.settle()
        let layoutDeadline = ContinuousClock.now + .seconds(5)
        var mountedScroll: UIScrollView?
        repeat {
            mountedScroll = fixture.scrollViews().first
            if mountedScroll?.contentSize.height == 0 { mountedScroll = nil }
            if mountedScroll == nil { try await fixture.settle() }
        } while mountedScroll == nil && ContinuousClock.now < layoutDeadline
        let scroll = try XCTUnwrap(mountedScroll)
        let height = scroll.contentSize.height
        let bottom = max(0, height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
        let verticalTargets: [CGFloat] = bottom > 1 ? [0.5, 1, 0.25, 0] : []
        for fraction in verticalTargets {
            let target = bottom * fraction
            scroll.setContentOffset(CGPoint(x: 0, y: target), animated: true)
            let deadline = ContinuousClock.now + .seconds(3)
            while abs(scroll.contentOffset.y - target) > 1, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(30))
            }
            XCTAssertEqual(scroll.contentOffset.y, target, accuracy: 1)
            XCTAssertEqual(scroll.contentSize.height, height, accuracy: 1)
        }
        let rail = try XCTUnwrap(fixture.scrollViews().first { $0.contentSize.width > $0.bounds.width + 1 })
        let right = rail.contentSize.width - rail.bounds.width + rail.adjustedContentInset.right
        for fraction: CGFloat in [0.5, 1, 0] {
            let target = right * fraction
            rail.setContentOffset(CGPoint(x: target, y: rail.contentOffset.y), animated: true)
            let deadline = ContinuousClock.now + .seconds(3)
            while abs(rail.contentOffset.x - target) > 1, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(30))
            }
            XCTAssertEqual(rail.contentOffset.x, target, accuracy: 1)
            XCTAssertEqual(scroll.contentSize.height, height, accuracy: 1)
        }
        let first = try XCTUnwrap(sampled.first)
        let original = first.1.row
        var loading = original.section
        loading.items = []
        first.1.row = .init(section: loading, isLoading: true, failure: nil)
        try await fixture.settle()
        XCTAssertEqual(scroll.contentSize.height, height, accuracy: 1)
        first.1.row = .init(section: loading, isLoading: false, failure: .serverUnreachable)
        try await fixture.settle()
        XCTAssertEqual(scroll.contentSize.height, height, accuracy: 1)
        first.1.row = original
        try await fixture.settle()
        XCTAssertEqual(scroll.contentSize.height, height, accuracy: 1)
        fixture.app.settings.cardStyle.captions = CardCaptionSettings(showsLabels: false)
        try await fixture.settle()
        XCTAssertLessThan(scroll.contentSize.height, height)
        fixture.app.settings.cardStyle.captions = CardCaptionSettings(showsLabels: true)
        try await fixture.settle()
        XCTAssertEqual(scroll.contentSize.height, height, accuracy: 1)
        await model.load(showLoadingState: false)
        let refreshed = try XCTUnwrap(model.state.value)
        XCTAssertTrue(refreshed.serverRows.allSatisfy { !$0.isLoading && $0.failure == nil })
        XCTAssertFalse(refreshed.libraries.isEmpty)
        let refreshedRows = HomePresentationRow.resolve(rows: [], content: refreshed, visibility: visibility.visibility)
        for (choice, state) in sampled {
            guard let next = refreshedRows.first(where: { $0.id == choice.id }),
                  case let .library(row) = next.source else {
                XCTFail("Previously mounted live shelf must survive this read-only refresh.")
                continue
            }
            state.row = row
        }
        try await fixture.settle()
        let counts = await http.counts()
        XCTAssertEqual(counts.blocked, 0, "Home/browse must never attempt a write or playback request.")
        XCTAssertGreaterThan(counts.reads, 0)
        print("LIVE_HOME_ROWS providers=\(kinds.count) rows=\(sampled.count) items=\(checkedItems) browsePages=\(browsePages) reads=\(counts.reads) blocked=\(counts.blocked) width=\(Int(width)) height=\(Int(height)) verticalTargets=\(verticalTargets.count) horizontalTargets=3")
    }

    private struct LiveHomeConfiguration: Decodable {
        let baseURL: URL
        let serverID: String
        let userID: String
        let username: String
        let deviceID: String
        let token: String
    }

    private actor LiveHomeReadOnlyHTTP: HTTPClient {
        private let wrapped = URLSessionHTTPClient()
        private var reads = 0
        private var blocked = 0

        func counts() -> (reads: Int, blocked: Int) { (reads, blocked) }

        func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
            let path = endpoint.path.lowercased()
            guard endpoint.method == .get, endpoint.body == nil,
                  !path.contains("/:/"), !path.contains("playbackinfo"),
                  !path.contains("transcode"), !path.contains("/sessions") else {
                blocked += 1
                throw AppError.invalidResponse
            }
            reads += 1
            return try await wrapped.send(endpoint, baseURL: baseURL)
        }
    }

    func testFramedLandscapeCardsFitNarrowGridAndNormalRailSlots() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let metrics = PlozzMetrics.touch(density: .standard)
        for width: CGFloat in [169, metrics.landscapeCardSlotWidth, 360] {
            var cardSize = CGSize.zero
            fixture.mount(
                ScrollView {
                    PosterCardView(
                        item: fixture.items[0], style: .landscape, action: {}
                    )
                    .environment(\.plozzCardStyle, .framed)
                    .environment(\.plozzCardCaptionSettings, CardCaptionSettings(showsLabels: false))
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { cardSize = $0 }
                    .frame(width: width)
                }
            )
            try await fixture.settle()
            XCTAssertEqual(cardSize.width, width, accuracy: 0.5)
            XCTAssertEqual(
                cardSize.height, (width - 2 * metrics.cardInset) * 9 / 16 + 2 * metrics.cardInset,
                accuracy: 0.5
            )
        }
    }

    func testLandscapeBrowseColumnsUseWideCardsOnPhoneTabletAndMac() {
        for density in UIDensity.allCases {
            for sizeClass in [UserInterfaceSizeClass.compact, .regular] {
                for isMac in [false, true] {
                    let columns = density.iOSLandscapeGridColumns(
                        horizontalSizeClass: sizeClass, isRunningOnMac: isMac
                    )
                    XCTAssertEqual(columns.count, 1)
                    guard case let .adaptive(minimum, maximum) = columns[0].size else {
                        return XCTFail("Landscape grids must adapt their column count.")
                    }
                    if isMac {
                        let metrics = PlozzMetrics.desktop(density: density)
                        XCTAssertEqual(minimum, metrics.landscapeWidth)
                        XCTAssertEqual(maximum, minimum * 1.18, accuracy: 0.001)
                        XCTAssertEqual(columns[0].spacing, metrics.gridSpacing)
                    } else {
                        XCTAssertEqual(minimum, sizeClass == .regular ? 240 : 160)
                        XCTAssertEqual(columns[0].spacing, 12)
                    }
                }
            }
        }
    }

    func testMacBrowseThresholdDoesNotShortenLoadedRowsOrChangeMobilePolicy() throws {
        let choice = try XCTUnwrap(HomeRowChoice.shared.first { $0.id == .global(.continueWatching) })
        let threshold = PlozziOSMediaRailLayout.desktopBrowseThreshold
        XCTAssertEqual(threshold, 10)
        for count in [0, 1, 10, 11, 20, 40] {
            let items = (0..<count).map { MediaItem(id: "\($0)", title: "Movie", kind: .movie) }
            for hasMore in [false, true] {
                var home = HomeRow(kind: .continueWatching, items: items)
                home.hasMore = hasMore
                let section = LibrarySection(id: "shelf", title: "Shelf", items: items, hasMore: hasMore)
                for row in [
                    HomePresentationRow(choice: choice, source: .home(home)),
                    HomePresentationRow(choice: choice, source: .library(
                        .init(section: section, isLoading: false, failure: nil)
                    ))
                ] {
                    XCTAssertEqual(row.supportsBrowsing(loadedItemThreshold: threshold), count > 10)
                    XCTAssertEqual(row.canBrowse, hasMore && count > 0)
                    switch row.source {
                    case let .home(value): XCTAssertEqual(value.items.count, count)
                    case let .library(value): XCTAssertEqual(value.section.items.count, count)
                    case .liveTV: XCTFail("Unexpected source")
                    }
                }
                for (loading, failure): (Bool, AppError?) in [(true, nil), (false, .serverUnreachable)] {
                    home.loadingPlaceholderCount = loading ? 20 : 0
                    home.failure = failure
                    XCTAssertFalse(HomePresentationRow(choice: choice, source: .home(home))
                        .supportsBrowsing(loadedItemThreshold: threshold))
                    let retained = HomePresentationRow(choice: choice, source: .library(
                        .init(section: section, isLoading: loading, failure: failure)
                    ))
                    XCTAssertEqual(retained.supportsBrowsing(loadedItemThreshold: threshold), count > 10)
                    XCTAssertEqual(retained.canBrowse, hasMore && count > 0)
                }
            }
        }
        XCTAssertFalse(HomePresentationRow(choice: choice, source: .liveTV([]))
            .supportsBrowsing(loadedItemThreshold: threshold))
    }

    func testRelatedBrowserKeepsTheWholeRowAndInvalidatesAfterProfileSwitch() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let entries = fixture.items.map {
            RelatedEntry(related: .init(title: $0.title, kind: .movie, source: .tmdb), libraryItem: $0)
        }
        let model = PlozziOSRelatedSection.makeBrowser(entries: entries, appModel: fixture.app)
        XCTAssertEqual(model.items.map(\.stablePresentationID), fixture.items.map(\.stablePresentationID))
        XCTAssertEqual(model.items.count, 20)
        XCTAssertFalse(model.hasMore)
        await model.load()
        XCTAssertNil(model.error)
        XCTAssertEqual(model.items.count, 20)
        let next = fixture.app.profiles.add(name: "Other", isAwaitingSetup: false)
        defer {
            fixture.app.profiles.remove(next.id)
            for key in UserDefaults.standard.dictionaryRepresentation().keys
            where key.components(separatedBy: ".").contains(next.id) {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        fixture.app.selectProfile(next.id)
        await model.load()
        XCTAssertFalse(model.scopeIsCurrent)
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertEqual(model.error, .notFound)
    }

    func testRelatedChevronAppearsOnlyAboveTenItemsOnMac() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        var plainEdge: CGFloat?
        for (isMac, count) in [(true, 10), (true, 11), (false, 11)] {
            let entries = fixture.items.prefix(count).map {
                RelatedEntry(related: .init(title: $0.title, kind: .movie, source: .tmdb), libraryItem: $0)
            }
            fixture.mount(
                ScrollView {
                    PlozziOSRelatedSection(entries: entries, inset: 52, onSelect: { _, _ in })
                }
                .environment(\.plozziOSIsRunningOnMac, isMac),
                width: 1039
            )
            try await fixture.settle()
            let image = renderedImage(fixture.window)
            let edge = try rightmostHeaderInk(in: image)
            if let plainEdge {
                if isMac { XCTAssertGreaterThan(edge, plainEdge + 8) }
                else { XCTAssertEqual(edge, plainEdge, accuracy: 1) }
            } else { plainEdge = edge }
            let attachment = XCTAttachment(image: image)
            attachment.name = "related-chevron-mac-\(isMac)-items-\(count)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    private func rightmostHeaderInk(in image: UIImage) throws -> CGFloat {
        let cgImage = try XCTUnwrap(image.cgImage)
        let header = try XCTUnwrap(cgImage.cropping(to: CGRect(
            x: 0, y: 0, width: 300 * image.scale, height: 32 * image.scale
        )))
        var pixels = [UInt8](repeating: 0, count: header.width * header.height * 4)
        try pixels.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(
                data: bytes.baseAddress, width: header.width, height: header.height, bitsPerComponent: 8,
                bytesPerRow: header.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ))
            context.draw(header, in: CGRect(x: 0, y: 0, width: header.width, height: header.height))
        }
        var rightmost = 0
        for y in 0..<header.height {
            for x in 0..<header.width {
                let offset = (y * header.width + x) * 4
                if pixels[offset] > 72, pixels[offset + 1] > 72, pixels[offset + 2] > 72 {
                    rightmost = max(rightmost, x)
                }
            }
        }
        XCTAssertGreaterThan(rightmost, 0)
        return CGFloat(rightmost) / image.scale
    }

    func testMacSizingPreservesMobileMetricsAndProfileDensity() {
        var previousWidth: CGFloat = 0
        for density in UIDensity.allCases {
            for size in [DynamicTypeSize.large, .accessibility3] {
                let mobile = PlozziOSMediaLayout.metrics(density: density, dynamicTypeSize: size, isRunningOnMac: false)
                let desktop = PlozziOSMediaLayout.metrics(density: density, dynamicTypeSize: size, isRunningOnMac: true)
                XCTAssertEqual(mobile, .touch(density: density, dynamicTypeSize: size))
                XCTAssertFalse(mobile.usesDesktopSizing)
                XCTAssertTrue(desktop.usesDesktopSizing)
                XCTAssertEqual(desktop.posterWidth, 212 * density.scale)
                XCTAssertEqual(desktop.landscapeWidth, 360 * density.scale)
                XCTAssertEqual(desktop.castTileDiameter, 160 * density.scale)
                XCTAssertEqual(desktop.cardInset, mobile.cardInset)
                XCTAssertEqual(desktop.watchedBadgeSize, mobile.watchedBadgeSize)
                XCTAssertEqual(PlozziOSMediaLayout.episodeWidth(metrics: desktop, sizeClass: .regular), desktop.landscapeWidth)
                XCTAssertEqual(PlozziOSMediaLayout.episodeWidth(metrics: mobile, sizeClass: .regular), 360)
                XCTAssertEqual(PlozziOSMediaLayout.episodeWidth(metrics: mobile, sizeClass: .compact), 300)
            }
            let desktop = PlozzMetrics.desktop(density: density)
            XCTAssertGreaterThan(desktop.posterWidth, previousWidth)
            previousWidth = desktop.posterWidth
            XCTAssertGreaterThan(
                PlozzMetrics.desktop(density: density, dynamicTypeSize: .accessibility3).continueWatchingWidth,
                desktop.continueWatchingWidth
            )
        }
        XCTAssertEqual(PlozzMetrics.desktop(density: .standard).continueWatchingWidth, 360)
    }

    func testMacRailsPreserveAnExactNextCardPeekAcrossWidthsAndDensities() {
        for density in UIDensity.allCases {
            let metrics = PlozzMetrics.desktop(density: density)
            for style in [CardStyle.borderless, .framed] {
                for width in stride(from: CGFloat(600), through: 2600, by: 13) {
                    let resolved = PlozziOSHomeRailLayout<EmptyView>.posterMetrics(
                        in: width, inset: 36, metrics: metrics, cardStyle: style
                    )
                    XCTAssertEqual(resolved.fittingDesktopRail(in: width, cardStyle: style), resolved)
                    for (artwork, maximum) in [
                        (resolved.posterWidth, metrics.posterWidth),
                        (resolved.landscapeWidth, metrics.landscapeWidth),
                        (resolved.continueWatchingWidth, metrics.continueWatchingWidth)
                    ] {
                        let frameInset = style == .framed ? metrics.cardInset : 0
                        let visibleWidth = artwork + 2 * frameInset
                        let leading = DesktopMediaRailLayout.pageInset - frameInset
                        let count = floor((width - leading) / (visibleWidth + metrics.cardSpacing))
                        let peek = width - leading - count * (visibleWidth + metrics.cardSpacing)
                        XCTAssertEqual(peek, metrics.cardSpacing, accuracy: 0.001)
                        XCTAssertLessThanOrEqual(artwork, maximum + 0.001)
                        XCTAssertGreaterThan(artwork, 0)
                    }
                }
            }
            let grid = density.iOSPosterGridColumns(horizontalSizeClass: .regular, isRunningOnMac: true)
            guard case .adaptive(let minimum, let maximum) = grid[0].size else {
                return XCTFail("Desktop grids must adapt their column count.")
            }
            XCTAssertEqual(minimum, metrics.posterWidth)
            XCTAssertEqual(maximum, minimum * 1.18, accuracy: 0.001)
            XCTAssertEqual(density.iOSHomeLibraryWidth(horizontalSizeClass: .regular, isRunningOnMac: true),
                           metrics.landscapeWidth)
        }
    }

    func testMacRailsMatchReferenceColumnCountsAndProportions() {
        // Screenshots have different export scales. Normalize each measured
        // content width/card width by its leading content inset, not image pixels.
        let references: [(viewport: CGFloat, inset: CGFloat, landscape: CGFloat, posters: CGFloat?, cast: CGFloat?)] = [
            (1745, 47, 312, 186, 145),
            (1621, 65, 350, nil, nil),
            (1422, 70, 404, 229, nil),
            (1558, 78, 443, 250, 200)
        ]
        let metrics = PlozzMetrics.desktop(density: .standard)
        for reference in references {
            let scale = DesktopMediaRailLayout.pageInset / reference.inset
            let resolved = metrics.fittingDesktopRail(in: reference.viewport * scale, cardStyle: .borderless)
            XCTAssertEqual(resolved.landscapeWidth / scale, reference.landscape, accuracy: 3)
            XCTAssertEqual(resolved.continueWatchingWidth, resolved.landscapeWidth)
            if let posters = reference.posters {
                XCTAssertEqual(resolved.posterWidth / scale, posters, accuracy: 3)
            }
            if let cast = reference.cast {
                XCTAssertEqual(resolved.castTileDiameter / scale, cast, accuracy: 3)
            }
        }
        let featured = DesktopMediaRailLayout.featuredSize(in: 1930, metrics: metrics)
        XCTAssertEqual(featured.height / featured.width, 1.25, accuracy: 0.001)
        let count = floor((1930 - DesktopMediaRailLayout.pageInset) / (featured.width + metrics.cardSpacing))
        XCTAssertEqual(count, 4)
        XCTAssertEqual(1930 - DesktopMediaRailLayout.pageInset - count * (featured.width + metrics.cardSpacing), 26)
    }

    func testMacPostersKeepReferenceColumnsAcrossTheWideWindowBreakpoint() {
        let metrics = PlozzMetrics.desktop(density: .standard)
        // The paired screenshots put this viewport just above 1,950 points.
        // The old limit added a ninth full poster here despite keeping the peek.
        for width: CGFloat in [1952, 1960, 1970, 1980] {
            for style in [CardStyle.borderless, .framed] {
                let resolved = metrics.fittingDesktopRail(in: width, cardStyle: style)
                let frameInset = style == .framed ? metrics.cardInset : 0
                let pitch = resolved.posterWidth + 2 * frameInset + metrics.cardSpacing
                let count = floor((width - DesktopMediaRailLayout.pageInset + frameInset) / pitch)
                XCTAssertEqual(count, 8, "Reference window \(width) must not fit nine full posters.")
                let featured = DesktopMediaRailLayout.featuredSize(in: width, metrics: resolved)
                XCTAssertEqual(floor((width - DesktopMediaRailLayout.pageInset)
                    / (featured.width + metrics.cardSpacing)), 4)
            }
        }
        for (width, expectedCount): (CGFloat, CGFloat) in [(1039, 5), (1297, 6), (1930, 8)] {
            let resolved = metrics.fittingDesktopRail(in: width, cardStyle: .borderless)
            XCTAssertEqual(floor((width - DesktopMediaRailLayout.pageInset)
                / (resolved.posterWidth + metrics.cardSpacing)), expectedCount)
        }
    }

    func testMacHeroLogoRemainsCompactAndHonorsEverySizePreference() {
        XCTAssertEqual(PlozziOSPageLayout.homeTextMaxWidth(for: .landscape, logoSize: .default), 480)
        XCTAssertEqual(PlozziOSPageLayout.homeTextMaxWidth(
            for: .landscape, logoSize: .default, isRunningOnMac: true
        ), 360)
        for size in HeroLogoSize.allSizes {
            let width = PlozziOSPageLayout.homeTextMaxWidth(for: .landscape, logoSize: size, isRunningOnMac: true)
            let box = PlozziOSPageLayout.heroLogoBox(
                for: .landscape, size: size, availableWidth: width, isRunningOnMac: true
            )
            let mobileBox = PlozziOSPageLayout.heroLogoBox(for: .landscape, size: size)
            XCTAssertLessThan(box.width, mobileBox.width)
            XCTAssertLessThan(box.height, mobileBox.height)
            for aspect: CGFloat in [0.08, 0.75, 3] {
                let fitted = HeroLogoFit.fittedSize(
                    for: CGSize(width: 1000, height: 1000 * aspect),
                    maxWidth: box.width, maxHeight: box.height
                )
                XCTAssertLessThanOrEqual(fitted.width, width + 0.001)
                XCTAssertLessThanOrEqual(fitted.height, 220)
            }
        }
    }

    func testRenderedMacRowsKeepTheNextCardPeekAndMatchingHeadings() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let url = try XCTUnwrap(URL(string: "https://mac-rail.invalid/\(UUID()).png"))
        let artwork = UIGraphicsImageRenderer(size: CGSize(width: 320, height: 480)).image { context in
            UIColor(red: 0.05, green: 0.65, blue: 1, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 320, height: 480))
        }
        let cache = try XCTUnwrap(ArtworkSession.shared.configuration.urlCache)
        let response = try XCTUnwrap(HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "image/png", "Cache-Control": "max-age=86400"]
        ))
        cache.storeCachedResponse(
            CachedURLResponse(response: response, data: try XCTUnwrap(artwork.pngData())),
            for: URLRequest(url: url)
        )
        let items = (0..<20).map {
            MediaItem(id: "peek-\($0)", title: "Movie", kind: .movie, productionYear: 2024,
                      posterURL: url, backdropURL: url, allowsTitleBasedMetadataMatching: false)
        }
        let episodes = (0..<20).map {
            MediaItem(id: "episode-peek-\($0)", title: "Episode", kind: .episode,
                      posterURL: url, backdropURL: url, allowsTitleBasedMetadataMatching: false)
        }
        let related = items.enumerated().map { index, item in
            RelatedEntry(
                related: RelatedTitle(title: item.title, kind: .movie,
                                      providerIDs: ["tmdb": "\(index + 1)"], source: .tmdb),
                libraryItem: item
            )
        }
        let coordinator = FeaturedTrailerCoordinator()
        let controller = HeroTrailerController()
        let scenarios: [(CGFloat, CardStyle)] = [
            (1039, .borderless), (1039, .framed),
            (1297, .borderless), (1297, .framed),
            (1930, .borderless), (1930, .framed),
            (1960, .borderless), (1960, .framed)
        ]
        for (width, cardStyle) in scenarios {
            var headingHeight: CGFloat?
            for kind in 0..<5 {
                let row: AnyView
                if kind == 4 {
                    row = AnyView(PlozziOSRelatedSection(
                        entries: related, inset: DesktopMediaRailLayout.pageInset, onSelect: { _, _ in }
                    ))
                } else if kind == 3 {
                    row = AnyView(PlozziOSMediaSection(title: Text(verbatim: "Collection")) {
                        PlozziOSInlineEpisodeRail(episodes: episodes, isLoading: false, onPlay: { _, _ in })
                    })
                } else if kind == 2 {
                    row = AnyView(FeaturedMediaRow(
                        title: Text(verbatim: "Collection"), items: items, scope: ObjectIdentifier(controller),
                        coordinator: coordinator, controller: controller, settings: .default,
                        resolver: { _ in nil }, isActive: false, onSelect: { _ in }
                    ).browsingRow({}))
                } else {
                    row = AnyView(PlozziOSHomeMediaRail(
                        title: Text(verbatim: "Collection"), items: items,
                        style: kind == 0 ? .poster : .landscape, appModel: fixture.app, onBrowse: {}
                    ))
                }
                fixture.mount(
                    ScrollView { VStack(alignment: .leading) { row }.plozzDesktopMediaRailLayout() }
                        .environment(\.plozzMetrics, .desktop(density: .standard))
                        .environment(\.plozzCardStyle, cardStyle)
                        .environment(\.plozzArtworkSettings, ArtworkSettings(preference: .library))
                        .environment(\.plozziOSIsRunningOnMac, true)
                        .environment(\.plozziOSHomeViewportWidth, width),
                    width: width
                )
                try await fixture.settle()
                var image = renderedImage(fixture.window)
                var runs = try blueArtworkRuns(in: image, y: 100)
                let deadline = ContinuousClock.now + .seconds(3)
                while runs.isEmpty, ContinuousClock.now < deadline {
                    try await fixture.settle()
                    image = renderedImage(fixture.window)
                    runs = try blueArtworkRuns(in: image, y: 100)
                }
                let attachment = XCTAttachment(image: image)
                attachment.name = "mac-reference-peek-\(Int(width))-\(cardStyle)-row-\(kind)"
                attachment.lifetime = .keepAlways
                add(attachment)
                let first = try XCTUnwrap(runs.first)
                let last = try XCTUnwrap(runs.last)
                XCTAssertEqual(first.lowerBound, DesktopMediaRailLayout.pageInset, accuracy: 1.5)
                XCTAssertEqual(last.upperBound, width, accuracy: 1)
                let metrics = PlozzMetrics.desktop(density: .standard)
                    .fittingDesktopRail(in: width, cardStyle: cardStyle)
                let frameInset = cardStyle == .framed && kind != 2 ? metrics.cardInset : 0
                XCTAssertEqual(last.upperBound - last.lowerBound, 26 - frameInset, accuracy: 1.5,
                               "Rendered row \(kind) at width \(width) must show the next card.")
                let expectedWidth = kind == 0 || kind == 4 ? metrics.posterWidth
                    : kind == 2 ? DesktopMediaRailLayout.featuredSize(in: width, metrics: metrics).width
                    : metrics.landscapeWidth
                XCTAssertEqual(first.upperBound - first.lowerBound, expectedWidth, accuracy: 1.5)
                for run in runs.dropLast() {
                    XCTAssertEqual(run.upperBound - run.lowerBound, expectedWidth, accuracy: 1.5)
                }
                if width == 1960, kind == 0 || kind == 4 {
                    XCTAssertEqual(runs.count, 9, "Home and Related must show eight full posters and one preview.")
                }
                let title = kind == 4 ? "Related" : "Collection"
                let ink = try HeroTextInk.frames(in: image, terms: [title])
                let heading = try XCTUnwrap(ink[title])
                if let headingHeight { XCTAssertEqual(heading.height, headingHeight, accuracy: 1) }
                else { headingHeight = heading.height }
            }
        }
    }

    private func renderedImage(_ window: UIWindow) -> UIImage {
        UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
    }

    private func blueArtworkRuns(in image: UIImage, y: CGFloat) throws -> [Range<CGFloat>] {
        let cgImage = try XCTUnwrap(image.cgImage)
        let line = try XCTUnwrap(cgImage.cropping(to: CGRect(
            x: 0, y: y * image.scale, width: CGFloat(cgImage.width), height: 1
        )))
        var pixels = [UInt8](repeating: 0, count: line.width * 4)
        try pixels.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(
                data: bytes.baseAddress, width: line.width, height: 1, bitsPerComponent: 8,
                bytesPerRow: line.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(line, in: CGRect(x: 0, y: 0, width: line.width, height: 1))
        }
        var runs: [Range<CGFloat>] = []
        var start: Int?
        for x in 0...line.width {
            let blue = x < line.width && Int(pixels[x * 4 + 2]) > Int(pixels[x * 4]) + 60
                && pixels[x * 4 + 2] > 100
            if blue, start == nil { start = x }
            if !blue, let beginning = start {
                if x - beginning > 4 {
                    runs.append((CGFloat(beginning) / image.scale)..<(CGFloat(x) / image.scale))
                }
                start = nil
            }
        }
        return runs
    }

    func testMacLoadingAndLoadedCardsKeepMatchingGeometryAcrossWindowSizes() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let items = fixture.items.map {
            MediaItem(id: $0.id, title: $0.title, kind: .movie, productionYear: 2024,
                      allowsTitleBasedMetadataMatching: false)
        }
        for width: CGFloat in [760, 1440] {
            for cardStyle in [CardStyle.borderless, .framed] {
                for (style, seriesArtwork) in [(PosterCardView.Style.poster, false), (.landscape, false), (.landscape, true)] {
                    let heights = Heights()
                    fixture.mount(
                        ScrollView {
                            VStack(spacing: 40) {
                                PlozziOSHomeSkeletonRail(
                                    title: Text("Recently Added"), style: style,
                                    showsCaption: true, showsSeriesArtwork: seriesArtwork
                                )
                                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { heights.loading = $0 }
                                PlozziOSHomeMediaRail(
                                    title: Text("Recently Added"), items: items,
                                    style: style, appModel: fixture.app, showsSeriesArtwork: seriesArtwork,
                                    onBrowse: {}
                                )
                                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { heights.loaded = $0 }
                            }
                        }
                        .environment(\.plozzMetrics, .desktop(density: .standard))
                        .environment(\.plozziOSIsRunningOnMac, true)
                        .environment(\.plozziOSHomeViewportWidth, width)
                        .environment(\.plozzCardStyle, cardStyle),
                        width: width
                    )
                    try await fixture.settle()
                    XCTAssertGreaterThan(heights.loaded, 0)
                    XCTAssertEqual(heights.loading, heights.loaded, accuracy: 1,
                                   "\(width), \(cardStyle), \(style), series=\(seriesArtwork)")
                    let image = UIGraphicsImageRenderer(bounds: fixture.window.bounds).image { _ in
                        fixture.window.drawHierarchy(in: fixture.window.bounds, afterScreenUpdates: true)
                    }
                    let attachment = XCTAttachment(image: image)
                    attachment.name = "mac-cards-\(Int(width))-\(cardStyle)-\(style)-series-\(seriesArtwork)"
                    attachment.lifetime = .keepAlways
                    add(attachment)
                }
            }
        }
    }

    func testMacHeroActionsKeepMinimumTargetsWithAndWithoutGlass() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        for isMac in [false, true] {
            for reduced in [false, true] {
                for size in [DynamicTypeSize.large, .accessibility3] {
                    let heights = Heights()
                    fixture.mount(
                        VStack {
                            Button("Play") {}
                                .buttonStyle(PlozziOSHeroActionButtonStyle(kind: .primary))
                                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { heights.loading = $0 }
                            Button("Info", systemImage: "info") {}
                                .labelStyle(.iconOnly)
                                .buttonStyle(PlozziOSHeroActionButtonStyle(kind: .secondary, circular: true))
                                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { heights.loaded = $0 }
                        }
                        .environment(\.plozziOSIsRunningOnMac, isMac)
                        .environment(\.plozzReducePanelGlass, reduced)
                        .environment(\.dynamicTypeSize, size),
                        width: 760
                    )
                    try await fixture.settle()
                    XCTAssertGreaterThanOrEqual(heights.loading, 48)
                    XCTAssertEqual(heights.loaded, 48, accuracy: 0.1)
                    if size.isAccessibilitySize {
                        XCTAssertGreaterThan(heights.loading, 48)
                    }
                }
            }
        }
    }

    func testBrowseActionDoesNotChangeTheHeightOfALoadingRow() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        for width in [CGFloat(390), 768] {
            for size in [DynamicTypeSize.large, .accessibility3] {
                let heights = Heights()
                fixture.mount(
                    ScrollView {
                        VStack(spacing: 0) {
                            PlozziOSHomeSkeletonRail(title: Text("Recently Added"), style: .poster)
                                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { heights.loading = $0 }
                            PlozziOSHomeMediaRail(
                                title: Text("Recently Added"), items: fixture.items,
                                style: .poster, appModel: fixture.app, onBrowse: {}
                            )
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { heights.loaded = $0 }
                        }
                    }
                    .environment(\.dynamicTypeSize, size),
                    width: width
                )
                try await fixture.settle()
                XCTAssertGreaterThan(heights.loading, 0)
                XCTAssertEqual(heights.loading, heights.loaded, accuracy: 1, "\(width), \(size)")
            }
        }
    }

    func testRemovingAnEmptyRowDoesNotIssueAScrollCorrection() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let state = Rows()
        fixture.mount(LoadingRows(app: fixture.app, items: fixture.items, state: state))
        try await fixture.settle()
        let scroll = try XCTUnwrap(fixture.scrollViews().first { $0.contentSize.height > $0.bounds.height })
        let marker = try XCTUnwrap(fixture.find("row-3"))
        let contentY = marker.convert(.zero, to: scroll).y
        scroll.setContentOffset(CGPoint(x: 0, y: contentY - 100), animated: false)
        try await fixture.settle()
        let before = marker.convert(.zero, to: fixture.window).y
        XCTAssertEqual(before, 100, accuracy: 1)
        let oldHeight = scroll.contentSize.height
        let oldOffset = scroll.contentOffset.y
        state.rows.removeFirst()
        try await fixture.settle()
        XCTAssertLessThan(scroll.contentSize.height, oldHeight, "An empty row must not leave a permanent gap.")
        XCTAssertEqual(scroll.contentOffset.y, oldOffset, accuracy: 1,
                       "A confirmed-empty row may disappear, but Home must not steer the native scroll view.")
        XCTAssertEqual(try XCTUnwrap(fixture.find("row-3")).convert(.zero, to: fixture.window).y,
                       before - (oldHeight - scroll.contentSize.height), accuracy: 1)
    }

    func testReplacingSkeletonsWhileScrolledKeepsPageHeightAndPosition() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let state = Rows()
        fixture.mount(LoadingRows(app: fixture.app, items: fixture.items, state: state))
        try await fixture.settle()
        let scroll = try XCTUnwrap(fixture.scrollViews().first { $0.contentSize.height > $0.bounds.height })
        scroll.setContentOffset(CGPoint(x: 0, y: 450), animated: false)
        try await fixture.settle()
        let height = scroll.contentSize.height
        let offset = scroll.contentOffset.y
        state.loading = false
        try await fixture.settle()
        XCTAssertEqual(scroll.contentSize.height, height, accuracy: 1)
        XCTAssertEqual(scroll.contentOffset.y, offset, accuracy: 1)
    }

    func testReservedRowsDeferOffscreenContentWithoutChangingGeometry() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let state = Rows()
        state.rows = (0..<40).map { Rows.Row(number: $0) }
        fixture.mount(LoadingRows(app: fixture.app, items: fixture.items, state: state))
        try await fixture.settle()
        let scroll = try XCTUnwrap(fixture.scrollViews().first { $0.contentSize.height > $0.bounds.height })
        let height = scroll.contentSize.height
        XCTAssertGreaterThan(height, 8_000)
        XCTAssertNotNil(fixture.find("row-39"), "Every configured row reserves its footprint immediately.")
        XCTAssertNotNil(fixture.find("content-0"))
        XCTAssertNil(fixture.find("content-39"), "Offscreen rails must not mount merely to measure the page.")

        state.loading = false
        try await fixture.settle()
        XCTAssertEqual(scroll.contentSize.height, height, accuracy: 0.5)
        XCTAssertNil(fixture.find("content-39"), "Background results must not eagerly build offscreen cards.")
        for index in [39, 0, 20] {
            let slot = try XCTUnwrap(fixture.find("row-\(index)"))
            let bottom = scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom
            let target = min(bottom, max(0, slot.convert(.zero, to: scroll).y))
            scroll.setContentOffset(CGPoint(x: 0, y: target), animated: true)
            let deadline = ContinuousClock.now + .seconds(3)
            while abs(scroll.contentOffset.y - target) > 0.5, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            try await fixture.settle()
            XCTAssertEqual(scroll.contentOffset.y, target, accuracy: 0.5)
            XCTAssertEqual(scroll.contentSize.height, height, accuracy: 0.5)
            let content = try XCTUnwrap(fixture.find("content-\(index)"))
            XCTAssertGreaterThan(content.bounds.height, 100)
            XCTAssertTrue(content.convert(content.bounds, to: fixture.window).intersects(fixture.window.bounds))
        }
    }

    func testLibraryRowUpdatesIncludeContentFailuresAndHomeScope() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let model = HomeViewModel(accounts: [], profileNamespace: fixture.profileID)
        let replacement = HomeViewModel(accounts: [], profileNamespace: "replacement")
        defer { model.invalidate(); replacement.invalidate() }
        let coordinator = FeaturedTrailerCoordinator()
        let controller = HeroTrailerController()
        let choice = try XCTUnwrap(HomeRowChoice.shared.first)
        let section = LibrarySection(id: "shelf", title: "Shelf", items: fixture.items)
        let row = HomeLibrarySectionGroup.Row(section: section, isLoading: false, failure: nil)
        func view(
            _ row: HomeLibrarySectionGroup.Row, modelOverride: HomeViewModel? = nil, isActive: Bool = false,
            choiceOverride: HomeRowChoice? = nil
        ) -> PlozziOSHomeLibraryPresentationRow {
            PlozziOSHomeLibraryPresentationRow(
                choice: choiceOverride ?? choice, row: row,
                appModel: fixture.app, viewModel: modelOverride ?? model,
                coordinator: coordinator, controller: controller, isActive: isActive,
                rowBrowser: .constant(nil), showingHomeCustomization: .constant(false)
            )
        }
        XCTAssertEqual(view(row), view(row))
        XCTAssertEqual(view(row), view(.init(section: section, isLoading: true, failure: nil)))
        XCTAssertEqual(view(row), view(.init(section: section, isLoading: false, failure: .serverUnreachable)))
        let emptySection = LibrarySection(id: "shelf", title: "Shelf", items: [])
        let emptyRow = HomeLibrarySectionGroup.Row(section: emptySection, isLoading: false, failure: nil)
        XCTAssertNotEqual(view(emptyRow), view(.init(section: emptySection, isLoading: true, failure: nil)))
        XCTAssertNotEqual(
            view(emptyRow), view(.init(section: emptySection, isLoading: false, failure: .serverUnreachable))
        )
        var changedSection = section
        changedSection.items[0].title = "Updated movie"
        XCTAssertNotEqual(view(row), view(.init(section: changedSection, isLoading: false, failure: nil)))
        var browsable = row
        browsable.browseItem = MediaItem(id: "collection", title: "Collection", kind: .collection)
        XCTAssertNotEqual(view(row), view(browsable))
        XCTAssertNotEqual(view(row), view(row, modelOverride: replacement))
        XCTAssertNotEqual(view(row), view(row, isActive: true))
        let otherChoice = try XCTUnwrap(HomeRowChoice.shared.first { $0.id != choice.id })
        XCTAssertNotEqual(view(row), view(row, choiceOverride: otherChoice))
        var metadata = section
        metadata.items[metadata.items.count - 1].people = [
            MediaPerson(id: "person", name: "Person", role: "Actor", kind: "Actor", biography: "Original")
        ]
        let originalMetadata = HomeLibrarySectionGroup.Row(section: metadata, isLoading: false, failure: nil)
        metadata.items[metadata.items.count - 1].people[0].biography = "Updated biography"
        XCTAssertNotEqual(view(originalMetadata), view(.init(section: metadata, isLoading: false, failure: nil)))
    }

    func testPerformanceLibraryRowComparison() async throws {
        try PerformanceProbe.requireEnabled()
        let fixture = try Fixture()
        defer { fixture.close() }
        let model = HomeViewModel(accounts: [], profileNamespace: fixture.profileID)
        defer { model.invalidate() }
        let coordinator = FeaturedTrailerCoordinator()
        let controller = HeroTrailerController()
        let choice = try XCTUnwrap(HomeRowChoice.shared.first)
        let items = (0..<75).map { index in
            MediaItem(
                id: "movie-\(index)", title: "Movie \(index)", kind: .movie,
                people: (0..<32).map {
                    MediaPerson(id: "person-\($0)", name: "Person \($0)", role: "Actor", kind: "Actor",
                                biography: String(repeating: "Biography \($0). ", count: 16))
                }
            )
        }
        let encoded = try JSONEncoder().encode(items)
        func view(_ items: [MediaItem]) -> PlozziOSHomeLibraryPresentationRow {
            PlozziOSHomeLibraryPresentationRow(
                choice: choice,
                row: .init(section: .init(id: "row", title: "Row", items: items), isLoading: false, failure: nil),
                appModel: fixture.app, viewModel: model, coordinator: coordinator, controller: controller,
                isActive: false, rowBrowser: .constant(nil), showingHomeCustomization: .constant(false)
            )
        }
        let left = view(try JSONDecoder().decode([MediaItem].self, from: encoded))
        let right = view(try JSONDecoder().decode([MediaItem].self, from: encoded))
        try await PerformanceProbe.measure(self, scenario: "mobile-home-library-row-comparison") {
            var comparisons = 0
            for _ in 0..<256 {
                XCTAssertEqual(left, right)
                comparisons += 1
            }
            return ["comparisons": comparisons, "items": items.count,
                    "metadataPeople": items.reduce(0) { $0 + $1.people.count }]
        }
        var changed = items
        changed[74].people[31].biography = "Updated last biography"
        XCTAssertNotEqual(left, view(changed))
    }

    func testUnchangedLibraryRowsStillRespondToCaptionSettings() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let model = HomeViewModel(accounts: [], profileNamespace: fixture.profileID)
        defer { model.invalidate() }
        let choice = try XCTUnwrap(HomeRowChoice.shared.first)
        for loading in [true, false] {
            let heights = Heights()
            let row = HomeLibrarySectionGroup.Row(
                section: LibrarySection(id: "shelf", title: "Shelf", items: loading ? [] : fixture.items),
                isLoading: loading, failure: nil
            )
            fixture.mount(
                ScrollView {
                    PlozziOSHomeLibraryPresentationRow(
                        choice: choice, row: row,
                        appModel: fixture.app, viewModel: model,
                        coordinator: FeaturedTrailerCoordinator(), controller: HeroTrailerController(),
                        isActive: false, rowBrowser: .constant(nil), showingHomeCustomization: .constant(false)
                    )
                    .equatable()
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { heights.loaded = $0 }
                }
            )
            try await fixture.settle()
            let withCaptions = heights.loaded
            fixture.app.settings.cardStyle.captions = CardCaptionSettings(showsLabels: false)
            try await fixture.settle()
            XCTAssertLessThan(heights.loaded, withCaptions - 10, "loading=\(loading)")
            fixture.app.settings.cardStyle.captions = CardCaptionSettings(showsLabels: true)
            try await fixture.settle()
            XCTAssertEqual(heights.loaded, withCaptions, accuracy: 1)
        }
    }

    func testRowChangesLeaveNativeScrollOffsetAloneWithAContentInset() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let state = Rows()
        fixture.mount(LoadingRows(app: fixture.app, items: fixture.items, state: state)
            .safeAreaInset(edge: .top) { Color.clear.frame(height: 80) })
        try await fixture.settle()
        let scroll = try XCTUnwrap(fixture.scrollViews().first { $0.contentSize.height > $0.bounds.height })
        let marker = try XCTUnwrap(fixture.find("row-3"))
        scroll.setContentOffset(CGPoint(x: 0, y: marker.convert(.zero, to: scroll).y - 100), animated: false)
        try await fixture.settle()
        let before = scroll.contentOffset.y
        state.rows.removeFirst()
        try await fixture.settle()
        XCTAssertEqual(scroll.contentOffset.y, before, accuracy: 1)
        state.rows.insert(.init(number: 99), at: 0)
        try await fixture.settle()
        XCTAssertEqual(scroll.contentOffset.y, before, accuracy: 1)
    }

    func testRowSlotsKeepExactHeightThroughContentFailureAndRetry() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let model = HomeViewModel(accounts: [], profileNamespace: fixture.profileID)
        defer { model.invalidate() }
        let choice = HomeRowChoice(
            id: .library(key: "fixture", section: "recentlyAdded"), title: "Recently Added",
            isProviderDefault: true
        )
        for width in [CGFloat(390), 768] {
            for cardStyle in [CardStyle.borderless, .framed] {
                for style in [LibrarySection.Style.poster, .landscape] {
                    for captions in [true, false] {
                        for textSize in [DynamicTypeSize.large, .accessibility3] {
                            fixture.app.settings.cardStyle.captions = CardCaptionSettings(showsLabels: captions)
                            let section = LibrarySection(
                                id: "recentlyAdded", title: "Recently Added Recommendations",
                                style: style, items: []
                            )
                            let state = RowState(row: .init(section: section, isLoading: true, failure: nil))
                            let heights = Heights()
                            fixture.mount(
                                ScrollView {
                                    ReservedLibraryRow(
                                        choice: choice, state: state, app: fixture.app, model: model,
                                        coordinator: FeaturedTrailerCoordinator(), controller: HeroTrailerController(),
                                        onContentHeight: { heights.loading = $0 }
                                    )
                                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { heights.loaded = $0 }
                                }
                                .environment(\.plozziOSHomeViewportWidth, width)
                                .environment(\.plozzCardStyle, cardStyle)
                                .environment(\.dynamicTypeSize, textSize),
                                width: width
                            )
                            try await fixture.settle()
                            let reserved = heights.loaded
                            XCTAssertGreaterThan(reserved, 100)
                            XCTAssertEqual(heights.loading, reserved, accuracy: 0.5,
                                           "Reserve the actual placeholder height, not an estimate.")
                            var loaded = section
                            loaded.items = fixture.items
                            for row in [
                                HomeLibrarySectionGroup.Row(section: loaded, isLoading: false, failure: nil),
                                .init(section: section, isLoading: false, failure: .serverUnreachable),
                                .init(section: section, isLoading: false, failure: nil,
                                      issue: .init(choice: choice, reason: .failed(.serverUnreachable))),
                                .init(section: section, isLoading: true, failure: nil)
                            ] {
                                state.row = row
                                try await fixture.settle()
                                XCTAssertEqual(heights.loaded, reserved, accuracy: 0.5,
                                               "\(width), \(cardStyle), \(style), captions=\(captions), \(textSize)")
                                if row.failure == nil && row.issue == nil {
                                    let rendered = try XCTUnwrap(fixture.find("reserved-content"))
                                    XCTAssertEqual(rendered.bounds.height, reserved, accuracy: 0.5,
                                                   "\(width), \(cardStyle), \(style), captions=\(captions), \(textSize), loading=\(row.isLoading)")
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    func testStatusRowsRetainTheirConfiguredCardShape() throws {
        let definition = HomeServerRowDefinition(
            accountID: "server", serverName: "Server", providerKind: .jellyfin,
            section: .init(id: "next", kind: .nextUp)
        )
        let choice = HomeRowChoice(serverRow: definition)
        let visibility = HomeLibraryVisibility(
            rowCustomization: .init(defaults: .custom, shown: [definition.id], serverRows: [definition]),
            mergeNextUpIntoContinueWatching: false
        )
        var content = HomeViewModel.Content(serverRows: [
            .init(definition: definition, failure: .serverUnreachable)
        ])
        content.sectionIssues = [.init(choice: choice, reason: .failed(.serverUnreachable))]
        let rows = HomePresentationRow.resolve(rows: [], content: content, visibility: visibility)
        guard case let .library(row) = try XCTUnwrap(rows.first).source else {
            return XCTFail("Expected a visible failure.")
        }
        XCTAssertEqual(row.section.style, .landscape)
        XCTAssertNotNil(row.issue)
    }

    func testReservedContinueWatchingHeightMatchesBothLayoutsAndCaptionPreferences() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let model = HomeViewModel(accounts: [], profileNamespace: fixture.profileID)
        defer { model.invalidate() }
        let choice = try XCTUnwrap(HomeRowChoice.shared.first { $0.id == .global(.continueWatching) })
        for width in [CGFloat(390), 768] {
            for layout in ContinueWatchingCardLayout.allCases {
                fixture.app.settings.homeVisibility.setContinueWatchingLayout(layout)
                for captions in [true, false] {
                    fixture.app.settings.cardStyle.captions = CardCaptionSettings(showsLabels: captions)
                    var reserved: CGFloat?
                    for row in [
                        HomeRow(kind: .continueWatching, loadingPlaceholderCount: 8),
                        HomeRow(kind: .continueWatching, items: fixture.items),
                        HomeRow(kind: .continueWatching, failure: .serverUnreachable)
                    ] {
                        let heights = Heights()
                        let presentation = HomePresentationRow(choice: choice, source: .home(row))
                        fixture.mount(
                            ScrollView {
                                PlozziOSHomeRowSlot(
                                    presentation: presentation, captions: fixture.app.settings.cardStyle.captions,
                                    continueWatchingLayout: layout, continueWatchingUsesSeriesArtwork: true
                                ) {
                                    PlozziOSHomeRowView(
                                        row: row, appModel: fixture.app, viewModel: model,
                                        watchlistIntentRevision: 0, watchlistLoadingPlaceholderCount: 0, onBrowse: nil
                                    )
                                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { heights.loading = $0 }
                                }
                                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { heights.loaded = $0 }
                            }
                            .environment(\.plozziOSHomeViewportWidth, width),
                            width: width
                        )
                        try await fixture.settle()
                        if let reserved { XCTAssertEqual(heights.loaded, reserved, accuracy: 0.5) }
                        else { reserved = heights.loaded }
                        if row.failure == nil { XCTAssertEqual(heights.loading, heights.loaded, accuracy: 0.5) }
                    }
                }
            }
        }
    }

    func testFeaturedRowReservationSurvivesFailureAndMatchesLoadedContent() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let model = HomeViewModel(accounts: [], profileNamespace: fixture.profileID)
        defer { model.invalidate() }
        let definition = CollectionSection(
            source: .init(accountID: "fixture", collectionID: "collection", title: "Featured Collection"),
            cardStyle: .featured
        )
        let choice = HomeRowChoice(collectionSection: definition)
        for width in [CGFloat(390), 768] {
            let state = RowState(row: HomeCollectionRow(definition: definition, isLoading: true).row)
            let heights = Heights()
            fixture.mount(
                ScrollView {
                    ReservedLibraryRow(
                        choice: choice, state: state, app: fixture.app, model: model,
                        coordinator: FeaturedTrailerCoordinator(), controller: HeroTrailerController(),
                        onContentHeight: { heights.loading = $0 }
                    )
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { heights.loaded = $0 }
                }
                .environment(\.plozziOSHomeViewportWidth, width),
                width: width
            )
            try await fixture.settle()
            let reserved = heights.loaded
            XCTAssertEqual(heights.loading, reserved, accuracy: 0.5)
            state.row = HomeCollectionRow(definition: definition, items: fixture.items).row
            try await fixture.settle()
            XCTAssertEqual(heights.loading, reserved, accuracy: 0.5)
            XCTAssertEqual(heights.loaded, reserved, accuracy: 0.5)
            state.row = HomeCollectionRow(definition: definition, failure: .serverUnreachable).row
            try await fixture.settle()
            XCTAssertEqual(heights.loaded, reserved, accuracy: 0.5)
        }
    }

    func testLiveTVReservationDoesNotAddMediaCaptionSpace() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let channel = HomeLiveTVChannel(
            route: .init(profileID: fixture.profileID, channelID: "channel", sourceID: "source",
                         sourceAuthorizationID: "source-auth", serverAuthorizationID: "server-auth"),
            name: "Channel", sourceName: "Source", number: 1
        )
        let presentation = HomePresentationRow(
            choice: try XCTUnwrap(HomeRowChoice.shared.first { $0.id == .liveTV }), source: .liveTV([channel])
        )
        for style in [CardStyle.borderless, .framed] {
            let heights = Heights()
            fixture.mount(
                ScrollView {
                    PlozziOSHomeRowSlot(
                        presentation: presentation, captions: .default,
                        continueWatchingLayout: .landscape, continueWatchingUsesSeriesArtwork: false
                    ) {
                        PlozziOSHomeMediaRail(
                            title: Text("Live TV"), items: [], style: .landscape,
                            appModel: fixture.app, liveChannels: [channel]
                        )
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { heights.loading = $0 }
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { heights.loaded = $0 }
                }
                .environment(\.plozziOSHomeViewportWidth, 390)
                .environment(\.plozzCardStyle, style)
            )
            try await fixture.settle()
            XCTAssertGreaterThan(heights.loaded, 100)
            XCTAssertEqual(heights.loaded, heights.loading, accuracy: 0.5)
        }
    }

    func testContentAndFailuresKeepPageGeometryDuringNativeAnimatedScrolling() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let model = HomeViewModel(accounts: [], profileNamespace: fixture.profileID)
        defer { model.invalidate() }
        let section = LibrarySection(id: "shelf", title: "Shelf", items: [])
        let state = RowState(row: .init(section: section, isLoading: true, failure: nil))
        let coordinator = FeaturedTrailerCoordinator()
        let controller = HeroTrailerController()
        fixture.mount(PlozziOSHomeScrollView(heroActive: false) {
            EmptyView()
        } rows: {
            ForEach(0..<8, id: \.self) { index in
                ReservedLibraryRow(
                    choice: .init(id: .library(key: "\(index)", section: "shelf"), title: "Shelf", isProviderDefault: true),
                    state: state, app: fixture.app, model: model, coordinator: coordinator, controller: controller
                )
            }
        })
        try await fixture.settle()
        let scroll = try XCTUnwrap(fixture.scrollViews().first { $0.contentSize.height > $0.bounds.height })
        let height = scroll.contentSize.height
        let target = (height - scroll.bounds.height) * 0.75
        let changes = Task { @MainActor in
            for failure in [AppError?.none, .serverUnreachable, .none] {
                try await Task.sleep(for: .milliseconds(50))
                var next = section
                next.items = failure == nil ? fixture.items : []
                state.row = .init(section: next, isLoading: false, failure: failure)
            }
        }
        defer { changes.cancel() }
        scroll.setContentOffset(CGPoint(x: 0, y: target), animated: true)
        var previous: CGFloat = 0
        let deadline = ContinuousClock.now + .seconds(3)
        repeat {
            try await Task.sleep(for: .milliseconds(10))
            XCTAssertEqual(scroll.contentSize.height, height, accuracy: 0.5)
            XCTAssertGreaterThanOrEqual(scroll.contentOffset.y, previous - 0.5)
            previous = scroll.contentOffset.y
        } while abs(scroll.contentOffset.y - target) > 0.5 && ContinuousClock.now < deadline
        try await changes.value
        XCTAssertEqual(scroll.contentOffset.y, target, accuracy: 0.5)
        XCTAssertEqual(scroll.contentSize.height, height, accuracy: 0.5)
    }

    func testFeaturedCollectionSkeletonMatchesTheFeaturedCardHeight() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let coordinator = FeaturedTrailerCoordinator()
        let controller = HeroTrailerController()
        for width in [CGFloat(390), 768] {
            let heights = Heights()
            fixture.mount(
                ScrollView {
                    VStack {
                        FeaturedMediaRow(
                            title: Text("Featured"), items: [], scope: ObjectIdentifier(controller),
                            coordinator: coordinator, controller: controller, settings: .default,
                            resolver: { _ in nil }, isActive: false, onSelect: { _ in }
                        )
                        .browsingRow(nil)
                        .loading(true)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { heights.loading = $0 }
                        FeaturedMediaRow(
                            title: Text("Featured"), items: fixture.items, scope: ObjectIdentifier(controller),
                            coordinator: coordinator, controller: controller, settings: .default,
                            resolver: { _ in nil }, isActive: false, onSelect: { _ in }
                        )
                        .browsingRow({})
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { heights.loaded = $0 }
                    }
                },
                width: width
            )
            try await fixture.settle()
            XCTAssertGreaterThan(heights.loaded, 0)
            XCTAssertEqual(heights.loading, heights.loaded, accuracy: 1)
        }
    }

    func testLibrarySkeletonUsesTheLibraryTilesGeometry() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let library = AggregatedLibrary(
            accountID: "fixture", accountName: "Fixture", serverName: "Server", providerKind: .jellyfin,
            library: MediaLibrary(id: "movies", title: "Movies", kind: .movie)
        )
        for style in [CardStyle.borderless, .framed] {
            for captions in [true, false] {
                let heights = Heights()
                fixture.mount(
                    ScrollView {
                        VStack {
                            PlozziOSHomeSkeletonRail(
                                title: Text("Libraries"), style: .landscape, showsCaption: captions, isLibraryRow: true
                            )
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { heights.loading = $0 }
                            PlozziOSMediaSection(title: Text("Libraries")) {
                                ScrollView(.horizontal) {
                                    HStack(spacing: PlozziOSMediaRailLayout.visibleSpacing) {
                                        ForEach(0..<8, id: \.self) { _ in
                                            PlozziOSHomeLibraryCard(library: library, artworkSource: nil, width: 220)
                                        }
                                    }
                                }
                                .contentMargins(.horizontal, 22, for: .scrollContent)
                                .plozziOSMediaRailClearance()
                            }
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { heights.loaded = $0 }
                        }
                    }
                    .environment(\.plozzCardStyle, style)
                    .environment(\.plozzCardCaptionSettings, CardCaptionSettings(showsLabels: captions))
                )
                try await fixture.settle()
                XCTAssertGreaterThan(heights.loaded, 0)
                XCTAssertEqual(heights.loading, heights.loaded, accuracy: 1, "\(style), captions=\(captions)")
            }
        }
    }

    func testLoadingRailsAnimateWhenScrolledIntoView() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let state = Rows()
        fixture.mount(LoadingRows(app: fixture.app, items: fixture.items, state: state))
        try await fixture.settle()
        let scroll = try XCTUnwrap(fixture.scrollViews().first { $0.contentSize.height > $0.bounds.height })
        let height = scroll.contentSize.height
        func snapshot() throws -> Data {
            let image = UIGraphicsImageRenderer(bounds: fixture.window.bounds).image { _ in
                XCTAssertTrue(fixture.window.drawHierarchy(in: fixture.window.bounds, afterScreenUpdates: true))
            }
            return try XCTUnwrap(image.pngData())
        }
        for offset in [CGFloat.zero, height - scroll.bounds.height, CGFloat.zero] {
            scroll.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
            try await fixture.settle()
            let first = try snapshot()
            var changed = false
            for _ in 0..<8 {
                try await Task.sleep(for: .milliseconds(300))
                let next = try snapshot()
                changed = changed || first != next
            }
            XCTAssertTrue(changed, "Rows entering or reentering the viewport must shimmer.")
            XCTAssertEqual(scroll.contentSize.height, height, accuracy: 1)
            XCTAssertEqual(scroll.contentOffset.y, offset, accuracy: 1)
        }
    }

    func testPerformanceLoadingWhileScrolling() async throws {
        try PerformanceProbe.requireEnabled()
        let fixture = try Fixture()
        defer { fixture.close() }
        let state = Rows()
        fixture.mount(LoadingRows(app: fixture.app, items: fixture.items, state: state))
        try await fixture.settle()
        let scroll = try XCTUnwrap(fixture.scrollViews().first { $0.contentSize.height > $0.bounds.height })
        try await PerformanceProbe.measure(self, scenario: "mobile-home-loading-scroll") {
            state.loading = true
            state.loaded = []
            scroll.setContentOffset(.zero, animated: false)
            try await fixture.settle()
            let height = scroll.contentSize.height
            let destination = (height - scroll.bounds.height) * 0.75
            var greatestHeightChange: CGFloat = 0
            for index in 0..<8 {
                scroll.setContentOffset(CGPoint(x: 0, y: destination * CGFloat(index + 1) / 8), animated: true)
                try await Task.sleep(for: .milliseconds(40))
                state.loaded.insert(index)
                try await Task.sleep(for: .milliseconds(40))
                greatestHeightChange = max(greatestHeightChange, abs(scroll.contentSize.height - height))
            }
            let deadline = ContinuousClock.now + .seconds(3)
            while abs(scroll.contentOffset.y - destination) > 1, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertEqual(state.loaded.count, 8)
            XCTAssertEqual(scroll.contentOffset.y, destination, accuracy: 1)
            XCTAssertLessThanOrEqual(greatestHeightChange, 1)
            return ["loadedRows": 8, "scrollTargets": 8, "itemsPerRow": fixture.items.count,
                    "maximumPageHeightChangePoints": Int(greatestHeightChange.rounded())]
        }
    }

    @MainActor private final class Heights {
        var loading: CGFloat = 0
        var loaded: CGFloat = 0
    }

    @MainActor @Observable final class RowState {
        var row: HomeLibrarySectionGroup.Row
        init(row: HomeLibrarySectionGroup.Row) { self.row = row }
    }

    private struct ReservedLibraryRow: View {
        let choice: HomeRowChoice
        let state: RowState
        let app: PlozziOSAppModel
        let model: HomeViewModel
        let coordinator: FeaturedTrailerCoordinator
        let controller: HeroTrailerController
        var onContentHeight: (CGFloat) -> Void = { _ in }

        var body: some View {
            let presentation = HomePresentationRow(choice: choice, source: .library(state.row))
            PlozziOSHomeRowSlot(
                presentation: presentation, captions: app.settings.cardStyle.captions,
                continueWatchingLayout: app.settings.homeVisibility.continueWatchingLayout,
                continueWatchingUsesSeriesArtwork: app.settings.homeVisibility.continueWatchingUsesSeriesArtwork
            ) {
                PlozziOSHomeLibraryPresentationRow(
                    choice: presentation.choice, row: state.row, appModel: app, viewModel: model,
                    coordinator: coordinator, controller: controller, isActive: false,
                    rowBrowser: .constant(nil), showingHomeCustomization: .constant(false)
                )
                .equatable()
                .background(RowMarker(name: "reserved-content"))
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onContentHeight($0) }
            }
        }
    }

    @MainActor @Observable final class Rows {
        struct Row: Identifiable {
            let number: Int
            var id: HomeRowID { .library(key: "fixture-\(number)", section: "recentlyAdded") }
        }
        var rows = (0..<8).map { Row(number: $0) }
        var loading = true
        var loaded: Set<Int> = []
    }

    private struct LoadingRows: View {
        let app: PlozziOSAppModel
        let items: [MediaItem]
        let state: Rows

        var body: some View {
            PlozziOSHomeScrollView(heroActive: false) {
                EmptyView()
            } rows: {
                ForEach(state.rows) { row in
                    let presentation = HomePresentationRow(
                        choice: .init(id: row.id, title: "Row \(row.number)", isProviderDefault: true),
                        source: .library(.init(
                            section: LibrarySection(id: "recentlyAdded", title: "Row \(row.number)", items: items),
                            isLoading: state.loading && !state.loaded.contains(row.number), failure: nil
                        ))
                    )
                    PlozziOSHomeRowSlot(
                        presentation: presentation, captions: app.settings.cardStyle.captions,
                        continueWatchingLayout: .landscape, continueWatchingUsesSeriesArtwork: false
                    ) {
                        Group {
                            if state.loading && !state.loaded.contains(row.number) {
                                PlozziOSHomeSkeletonRail(title: Text(verbatim: "Row \(row.number)"), style: .poster)
                            } else {
                                PlozziOSHomeMediaRail(
                                    title: Text(verbatim: "Row \(row.number)"), items: items,
                                    style: .poster, appModel: app, onBrowse: {}
                                )
                            }
                        }
                        .background(RowMarker(name: "content-\(row.number)"))
                    }
                    .background(RowMarker(name: "row-\(row.number)"))
                }
            }
        }
    }

    private struct RowMarker: UIViewRepresentable {
        let name: String
        func makeUIView(context: Context) -> UIView {
            let view = UIView()
            view.accessibilityIdentifier = name
            view.isUserInteractionEnabled = false
            return view
        }
        func updateUIView(_ uiView: UIView, context: Context) {}
    }

    @MainActor private final class Fixture {
        let app: PlozziOSAppModel
        let items: [MediaItem]
        let window: UIWindow
        let previous: UIWindow?
        let suite = "HomeLoadingLayout.\(UUID())"
        let defaults: UserDefaults
        let profileID: String

        init() throws {
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            app = PlozziOSAppModel(
                accountStore: AccountStore(secureStore: InMemorySecureStore()),
                profileStore: ProfileStore(defaults: defaults)
            )
            profileID = app.profiles.add(name: "Fixture", isAwaitingSetup: false).id
            app.selectProfile(profileID)
            app.settings.cardStyle.artwork = ArtworkSettings(preference: .library)
            app.settings.cardStyle.captions = CardCaptionSettings(showsLabels: true)
            items = (0..<20).map {
                MediaItem(id: "loading-\($0)", title: "Movie", kind: .movie,
                          allowsTitleBasedMetadataMatching: false)
            }
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .first { $0.activationState == .foregroundActive })
            previous = scene.windows.first(where: \.isKeyWindow)
            window = UIWindow(windowScene: scene)
            window.overrideUserInterfaceStyle = .dark
        }

        func mount(_ view: some View, width: CGFloat = 390) {
            window.frame = CGRect(x: 0, y: 0, width: width, height: 844)
            let host = UIHostingController(rootView: view
                .environment(app)
                .environment(\.horizontalSizeClass, width < 600 ? .compact : .regular)
                .environment(\.plozzCardStyle, .borderless)
                .environment(\.plozzMetrics, .touch(density: .standard))
                .environment(\.themePalette, .dark))
            host.safeAreaRegions = []
            window.rootViewController = host
            window.makeKeyAndVisible()
        }

        func settle() async throws {
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(250))
            window.layoutIfNeeded()
        }

        func scrollViews() -> [UIScrollView] {
            func walk(_ view: UIView) -> [UIScrollView] {
                ((view as? UIScrollView).map { [$0] } ?? []) + view.subviews.flatMap(walk)
            }
            return walk(window)
        }

        func find(_ name: String) -> UIView? {
            func walk(_ view: UIView) -> UIView? {
                if view.accessibilityIdentifier == name { return view }
                return view.subviews.lazy.compactMap(walk).first
            }
            return walk(window)
        }

        func close() {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
            defaults.removePersistentDomain(forName: suite)
            for key in UserDefaults.standard.dictionaryRepresentation().keys
            where key.components(separatedBy: ".").contains(profileID) {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }
}
#endif
