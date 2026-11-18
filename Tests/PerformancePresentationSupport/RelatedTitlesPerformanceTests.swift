import AppRuntime
import CoreModels
import CoreSecureStore
import CoreUI
import FeatureAuthCore
import FeatureHomeCore
import MetadataKit
import SwiftUI
import UIKit
import XCTest
#if os(iOS)
@testable import AppShelliOS
#else
@testable import FeatureHome
#endif

@MainActor
final class RelatedTitlesPerformanceTests: XCTestCase {
    func testPerformanceCachedRecommendationsWhileScrolling() async throws {
        try await measure(cached: true)
    }

    func testPerformanceColdRecommendationsWhileScrolling() async throws {
        try await measure(cached: false)
    }

    func testPerformanceMixedServersWhileScrolling() async throws {
        try await measure(cached: true, mixed: true)
    }

    func testPerformanceDetailOpeningWhileScrolling() async throws {
        try await measure(cached: false, detailOpening: true)
    }

    private func measure(cached: Bool, mixed: Bool = false, detailOpening: Bool = false) async throws {
        try PerformanceProbe.requireEnabled()
        let fixture = try Fixture()
        defer { fixture.close() }
        let scenario = mixed ? "related-mixed-servers-scroll" : detailOpening ? "related-detail-open-scroll"
            : cached ? "related-cached-scroll" : "related-cold-scroll"
        try await PerformanceProbe.measure(
            self, scenario: scenario
        ) {
            try await fixture.exercise(cached: cached, mixed: mixed, detailOpening: detailOpening)
        }
    }

    @MainActor private final class Probe {
        var start = ContinuousClock.now
        var firstMicroseconds = 0
        var fullMicroseconds = 0
        var publications = 0
        var renderedCount = 0

        func published(_ entries: [RelatedEntry]) {
            guard !entries.isEmpty else { return }
            publications += 1
            renderedCount = entries.count
            let elapsed = Self.microseconds(start.duration(to: .now))
            if firstMicroseconds == 0 { firstMicroseconds = elapsed }
            if entries.count == 12 { fullMicroseconds = elapsed }
        }

        static func microseconds(_ duration: Duration) -> Int {
            let parts = duration.components
            return Int(parts.seconds * 1_000_000 + parts.attoseconds / 1_000_000_000_000)
        }
    }

    private struct Rows: View {
        let loader: RelatedTitlesLoader
        let probe: Probe
        #if os(iOS)
        let app: PlozziOSAppModel
        #endif

        var body: some View {
            VStack(alignment: .leading, spacing: 40) {
                Text(verbatim: "Detail performance fixture").font(.largeTitle)
                    .frame(height: 180)
                related
                    .frame(height: 480, alignment: .top)
                ForEach(0..<6) { index in
                    Text(verbatim: "Detail section \(index)")
                        .frame(maxWidth: .infinity, minHeight: 220, alignment: .leading)
                }
            }
            .environment(\.plozzCardStyle, .borderless)
            .environment(\.plozzCardCaptionSettings, CardCaptionSettings(showsLabels: true))
            .environment(\.plozzReducePanelGlass, true)
            .environment(\.plozzReduceTransparency, true)
            .environment(\.locale, Locale(identifier: "en_US"))
            .onChange(of: loader.entries) { _, entries in probe.published(entries) }
        }

        @ViewBuilder private var related: some View {
            #if os(iOS)
            PlozziOSRelatedSection(entries: loader.entries, inset: 24, onSelect: { _, _ in })
                .environment(app)
                .environment(\.plozzMetrics, .touch(density: .standard))
            #else
            RelatedRowView(entries: loader.entries, hasResolved: loader.hasResolved, onSelect: { _ in })
            #endif
        }
    }

    @MainActor private final class Fixture {
        let window: UIWindow
        let previous: UIWindow?
        let controller = UIViewController()
        let scroll = UIScrollView()
        let artworkFolder: URL
        let artwork: URL
        #if os(iOS)
        let app: PlozziOSAppModel
        let defaults: UserDefaults
        let suite: String
        #endif
        var host: UIHostingController<Rows>?

        init() throws {
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .first { $0.activationState == .foregroundActive })
            previous = scene.windows.first(where: \.isKeyWindow)
            window = UIWindow(windowScene: scene)
            window.frame = scene.coordinateSpace.bounds
            window.overrideUserInterfaceStyle = .dark
            artworkFolder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: artworkFolder, withIntermediateDirectories: true)
            artwork = artworkFolder.appendingPathComponent("poster.png")
            let image = UIGraphicsImageRenderer(size: CGSize(width: 200, height: 300)).image {
                UIColor.systemBlue.setFill()
                $0.fill(CGRect(x: 0, y: 0, width: 200, height: 300))
            }
            try XCTUnwrap(image.pngData()).write(to: artwork)
            #if os(iOS)
            suite = "RelatedPerformance.\(UUID().uuidString)"
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            app = PlozziOSAppModel(
                accountStore: AccountStore(secureStore: InMemorySecureStore()),
                profileStore: ProfileStore(defaults: defaults)
            )
            #endif
            window.rootViewController = controller
            scroll.frame = window.bounds
            scroll.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            controller.view.addSubview(scroll)
            window.makeKeyAndVisible()
            window.layoutIfNeeded()
        }

        func exercise(cached: Bool, mixed: Bool, detailOpening: Bool) async throws -> [String: Int] {
            let requests = Requests()
            let seed = MediaItem(id: "seed", title: "Seed", kind: .movie, providerIDs: ["Tmdb": "999"])
            let accountKinds: [(String, ProviderKind)] = mixed
                ? [("plex-a", .plex), ("plex-b", .plex), ("jellyfin", .jellyfin), ("emby", .emby),
                   ("silo", .silo), ("share", .mediaShare)]
                : [("plex-a", .plex), ("jellyfin", .jellyfin)]
            let titles = (0..<24).map {
                RelatedTitle(title: "Candidate \($0)", kind: .movie, providerIDs: ["Tmdb": "\($0 + 1)"],
                             posterURL: artwork, source: .tmdb)
            }
            let owned = (0..<12).map { index -> MediaItem in
                var item = MediaItem(
                    id: "owned-\(index / accountKinds.count)", title: "Server title \(index)", kind: .movie,
                    productionYear: 2020, posterURL: artwork,
                    providerIDs: ["Tmdb": "\(index + 1)"], sourceAccountID: accountKinds[index % accountKinds.count].0
                )
                item.catalogIdentityIsComplete = true
                item.allowsTitleBasedMetadataMatching = false
                return item
            }
            let providers: [any MediaProvider] = accountKinds.map { accountID, kind in
                let provider = LibraryProvider(
                    kind: kind, accountID: accountID, items: owned, seed: seed, requests: requests
                )
                if kind == .silo || kind == .mediaShare { return SingleItemProvider(base: provider) }
                return provider
            }
            let accounts = zip(accountKinds, providers).map { account, provider in
                ResolvedAccount(account: Account(id: account.0, from: provider.session), provider: provider)
            }
            let search = try XCTUnwrap(relatedTitleLibrarySearch(in: accounts))
            var identities: [MediaIdentity: [IndexedSource]] = [:]
            for (index, item) in owned.enumerated() {
                for identity in MediaItemIdentity.identities(for: item) {
                    identities[identity, default: []].append(.init(
                        accountID: try XCTUnwrap(item.sourceAccountID), itemID: item.id, kind: .movie,
                        normalizedTitle: MediaItemIdentity.normalizedTitle(titles[index].title)
                    ))
                }
            }
            let snapshot = IdentityIndexSnapshot(byIdentity: identities)
            let store = RelatedTitlesStore(directory: nil)
            if cached {
                await store.store(.init(seedKey: MetadataQuery(seed).seriesScoped.enrichmentCacheKey,
                                        titles: titles, refreshedAt: Date()))
            }
            let loader = RelatedTitlesLoader(
                resolver: .init(providers: [Recommendations(titles: titles, requests: requests)]),
                store: store, search: search,
                indexedLibrarySources: { snapshot.sourceRefs(for: $0) },
                loadIndexedItem: relatedTitleLibraryItemLoader(in: accounts),
                loadIndexedBatches: relatedTitleLibraryBatchLoaders(in: accounts)
            )
            let detail = detailOpening ? ItemDetailViewModel(
                provider: providers[0], itemID: seed.id, initialItem: seed,
                sourceAccountID: accountKinds[0].0, onlineTrailerResolver: { _ in [] },
                relatedTitlesLoader: loader
            ) : nil
            defer { detail?.suspendEnrichment() }
            let probe = Probe()
            #if os(iOS)
            let root = Rows(loader: loader, probe: probe, app: app)
            #else
            let root = Rows(loader: loader, probe: probe)
            #endif
            let host = UIHostingController(rootView: root)
            self.host = host
            controller.addChild(host)
            scroll.addSubview(host.view)
            host.view.frame = CGRect(x: 0, y: 0, width: scroll.bounds.width, height: 2400)
            scroll.contentSize = host.view.bounds.size
            host.didMove(toParent: controller)
            scroll.contentOffset = .zero
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            defer { unmount() }
            probe.start = .now
            let loading = Task {
                if let detail { await detail.load() }
                else { await loader.load(for: seed) }
            }
            defer { loading.cancel() }
            let cpuStart = try PerformanceProbe.usage().cpuMilliseconds
            var last = ContinuousClock.now
            var maximumGap = 0
            let distance = scroll.contentSize.height - scroll.bounds.height
            XCTAssertGreaterThan(distance, 0)
            for step in 0..<100 {
                let fraction = CGFloat(step % 50) / 49
                let y = distance * (step < 50 ? fraction : 1 - fraction)
                scroll.setContentOffset(CGPoint(x: 0, y: y), animated: false)
                scroll.layoutIfNeeded()
                XCTAssertEqual(scroll.contentOffset.y, y, accuracy: 1)
                try await Task.sleep(for: .milliseconds(16))
                let now = ContinuousClock.now
                maximumGap = max(maximumGap, Probe.microseconds(last.duration(to: now)))
                last = now
            }
            let scrollCPU = Int((try PerformanceProbe.usage().cpuMilliseconds - cpuStart) * 1_000)
            await loading.value
            let finished = Probe.microseconds(probe.start.duration(to: .now))
            let deadline = ContinuousClock.now + .seconds(2)
            while probe.renderedCount != 12, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(16))
            }
            XCTAssertTrue(loader.hasResolved)
            XCTAssertEqual(loader.entries.map(\.item.id), owned.map(\.id))
            XCTAssertEqual(loader.entries.map(\.item.sourceAccountID), owned.map(\.sourceAccountID))
            XCTAssertEqual(loader.entries.map(\.item.title), owned.map(\.title))
            XCTAssertEqual(loader.entries.map(\.item.posterURL), owned.map(\.posterURL))
            XCTAssertEqual(probe.renderedCount, 12)
            XCTAssertGreaterThan(probe.firstMicroseconds, 0)
            let counts = await requests.counts
            XCTAssertLessThanOrEqual(counts.peak, 6)
            return [
                "items": loader.entries.count, "searchRequests": counts.search,
                "detailRequests": counts.detail, "recommendationRequests": counts.recommendations,
                "batchRequests": counts.batch, "accountCount": accounts.count,
                "primaryDetailRequests": counts.primary, "maxNativeInFlight": counts.peak,
                "publications": probe.publications, "firstRowMicroseconds": probe.firstMicroseconds,
                "fullRowMicroseconds": probe.fullMicroseconds, "finishedMicroseconds": finished,
                "scrollTargets": 100, "maxMainActorGapMicroseconds": maximumGap,
                "scrollCPUTimeMicroseconds": scrollCPU
            ]
        }

        private func unmount() {
            host?.willMove(toParent: nil)
            host?.view.removeFromSuperview()
            host?.removeFromParent()
            host = nil
        }

        func close() {
            unmount()
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
            #if os(iOS)
            defaults.removePersistentDomain(forName: suite)
            #endif
            do { try FileManager.default.removeItem(at: artworkFolder) }
            catch { XCTFail("Could not remove owned Related artwork: \(error)") }
        }
    }

    private actor Requests {
        var counts = (search: 0, detail: 0, recommendations: 0, batch: 0, primary: 0, peak: 0)
        var active = 0
        func searched() { counts.search += 1 }
        func started(batch: Bool) {
            if batch { counts.batch += 1 } else { counts.detail += 1 }
            active += 1
            counts.peak = max(counts.peak, active)
        }
        func finished() { active -= 1 }
        func opened() { counts.primary += 1 }
        func recommended() { counts.recommendations += 1 }
    }

    private struct Recommendations: RelatedTitlesProviding {
        let id: MetadataSource = .tmdb
        let isEnabled = true
        let titles: [RelatedTitle]
        let requests: Requests
        func relatedTitles(for query: MetadataQuery, limit: Int) async -> [RelatedTitle] {
            await requests.recommended()
            do { try await Task.sleep(for: .milliseconds(350)) }
            catch { return [] }
            return Array(titles.prefix(limit))
        }
    }

    private struct LibraryProvider: LibraryItemBatchProviding {
        let kind: ProviderKind
        let accountID: String
        let items: [MediaItem]
        let seed: MediaItem
        let requests: Requests
        var session: UserSession {
            .init(server: .init(id: accountID, name: "Fixture", baseURL: URL(string: "https://fixture.invalid")!,
                                provider: kind),
                  userID: "viewer", userName: "Viewer", deviceID: "fixture", accessToken: "fixture")
        }
        func libraries() async throws -> [MediaLibrary] { [] }
        func continueWatching(limit: Int) async throws -> [MediaItem] { [] }
        func latest(limit: Int) async throws -> [MediaItem] { [] }
        func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
            throw AppError.notFound
        }
        func item(id: String) async throws -> MediaItem {
            if id == seed.id {
                await requests.opened()
                try await Task.sleep(for: .milliseconds(250))
                return seed
            }
            await requests.started(batch: false)
            do {
                try await Task.sleep(for: .milliseconds(40))
                guard let item = items.first(where: { $0.id == id && $0.sourceAccountID == accountID }) else {
                    throw AppError.notFound
                }
                await requests.finished()
                return item
            } catch {
                await requests.finished()
                throw error
            }
        }
        func libraryItems(ids: [String]) async throws -> [MediaItem] {
            await requests.started(batch: true)
            do {
                try await Task.sleep(for: .milliseconds(40))
                let result = items.filter { ids.contains($0.id) && $0.sourceAccountID == accountID }
                await requests.finished()
                return result.reversed()
            } catch {
                await requests.finished()
                throw error
            }
        }
        func children(of itemID: String) async throws -> [MediaItem] { [] }
        func search(query: String, limit: Int) async throws -> [MediaItem] {
            await requests.searched()
            let index = Int(query.split(separator: " ").last ?? "") ?? 0
            try await Task.sleep(for: .milliseconds(150 + (index % 6) * 70))
            return items.filter { $0.providerIDs["Tmdb"] == "\(index + 1)" && $0.sourceAccountID == accountID }
        }
        func playbackInfo(for itemID: String) async throws -> PlaybackRequest { throw AppError.notFound }
        func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {}
        func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
    }

    private struct SingleItemProvider: MediaProvider {
        let base: LibraryProvider
        var kind: ProviderKind { base.kind }
        var session: UserSession { base.session }
        func libraries() async throws -> [MediaLibrary] { [] }
        func continueWatching(limit: Int) async throws -> [MediaItem] { [] }
        func latest(limit: Int) async throws -> [MediaItem] { [] }
        func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
            throw AppError.notFound
        }
        func item(id: String) async throws -> MediaItem { try await base.item(id: id) }
        func children(of itemID: String) async throws -> [MediaItem] { [] }
        func search(query: String, limit: Int) async throws -> [MediaItem] {
            try await base.search(query: query, limit: limit)
        }
        func playbackInfo(for itemID: String) async throws -> PlaybackRequest { throw AppError.notFound }
        func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {}
        func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
    }
}
