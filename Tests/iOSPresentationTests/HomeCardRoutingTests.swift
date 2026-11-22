#if os(iOS)
import CoreModels
import CoreUI
import Observation
import SwiftUI
import UIKit
import XCTest
@testable import AppShelliOS

@MainActor
final class HomeCardRoutingTests: XCTestCase {
    func testDetailPrewarmingCannotReopenAnInactiveViewersCaches() throws {
        let app = PlozziOSAppModel()
        let current = try XCTUnwrap(app.detailRevisitResources(for: app.detailArtworkScopeID))
        XCTAssertTrue(current.snapshots === app.detailSnapshotCache)
        XCTAssertTrue(current.replay === app.detailArtworkReplay)
        XCTAssertNil(app.detailRevisitResources(for: "previous-viewer"))
    }

    func testBrowsingDetailAndContinueWatchingCardsDoesNotResolveSources() async throws {
        for interaction in [PlozziOSRailInteraction.openDetail, .play] {
            let before = PlozziOSHomeMediaCard.routingResolutionCount
            let fixture = try await Fixture(provider: Fixture.Provider(), interaction: interaction)
            defer { fixture.close() }
            for _ in 0..<4 { try await fixture.update() }
            XCTAssertEqual(PlozziOSHomeMediaCard.routingResolutionCount, before)
        }
    }

    func testActivationReadsCurrentIndexWithoutOverridingDetailEditionOrContainer() {
        let app = PlozziOSAppModel()
        let item = MediaItem(id: "original", title: "Movie", kind: .movie, providerIDs: ["tmdb": "123"])
        func publish(_ id: String) {
            app.identityIndex.identitySnapshotStore.update(IdentityIndexSnapshot(byIdentity: [
                .external(source: "tmdb", value: "123"): [
                    IndexedSource(accountID: "fixture", itemID: id, providerKind: .jellyfin, kind: .movie)
                ]
            ]))
        }
        publish("first")
        XCTAssertEqual(PlozziOSHomeMediaCard.resolvedItem(item, appModel: app, playsDirectly: true).id, "first")
        publish("second")
        XCTAssertEqual(PlozziOSHomeMediaCard.resolvedItem(item, appModel: app, playsDirectly: false).id, "second")
        var explicit = item
        explicit.edition = "Theatrical"
        explicit.sourceAccountID = "fixture"
        XCTAssertEqual(PlozziOSHomeMediaCard.resolvedItem(explicit, appModel: app, playsDirectly: false), explicit)
        for kind in [MediaItemKind.folder, .collection] {
            var container = item
            container.kind = kind
            XCTAssertEqual(PlozziOSHomeMediaCard.resolvedItem(container, appModel: app, playsDirectly: false), container)
        }
    }

    func testPerformanceHomeCardUpdates() async throws {
        try PerformanceProbe.requireEnabled()
        let fixture = try await Fixture()
        defer { fixture.close() }
        try await PerformanceProbe.measure(self, scenario: "mobile-home-card-routing") {
            let before = PlozziOSHomeMediaCard.routingResolutionCount
            for _ in 0..<24 {
                try await fixture.update()
            }
            return [
                "rootUpdates": 24, "cards": fixture.items.count,
                "sourceResolutions": PlozziOSHomeMediaCard.routingResolutionCount - before,
                "observedRevision": fixture.state.presentedRevision
            ]
        }
    }

    @MainActor @Observable
    final class Model {
        var revision = 0
        @ObservationIgnored var presentedRevision = -1
    }

    private struct Cards: View {
        let app: PlozziOSAppModel
        let state: Model
        let items: [MediaItem]
        let provider: (any MediaProvider)?
        let interaction: PlozziOSRailInteraction

        var body: some View {
            let revision = state.revision
            NavigationStack {
                VStack {
                    ForEach(0..<4) { row in
                        HStack {
                            ForEach(0..<6) { column in
                                let item = updated(items[row * 6 + column], revision: revision)
                                PlozziOSHomeMediaCard(
                                    item: item, isLandscape: false, interaction: interaction, provider: provider
                                )
                                    .frame(width: 100, height: 200)
                            }
                        }
                    }
                }
                .background(RevisionProbe(state: state, revision: revision))
            }
            .environment(app)
            .environment(\.plozzCardStyle, .borderless)
            .environment(\.plozzMetrics, .touch(density: .standard, dynamicTypeSize: .large))
            .plozziOSRailPlay { _ in XCTFail("Browsing must not activate playback.") }
        }

        private func updated(_ item: MediaItem, revision: Int) -> MediaItem {
            var copy = item
            copy.overview = "Metadata revision \(revision)"
            return copy
        }
    }

    private struct RevisionProbe: UIViewRepresentable {
        let state: Model
        let revision: Int
        func makeUIView(context: Context) -> UIView { UIView() }
        func updateUIView(_ view: UIView, context: Context) {
            state.presentedRevision = revision
        }
    }

    @MainActor
    private final class Fixture {
        let app = PlozziOSAppModel()
        let state = Model()
        let items: [MediaItem]
        let window: UIWindow
        let previous: UIWindow?

        init(provider: (any MediaProvider)? = nil, interaction: PlozziOSRailInteraction = .openDetail) async throws {
            let deadline = ContinuousClock.now + .seconds(5)
            while !UIApplication.shared.connectedScenes.contains(where: { $0.activationState == .foregroundActive }),
                  ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .first { $0.activationState == .foregroundActive })
            previous = scene.windows.first(where: \.isKeyWindow)
            window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 834, height: 1194)
            items = (0..<24).map { index in
                MediaItem(
                    id: "movie-\(index)", title: "Movie \(index)", kind: .movie,
                    people: (0..<32).map { MediaPerson(id: "person-\($0)", name: "Person \($0)") },
                    providerIDs: ["tmdb": "\(index + 1)", "imdb": "tt\(index + 1)"]
                )
            }
            let entries = Dictionary(uniqueKeysWithValues: items.enumerated().map { index, item in
                (MediaIdentity.external(source: "tmdb", value: "\(index + 1)"), (0..<4).map { account in
                    IndexedSource(
                        accountID: "account-\(account)", itemID: item.id, providerKind: account == 0 ? .plex : .jellyfin,
                        kind: item.kind, normalizedTitle: MediaItemIdentity.normalizedTitle(item.title)
                    )
                })
            })
            app.identityIndex.identitySnapshotStore.update(IdentityIndexSnapshot(byIdentity: entries))
            window.rootViewController = UIHostingController(rootView: Cards(
                app: app, state: state, items: items, provider: provider, interaction: interaction
            ))
            window.makeKeyAndVisible()
            try await update()
        }

        func update() async throws {
            state.revision += 1
            let deadline = ContinuousClock.now + .seconds(3)
            repeat {
                window.layoutIfNeeded()
                if state.presentedRevision == state.revision { return }
                try await Task.sleep(for: .milliseconds(2))
            } while ContinuousClock.now < deadline
            XCTFail("Production Home cards did not receive the metadata update.")
        }

        func close() {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }

        struct Provider: MediaProvider {
            let kind = ProviderKind.jellyfin
            var session: UserSession {
                UserSession(
                    server: MediaServer(id: "fixture", name: "Fixture", baseURL: URL(string: "https://fixture.invalid")!,
                                        provider: kind),
                    userID: "viewer", userName: "Viewer", deviceID: "fixture", accessToken: "fixture"
                )
            }
            func libraries() async throws -> [MediaLibrary] { [] }
            func continueWatching(limit: Int) async throws -> [MediaItem] { [] }
            func latest(limit: Int) async throws -> [MediaItem] { [] }
            func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
                throw AppError.notFound
            }
            func item(id: String) async throws -> MediaItem { throw AppError.notFound }
            func children(of itemID: String) async throws -> [MediaItem] { [] }
            func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
            func playbackInfo(for itemID: String) async throws -> PlaybackRequest { throw AppError.notFound }
            func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {}
            func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
        }
    }
}
#endif
