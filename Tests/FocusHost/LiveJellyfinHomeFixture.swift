import CoreModels
import CoreNetworking
import CoreUI
import FeatureHome
import FeatureHomeCore
import Foundation
import ProviderJellyfin
import SwiftUI
import UIKit
import notify

/// Explicit opt-in only. Numeric reports exclude credentials and media identities.
struct LiveJellyfinHomeFixture: View {
    @State private var session: UserSession?
    @State private var state: LiveJellyfinHomeState?
    @State private var failed = false
    @FocusState private var startFocused: Bool

    var body: some View {
        Group {
            if let state {
                NavigationStack {
                    HomeView(
                        viewModel: state.model, visibility: state.visibility,
                        heroSettings: state.heroSettings, heroBackground: state.background,
                        heroTrailerController: state.trailer, heroIsFrontmost: true,
                        heroRuntime: state.runtime, heroArtworkProvider: { $0.backdropURL },
                        onSelectItem: { _ in }, onPlayItem: { _ in },
                        onSelectLibrary: { _ in }, onBrowse: { _ in }
                    )
                }
                .overlay(alignment: .topTrailing) {
                    Text(state.status)
                        .accessibilityIdentifier("live-home-status")
                        .font(.caption2)
                        .allowsHitTesting(false)
                }
                .task { await state.load() }
            } else if let session {
                Button("Load real Home") { state = LiveJellyfinHomeState(session: session) }
                    .accessibilityIdentifier("live-home-start")
                    .focused($startFocused)
                    .task { startFocused = true }
            } else {
                Text(failed ? "Live Home setup failed" : "Preparing internal measurement")
            }
        }
        .task {
            do {
                session = try await Self.configuration()
            } catch {
                failed = true
                // Do not interpolate network errors, which may contain the private endpoint.
                PlozzLog.app.error("Live Home measurement configuration failed")
            }
        }
    }

    private static func configuration() async throws -> UserSession {
        guard let address = ProcessInfo.processInfo.environment["PLOZZ_JELLYFIN_HOME_BROKER"],
              let url = URL(string: address), url.scheme == "http", url.host == "127.0.0.1",
              url.port != nil, url.user == nil, url.password == nil, url.query == nil,
              url.fragment == nil else { throw AppError.invalidResponse }
        let (data, response) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 30))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw AppError.invalidResponse }
        let config = try JSONDecoder().decode(Configuration.self, from: data)
        guard ["http", "https"].contains(config.baseURL.scheme), config.baseURL.host != nil,
              config.baseURL.user == nil, config.baseURL.password == nil,
              config.baseURL.query == nil, config.baseURL.fragment == nil,
              !config.token.isEmpty else { throw AppError.invalidResponse }
        return UserSession(
            server: .init(id: config.serverID, name: "Internal measurement",
                          baseURL: config.baseURL, provider: .jellyfin),
            userID: config.userID, userName: config.username,
            deviceID: config.deviceID, accessToken: config.token
        )
    }

    private struct Configuration: Decodable {
        let baseURL: URL
        let serverID: String
        let userID: String
        let username: String
        let deviceID: String
        let token: String
    }
}

@MainActor @Observable
private final class LiveJellyfinHomeState: NSObject {
    let visibility: HomeLibraryVisibilityModel
    let model: HomeViewModel
    let heroSettings = HeroSettingsModel()
    let background = HeroBackgroundSettingsModel()
    let trailer = HeroTrailerController()
    let runtime = HomeHeroRuntimeState()
    private(set) var status = "Loading real Home"
    @ObservationIgnored private let accounts: [ResolvedAccount]
    @ObservationIgnored private let http: LiveHomeHTTP
    @ObservationIgnored private var link: CADisplayLink?
    @ObservationIgnored private var notifications: [Int32] = []
    @ObservationIgnored private let started: CFTimeInterval
    @ObservationIgnored private var previousTick: CFTimeInterval?
    @ObservationIgnored private var phase = "loading"
    @ObservationIgnored private var counters: [String: Int] = [:]
    @ObservationIgnored private var didLoad = false
    @ObservationIgnored private var finished = false
    @ObservationIgnored private var focusObserver: (any NSObjectProtocol)?

    init(session: UserSession, started: CFTimeInterval = CACurrentMediaTime()) {
        self.started = started
        let http = LiveHomeHTTP()
        self.http = http
        let visibility = HomeLibraryVisibilityModel(store: LiveHomeVisibility())
        self.visibility = visibility
        let provider = JellyfinProvider(session: session, http: http)
        let accounts = [ResolvedAccount(account: Account(id: "measurement", from: session), provider: provider)]
        self.accounts = accounts
        model = HomeViewModel(
            accounts: accounts, layoutStore: InMemoryHomeLayoutStore(),
            contentStore: InMemoryHomeContentStore(), currentVisibility: { visibility.visibility },
            prepareVisibility: { await visibility.prepareServerDefaults(accounts: accounts) }
        )
        super.init()
        MetadataProviderSettingsStore().save(.init(
            orderMode: .custom, disabledOrder: MetadataSourceAttribution.all.map(\.source.rawValue)
        ))
        var hero = heroSettings.settings
        hero.isEnabled = true
        hero.sources = [.continueWatching, .recentlyAdded]
        hero.style = .carousel
        hero.autoAdvance = false
        hero.trailersEnabled = false
        hero.showsDiscoverRow = false
        heroSettings.settings = hero
        background.settings.homeTrailerEnabled = false
        counters["artworkDiskBytesBefore"] = ArtworkSession.cacheUsage().diskBytes
        counters["setupMicroseconds"] = elapsed()
        previousTick = started
        focusObserver = NotificationCenter.default.addObserver(
            forName: UIFocusSystem.didUpdateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.phase == "navigation" else { return }
                self.counters["navigationFocusChanges", default: 0] += 1
            }
        }
        let link = CADisplayLink(target: self, selector: #selector(tick))
        self.link = link
        link.add(to: .main, forMode: .common)
        for action in ["navigation", "finish"] {
            var token: Int32 = 0
            let runID = ProcessInfo.processInfo.environment["PLOZZ_LIVE_HOME_RUN_ID"] ?? ""
            precondition(!runID.isEmpty, "Live Home requires an owned profiling run")
            let result = notify_register_dispatch("com.thatcube.Plozz.live-home.\(runID)." + action, &token, .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if action == "navigation" {
                        self.phase = "navigation"
                        self.previousTick = nil
                    } else {
                        Task { await self.finish() }
                    }
                }
            }
            precondition(result == NOTIFY_STATUS_OK, "Live Home measurement notification registration failed")
            notifications.append(token)
        }
    }

    func load() async {
        guard !didLoad else { return }
        didLoad = true
        let discovered = await HomeAggregator().libraryDiscovery(from: accounts)
        // HomeView owns loadIfNeeded. Calling load here would enqueue a second refresh.
        do {
            let deadline = ContinuousClock.now + .seconds(35)
            while model.state.value == nil || model.isRefreshing {
                guard ContinuousClock.now < deadline else { throw AppError.invalidResponse }
                try await Task.sleep(for: .milliseconds(25))
            }
        } catch {
            status = "Real Home load failed"
            PlozzLog.app.error("Live Home measurement did not finish loading")
            return
        }
        counters["allDataMicroseconds"] = elapsed()
        counters["discoveryFailures"] = discovered.failures.count
        counters["layoutFailures"] = visibility.serverMatchFailures.count
        if let content = model.state.value {
            counters["libraries"] = content.libraries.count
            counters["serverRows"] = content.serverRows.count
            counters["items"] = content.continueWatching.count + content.latest.count
                + content.watchlist.count + content.serverRows.reduce(0) { $0 + $1.items.count }
            counters["rowFailures"] = content.serverRows.filter { $0.failure != nil }.count
        }
        status = "Real Home data ready"
    }

    @objc private func tick() {
        let now = CACurrentMediaTime()
        if let previousTick {
            let gap = Int((now - previousTick) * 1_000_000)
            counters[phase + "MaximumCallbackGapMicroseconds"] = max(
                counters[phase + "MaximumCallbackGapMicroseconds", default: 0], gap
            )
            if gap > 50_000 { counters[phase + "CallbacksOver50ms", default: 0] += 1 }
        }
        previousTick = now
        counters[phase + "Callbacks", default: 0] += 1
        if counters["firstDataMicroseconds"] == nil, let content = model.state.value,
           !content.continueWatching.isEmpty || !content.latest.isEmpty || !content.watchlist.isEmpty
            || content.serverRows.contains(where: { !$0.items.isEmpty }) {
            counters["firstDataMicroseconds"] = elapsed()
        }
    }

    private func finish() async {
        guard !finished else { return }
        finished = true
        link?.invalidate()
        link = nil
        for token in notifications { notify_cancel(token) }
        notifications = []
        if let focusObserver { NotificationCenter.default.removeObserver(focusObserver) }
        focusObserver = nil
        counters["totalMicroseconds"] = elapsed()
        counters.merge(await http.snapshot(), uniquingKeysWith: { _, new in new })
        if let content = model.state.value {
            let items = content.continueWatching + content.latest + content.watchlist
                + content.serverRows.flatMap(\.items)
            let urls = Set(items.flatMap { [$0.posterURL, $0.backdropURL].compactMap { $0 } })
            counters["decodedServerArtwork"] = urls.filter { url in
                ArtworkImageVariant.allCases.contains {
                    ArtworkImageCache.shared.cachedImage(for: url, variant: $0) != nil
                }
            }.count
        }
        func images(_ view: UIView) -> Int {
            let own = (view as? UIImageView)?.image != nil
                && view.bounds.width > 100 && view.bounds.height > 100 ? 1 : 0
            return own + view.subviews.reduce(0) { $0 + images($1) }
        }
        counters["mountedArtworkImages"] = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
            .reduce(0) { $0 + images($1) }
        do {
            let url = try FileManager.default.url(
                for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true
            ).appendingPathComponent("live-home-ui.json")
            try JSONEncoder().encode(counters).write(to: url, options: .atomic)
            status = "Real Home measured"
        } catch {
            status = "Real Home measurement failed"
            PlozzLog.app.error("Live Home measurement could not persist aggregate counters")
        }
    }

    private func elapsed() -> Int { Int((CACurrentMediaTime() - started) * 1_000_000) }
}

private struct LiveHomeVisibility: HomeLibraryVisibilityStoring {
    func load() -> HomeLibraryVisibility { .default }
    func save(_ visibility: HomeLibraryVisibility) {}
}

private actor LiveHomeHTTP: HTTPClient {
    private let client = URLSessionHTTPClient()
    private var requests = 0
    private var bytes = 0
    private var maximumRequestMicroseconds = 0
    func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
        requests += 1
        let started = CACurrentMediaTime()
        let response = try await client.send(endpoint, baseURL: baseURL)
        maximumRequestMicroseconds = max(
            maximumRequestMicroseconds, Int((CACurrentMediaTime() - started) * 1_000_000)
        )
        bytes += response.0.count
        return response
    }
    func snapshot() -> [String: Int] {
        ["metadataRequests": requests, "metadataBytes": bytes,
         "metadataMaximumRequestMicroseconds": maximumRequestMicroseconds]
    }
}
