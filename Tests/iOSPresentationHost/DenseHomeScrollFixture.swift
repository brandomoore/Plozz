import CoreModels
import CoreUI
import FeatureAuth
import FeatureHomeCore
import SwiftUI
import UIKit
@testable import AppShelliOS

/// Keep the shipping Home scroll view, geometry, rails, cards and image pipeline.
/// Only the 20 server accounts and their compressed poster responses are synthetic.
struct DenseHomeScrollFixture: View {
    @State private var app: PlozziOSAppModel?
    @State private var home: HomeViewModel?
    @State private var trailer = HeroTrailerController()
    @State private var gate: PublicationGate?

    var body: some View {
        Group {
            if let app, let home {
                NavigationStack {
                    PlozziOSHomeView(appModel: app, viewModel: home, onAddServer: {}, onShowSettings: {})
                }
                .environment(app)
                .environment(trailer)
                .environment(\.themePalette, .dark)
                .environment(\.plozzMetrics, .touch(density: .standard))
                .overlay(alignment: .bottomTrailing) { ScrollControls(home: home, gate: gate) }
            } else {
                ProgressView()
            }
        }
        .preferredColorScheme(.dark)
        .task {
            guard app == nil else { return }
            SyncSetupFeatureFlag().isEnabled = false
            let accounts = AccountStore(secureStore: InMemorySecureStore())
            let suite = "DenseHomeScrollFixture"
            let defaults = UserDefaults(suiteName: suite)!
            defaults.removePersistentDomain(forName: suite)
            let app = PlozziOSAppModel(accountStore: accounts, profileStore: ProfileStore(defaults: defaults))
            let profile = app.profiles.add(name: "Dense Home", isAwaitingSetup: false)
            app.selectProfile(profile.id)
            app.profiles.markFirstRunProfileSetupComplete()
            app.settings.hero.settings.isEnabled = false
            app.settings.heroBackground.settings.homeTrailerEnabled = false
            app.settings.homeVisibility.useRowDefaults(.matchServer)
            app.metadataProviderSettingsModel.settings = MetadataProviderSettings(
                orderMode: .custom, preferOnlineArtwork: false, disabledOrder: MetadataSourceAttribution.all.map(\.id)
            )
            let ids = (0..<20).map { String(format: "server-%02d", $0) }
            for id in ids {
                let server = MediaServer(id: id, name: id, baseURL: URL(string: "https://\(id).invalid")!, provider: .jellyfin)
                do {
                    try accounts.add(Account(id: id, server: server, userID: "viewer", userName: "Viewer",
                                             deviceID: "fixture"), token: "fixture")
                } catch { preconditionFailure("Could not seed Home account: \(error)") }
            }
            DenseShelfProvider.seedPosters(serverIDs: ids)
            app.profiles.setActiveAccountIDs(ids, for: profile.id)
            let gate = ProcessInfo.processInfo.arguments.contains("--during-publication") ? PublicationGate() : nil
            self.gate = gate
            app.accountsProviders.registry.register(.jellyfin) { DenseShelfProvider(session: $0.session, gate: gate) }
            app.accountsProviders.tokenResolver = { _ in "fixture" }
            app.accountsProviders.reloadAccounts()
            await app.settings.homeVisibility.prepareServerDefaults(accounts: app.accountsProviders.homeAccounts)
            if let gate {
                let first = app.settings.homeVisibility.visibility.rowCustomization?.availableServerRows.prefix(4) ?? []
                gate.allow(Set(first.map { "\($0.accountID)-\($0.section.id)" }))
            }
            self.home = HomeViewModel(
                accounts: app.accountsProviders.homeAccounts, layoutStore: InMemoryHomeLayoutStore(),
                contentStore: NoOpHomeContentStore(), currentVisibility: { app.settings.homeVisibility.visibility }
            )
            self.app = app
        }
    }

    /// Queried on demand, never a scroll delegate, timer or display-link observer.
    private struct ScrollControls: View {
        let home: HomeViewModel
        let gate: PublicationGate?
        @State private var report = ""
        @State private var motion = PublicationMotion()

        var body: some View {
            HStack {
                Button("Top") {
                    guard let scroll = verticalScroll else { return }
                    scroll.setContentOffset(CGPoint(x: 0, y: -scroll.adjustedContentInset.top), animated: false)
                }.accessibilityIdentifier("dense-top")
                Button("Inspect") {
                    guard let scroll = verticalScroll, let screen = scroll.window?.windowScene?.screen else {
                        report = "missing-scroll"
                        return
                    }
                    let rows = home.state.value?.serverRows ?? []
                    let complete = rows.filter { !$0.isLoading && $0.failure == nil && $0.items.count == 20 }.count
                    if let gate { motion.arm(scroll, gate: gate) }
                    var fields = [
                        "rows=\(complete)", "total=\(rows.count)",
                        "y=\(Int((scroll.contentOffset.y + scroll.adjustedContentInset.top).rounded()))",
                        "width=\(Int(scroll.bounds.width))", "height=\(Int(scroll.bounds.height))",
                        "screen=\(Int(screen.bounds.width))", "content=\(Int(scroll.contentSize.height))",
                        "pad=\(scroll.traitCollection.userInterfaceIdiom == .pad ? 1 : 0)",
                        "regular=\(scroll.traitCollection.horizontalSizeClass == .regular ? 1 : 0)",
                        "moving=\(scroll.isDragging || scroll.isDecelerating ? 1 : 0)",
                        "loading=\(home.isRefreshing ? 1 : 0)"
                    ]
                    if let gate {
                        fields += motion.fields + gate.work + ["pid=\(ProcessInfo.processInfo.processIdentifier)"]
                    }
                    report = fields.joined(separator: " ")
                }
                .accessibilityIdentifier("dense-inspect")
                .accessibilityValue(Text(verbatim: report))
            }
            .font(.caption).buttonStyle(.bordered)
            .background {
                if gate != nil {
                    Color.clear.onChange(of: home.state.value?.serverRows.filter {
                        !$0.isLoading && !$0.items.isEmpty && $0.failure == nil
                    }.count ?? 0) { old, new in
                        motion.published(old: old, new: new)
                    }
                }
            }
        }

        private var verticalScroll: UIScrollView? {
            func find(_ view: UIView) -> UIScrollView? {
                if let scroll = view as? UIScrollView, scroll.bounds.height > 100,
                   scroll.contentSize.height > 2 * scroll.bounds.height { return scroll }
                for child in view.subviews {
                    if let scroll = find(child) { return scroll }
                }
                return nil
            }
            return UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }
                .compactMap { find($0) }.first
        }
    }
}

/// Stop after the first two source batches. The next provider request suspends
/// until UIKit recognizes the real vertical pan, not a guessed delay after launch.
private final class PublicationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var pending: [CheckedContinuation<Void, Never>] = []
    private var shelfKeys: [String] = []
    private var immediateKeys: Set<String> = []
    private var calls: [String: Int] = [:]

    func count(_ kind: String) { lock.withLock { calls[kind, default: 0] += 1 } }
    func allow(_ keys: Set<String>) {
        precondition(keys.count == 4)
        lock.withLock { immediateKeys = keys }
    }
    var work: [String] {
        lock.withLock {
            ["shelves=\(shelfKeys.count)", "distinct=\(Set(shelfKeys).count)"]
                + calls.map { "\($0.key)=\($0.value)" }
        }
    }

    func wait(for key: String) async throws {
        let deferred = lock.withLock {
            shelfKeys.append(key)
            return !immediateKeys.contains(key)
        }
        if deferred {
            await withCheckedContinuation { waiter in
                let ready = lock.withLock {
                    if !opened { pending.append(waiter) }
                    return opened
                }
                if ready { waiter.resume() }
            }
            try await Task.sleep(for: .milliseconds(30))
        }
    }

    func open() {
        let waiters = lock.withLock {
            opened = true
            defer { pending.removeAll() }
            return pending
        }
        for waiter in waiters { waiter.resume() }
    }
}

@MainActor
private final class PublicationMotion: NSObject {
    private weak var scroll: UIScrollView?
    private var gate: PublicationGate?
    private var gains = 0, updates = 0, stall = 0
    private var minHeight = Int.max, maxHeight = 0, panHeight = 0
    var fields: [String] {
        ["gains=\(gains)", "updates=\(updates)", "panHeight=\(panHeight)",
         "minHeight=\(minHeight)", "maxHeight=\(maxHeight)", "stall=\(stall)"]
    }

    func arm(_ scroll: UIScrollView, gate: PublicationGate) {
        guard self.scroll !== scroll else { return }
        self.scroll?.panGestureRecognizer.removeTarget(self, action: #selector(pan(_:)))
        self.scroll = scroll
        self.gate = gate
        scroll.panGestureRecognizer.addTarget(self, action: #selector(pan(_:)))
    }

    @objc private func pan(_ recognizer: UIPanGestureRecognizer) {
        guard recognizer.state == .began, let scroll else { return }
        panHeight = Int(scroll.contentSize.height)
        gate?.open()
        if ProcessInfo.processInfo.arguments.contains("--calibrate-hitch") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) { [weak self] in
                guard let self, let moving = self.scroll, moving.isDragging || moving.isDecelerating else { return }
                stall += 1
                Thread.sleep(forTimeInterval: 0.35)
            }
        }
    }

    func published(old: Int, new: Int) {
        guard new > old, let scroll, scroll.isDragging || scroll.isDecelerating else { return }
        gains += new - old
        updates += 1
        let h = Int(scroll.contentSize.height)
        minHeight = min(minHeight, h)
        maxHeight = max(maxHeight, h)
    }
}

private struct DenseShelfProvider: MediaProvider {
    let session: UserSession
    let gate: PublicationGate?
    var kind: ProviderKind { .jellyfin }
    private static let sections = ["premieres", "favorites"]
    private static func poster(_ id: String) -> URL { URL(string: "https://posters.invalid/\(id).jpg")! }

    @MainActor static func seedPosters(serverIDs: [String]) {
        guard let cache = ArtworkSession.shared.configuration.urlCache else { preconditionFailure("No artwork cache") }
        let size = CGSize(width: 320, height: 480)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        for (server, id) in serverIDs.enumerated() {
            for (shelf, section) in sections.enumerated() {
                for index in 0..<20 {
                    let key = "\(id)-\(section)-\(index)"
                    let url = poster(key)
                    let data = renderer.jpegData(withCompressionQuality: 0.83) { context in
                        let hue = CGFloat((server * 67 + shelf * 13 + index * 19) % 360) / 360
                        UIColor(hue: hue, saturation: 0.76, brightness: 0.79, alpha: 1).setFill()
                        context.fill(CGRect(origin: .zero, size: size))
                        // A common band lets the UI test distinguish actual decoded posters from gray cards.
                        UIColor(red: 0.97, green: 0.34, blue: 0.07, alpha: 1).setFill()
                        context.fill(CGRect(x: 0, y: 170, width: 320, height: 96))
                        context.cgContext.setFillColor(UIColor.white.cgColor)
                        context.cgContext.fillEllipse(in: CGRect(x: 36 + index * 4, y: 62, width: 78, height: 78))
                        (key as NSString).draw(at: CGPoint(x: 12, y: 382), withAttributes: [
                            .font: UIFont.boldSystemFont(ofSize: 24), .foregroundColor: UIColor.white
                        ])
                    }
                    let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: [
                        "Content-Type": "image/jpeg", "Cache-Control": "public, max-age=86400"
                    ])!
                    cache.storeCachedResponse(CachedURLResponse(response: response, data: data), for: URLRequest(url: url))
                }
            }
        }
    }

    func serverHomeLayout() async throws -> ServerHomeLayout? {
        .init(sections: Self.sections.map {
            ServerHomeSection(id: $0, kind: .recommendations, title: "\(session.server.name) \($0)", libraryID: "movies")
        }, source: .server)
    }
    func serverHomeItems(section: ServerHomeSection, limit: Int, excludingLibraryIDs: Set<String>) async throws -> [MediaItem] {
        try await gate?.wait(for: "\(session.server.id)-\(section.id)")
        return (0..<min(limit, 20)).map { index in
            let id = "\(session.server.id)-\(section.id)-\(index)"
            var item = MediaItem(id: id, title: "Movie \(id)", kind: .movie,
                                 overview: "A library premiere from \(session.server.name).", productionYear: 2000 + index,
                                 runtime: 5400, allowsTitleBasedMetadataMatching: false)
            item.libraryID = "movies"
            item.posterURL = Self.poster(id)
            return item
        }
    }
    func libraries() async throws -> [MediaLibrary] {
        gate?.count("libraries")
        return [.init(id: "movies", title: "Movies", kind: .movie)]
    }
    func continueWatching(limit: Int) async throws -> [MediaItem] { gate?.count("history"); return [] }
    func latest(limit: Int) async throws -> [MediaItem] { gate?.count("latest"); return [] }
    func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        .init(items: [], startIndex: 0, totalCount: 0)
    }
    func item(id: String) async throws -> MediaItem { throw AppError.notFound }
    func children(of itemID: String) async throws -> [MediaItem] { [] }
    func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
    func playbackInfo(for itemID: String) async throws -> PlaybackRequest { throw AppError.notFound }
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {}
    func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
}
