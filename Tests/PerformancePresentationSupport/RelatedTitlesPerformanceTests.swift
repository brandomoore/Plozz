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

    private func measure(cached: Bool) async throws {
        try PerformanceProbe.requireEnabled()
        let fixture = try Fixture()
        defer { fixture.close() }
        try await PerformanceProbe.measure(
            self, scenario: cached ? "related-cached-scroll" : "related-cold-scroll"
        ) {
            try await fixture.exercise(cached: cached)
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

        func exercise(cached: Bool) async throws -> [String: Int] {
            let requests = Requests()
            let seed = MediaItem(id: "seed", title: "Seed", kind: .movie, providerIDs: ["Tmdb": "999"])
            let titles = (0..<24).map {
                RelatedTitle(title: "Candidate \($0)", kind: .movie, providerIDs: ["Tmdb": "\($0 + 1)"],
                             posterURL: artwork, source: .tmdb)
            }
            let owned = (0..<12).map { index -> MediaItem in
                var item = MediaItem(
                    id: "owned-\(index)", title: "Server title \(index)", kind: .movie,
                    productionYear: 2020, posterURL: artwork,
                    providerIDs: ["Tmdb": "\(index + 1)"], sourceAccountID: index.isMultiple(of: 2) ? "plex" : "silo"
                )
                item.catalogIdentityIsComplete = true
                item.allowsTitleBasedMetadataMatching = false
                return item
            }
            let providers = [ProviderKind.plex, .silo].map { kind in
                LibraryProvider(kind: kind, items: owned, requests: requests)
            }
            let accounts = providers.map {
                ResolvedAccount(account: Account(id: $0.kind.rawValue, from: $0.session), provider: $0)
            }
            let search = try XCTUnwrap(relatedTitleLibrarySearch(in: accounts))
            var identities: [MediaIdentity: [IndexedSource]] = [:]
            for item in owned {
                for identity in MediaItemIdentity.identities(for: item) {
                    identities[identity, default: []].append(.init(
                        accountID: try XCTUnwrap(item.sourceAccountID), itemID: item.id, kind: .movie,
                        normalizedTitle: MediaItemIdentity.normalizedTitle(titles[Int(item.id.dropFirst(6))!].title)
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
                loadIndexedItem: { source in
                    guard let provider = providers.first(where: { $0.kind.rawValue == source.accountID }) else {
                        XCTFail("Indexed item must resolve to its fixture account.")
                        return nil
                    }
                    return try? await provider.item(id: source.itemID)
                }
            )
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
            let loading = Task { await loader.load(for: seed) }
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
            XCTAssertEqual(loader.entries.map(\.item.title), owned.map(\.title))
            XCTAssertEqual(loader.entries.map(\.item.posterURL), owned.map(\.posterURL))
            XCTAssertEqual(probe.renderedCount, 12)
            XCTAssertGreaterThan(probe.firstMicroseconds, 0)
            let counts = await requests.counts
            return [
                "items": loader.entries.count, "searchRequests": counts.search,
                "detailRequests": counts.detail, "recommendationRequests": counts.recommendations,
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
        var counts = (search: 0, detail: 0, recommendations: 0)
        func searched() { counts.search += 1 }
        func fetched() { counts.detail += 1 }
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

    private struct LibraryProvider: MediaProvider {
        let kind: ProviderKind
        let items: [MediaItem]
        let requests: Requests
        var session: UserSession {
            .init(server: .init(id: kind.rawValue, name: "Fixture", baseURL: URL(string: "https://fixture.invalid")!,
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
            await requests.fetched()
            try await Task.sleep(for: .milliseconds(40))
            guard let item = items.first(where: { $0.id == id && $0.sourceAccountID == kind.rawValue }) else {
                throw AppError.notFound
            }
            return item
        }
        func children(of itemID: String) async throws -> [MediaItem] { [] }
        func search(query: String, limit: Int) async throws -> [MediaItem] {
            await requests.searched()
            let index = Int(query.split(separator: " ").last ?? "") ?? 0
            try await Task.sleep(for: .milliseconds(150 + (index % 6) * 70))
            return items.filter { $0.id == "owned-\(index)" && $0.sourceAccountID == kind.rawValue }
        }
        func playbackInfo(for itemID: String) async throws -> PlaybackRequest { throw AppError.notFound }
        func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {}
        func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
    }
}
