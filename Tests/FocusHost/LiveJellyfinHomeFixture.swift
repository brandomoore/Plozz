@testable import AppShell
import CoreModels
import CoreNetworking
import CoreSecureStore
import CoreUI
import FeatureAuth
import FeatureHome
import FeatureHomeCore
import Foundation
import ProviderJellyfin
import ProviderPlex
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

    fileprivate static func configuration() async throws -> UserSession {
        let config: Configuration = try await LiveFixtureBroker.read("PLOZZ_JELLYFIN_HOME_BROKER")
        guard ["http", "https"].contains(config.baseURL.scheme), config.baseURL.host != nil,
              config.baseURL.user == nil, config.baseURL.password == nil,
              config.baseURL.query == nil, config.baseURL.fragment == nil,
              !config.token.isEmpty else { throw AppError.invalidResponse }
        let kind = ProviderKind(rawValue: ProcessInfo.processInfo.environment["PLOZZ_LIVE_HOME_PROVIDER"] ?? "jellyfin")
        guard let kind, [.jellyfin, .emby, .plex].contains(kind) else { throw AppError.invalidResponse }
        return UserSession(
            server: .init(id: config.serverID, name: "Internal measurement",
                          baseURL: config.baseURL, provider: kind),
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

private final class LiveFixtureBroker: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    static func read<Value: Decodable>(_ key: String) async throws -> Value {
        guard let address = ProcessInfo.processInfo.environment[key], let url = URL(string: address),
              url.scheme == "http", url.host == "127.0.0.1", url.port != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil
        else { throw AppError.invalidResponse }
        let client = URLSession(configuration: .ephemeral, delegate: LiveFixtureBroker(), delegateQueue: nil)
        defer { client.invalidateAndCancel() }
        let (bytes, response) = try await client.data(for: URLRequest(url: url, timeoutInterval: 30))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw AppError.invalidResponse }
        return try JSONDecoder().decode(Value.self, from: bytes)
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
        let provider: any MediaProvider = session.server.provider == .plex
            ? PlexProvider(session: session, http: http)
            : JellyfinProvider(session: session, http: http)
        let accounts = [ResolvedAccount(account: Account(id: "measurement", from: session), provider: provider)]
        self.accounts = accounts
        model = HomeViewModel(
            accounts: accounts, layoutStore: InMemoryHomeLayoutStore(),
            contentStore: InMemoryHomeContentStore(), currentVisibility: { visibility.visibility },
            prepareHomeVisibility: { load in
                await visibility.prepareServerDefaults(accounts: accounts, homeLoad: load)
            }
        )
        super.init()
        MetadataProviderSettingsStore().save(.init(
            orderMode: .custom, disabledOrder: MetadataSourceAttribution.all.map(\.source.rawValue)
        ))
        var hero = heroSettings.settings
        hero.isEnabled = true
        hero.sources = [.continueWatching, .recentlyAdded]
        hero.style = ProcessInfo.processInfo.arguments.contains("--live-showcase-home") ? .heroShowcase : .carousel
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
        let path = endpoint.path.lowercased()
        guard endpoint.method == .get, endpoint.body == nil,
              !path.contains("/:/"), !path.contains("playbackinfo"),
              !path.contains("transcode"), !path.contains("/sessions") else {
            throw AppError.invalidResponse
        }

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

// MARK: - Cold sign-in (standalone FocusHost, not the already-loaded Home profiler)

@MainActor
final class SignInFirstFrameRun: NSObject, ObservableObject {
    enum Mode: Int { case account = 1, seed, profile }
    let mode: Mode
    @Published private(set) var app: AppState?
    private let origin = CACurrentMediaTime()
    private let output = DispatchQueue(label: "first-frame.numeric-report")
    private let hold = ProcessInfo.processInfo.arguments.contains("--first-frame-hold")
    private var nextGateCheck: CFTimeInterval = 0
    private var values: [String: Int] = [:]
    private var display: CADisplayLink?
    private var previous: CFTimeInterval?
    private var reference: CFTimeInterval?
    private var regionObserver: NSObjectProtocol?
    private let regions = NSHashTable<NavigationEntryFocusRegionView>.weakObjects()
    fileprivate weak var marker: FirstFrameMarker?
    private var connection: Credentials?
    private var started = false
    private var finished = false

    private struct Credentials: Decodable {
        let baseURL: URL
        let username, password: String
    }

    static func requested() -> SignInFirstFrameRun? {
        #if targetEnvironment(simulator)
        let args = ProcessInfo.processInfo.arguments
        for (flag, mode): (String, Mode) in [
            ("--first-frame-account", .account), ("--first-frame-seed", .seed), ("--first-frame-profile", .profile)
        ] where args.contains(flag) {
            return SignInFirstFrameRun(mode: mode)
        }
        #endif
        return nil
    }

    private static let suite = "com.thatcube.Plozz.FocusHost.first-frame"

    private init(mode: Mode) {
        self.mode = mode
        super.init()
        values = ["mode": mode.rawValue, "armedUs": us(origin), "pid": Int(getpid())]
        save()
        // XCTest hosts deliberately skip production work. Never accept one as a sample.
        guard !AppState.isRunningUnitTests else { fail(1); return }
        if mode != .seed {
            let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
            display = link
            link.add(to: .main, forMode: .common)
            regionObserver = NotificationCenter.default.addObserver(
                forName: NavigationEntryFocusRegionView.didChange, object: nil, queue: .main
            ) { [weak self] note in
                guard let region = note.object as? NavigationEntryFocusRegionView else { return }
                MainActor.assumeIsolated {
                    if region.preference == .content { self?.regions.add(region) }
                }
            }
        }
        SyncSetupFeatureFlag().isEnabled = false
        let suite = Self.suite + (mode == .account ? ".new" : ".returning")
        let defaults = UserDefaults(suiteName: suite)!
        if mode != .profile { defaults.removePersistentDomain(forName: suite) }
        let profiles = ProfilesModel(store: ProfileStore(defaults: defaults))
        let accounts = AccountStore(secureStore: InMemorySecureStore())
        if mode != .account {
            Task {
                do {
                    let session = try await LiveJellyfinHomeFixture.configuration()
                    guard session.server.provider == .jellyfin else { throw AppError.invalidResponse }
                    if mode == .seed {
                        let id = UUID().uuidString
                        defaults.set(id, forKey: "fixtureAccount")
                        profiles.setActiveAccountIDs([id], for: profiles.activeProfileID)
                        profiles.markFirstRunProfileSetupComplete()
                        profiles.add(name: "Other")
                        ProfileAppearanceSetupStore().markCompleted(profileID: profiles.activeProfileID)
                        FeatureIntroductionStore().markCompleted(.navigationStyles)
                        FeatureIntroductionStore().markCompleted(.homeLayout)
                        stamp("seededUs")
                        stop()
                    } else {
                        guard profiles.firstRunProfileSetupComplete, profiles.profiles.count == 2,
                              let id = defaults.string(forKey: "fixtureAccount") else { fail(3); return }
                        // Unsigned simulator hosts cannot depend on Keychain entitlements. Restore
                        // the seed's still-authorized session in RAM, before mounting RootView.
                        try accounts.add(Account(id: id, from: session), token: session.accessToken)
                        let state = AppState(accountStore: accounts, profilesModel: profiles,
                                             appAdmissionStore: AppAdmissionStore(defaults: defaults))
                        state.profileFlow.setAutomaticallySignIn(false)
                        stamp("credentialReadyUs")
                        app = state
                    }
                } catch { fail(2) }
            }
            return
        }
        let state = AppState(accountStore: accounts, profilesModel: profiles,
                             appAdmissionStore: AppAdmissionStore(defaults: defaults))
        Task {
            do {
                let creds: Credentials = try await LiveFixtureBroker.read("PLOZZ_JELLYFIN_ONBOARDING_BROKER")
                guard ["https", "http"].contains(creds.baseURL.scheme), creds.baseURL.host != nil,
                      creds.baseURL.user == nil, creds.baseURL.password == nil, creds.baseURL.query == nil,
                      creds.baseURL.fragment == nil, !creds.username.isEmpty, !creds.password.isEmpty
                else { throw AppError.invalidResponse }
                connection = creds
            } catch { fail(4) }
        }
        app = state
    }

    private func us(_ time: CFTimeInterval) -> Int { Int((time * 1_000_000).rounded()) }

    private func stamp(_ key: String) {
        values[key] = us(CACurrentMediaTime())
    }

    private func save() {
        let snapshot = values
        output.async {
            do {
                let url = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask,
                                                      appropriateFor: nil, create: true)
                    .appendingPathComponent("first-frame-\(getpid()).json")
                try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
            } catch { PlozzLog.app.error("First-frame report write failed") }
        }
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        let gap = us(now - (previous ?? origin))
        values["maxCallbackGapUs"] = max(values["maxCallbackGapUs"] ?? 0, gap)
        previous = now
        guard now - origin < 120 else { fail(5); return }
        guard let app, let window = marker?.window, window.isKeyWindow else { return }
        let focus = UIFocusSystem.focusSystem(for: window)?.focusedItem
        if !started {
            // LaunchView has no focus target. Wait for the real chooser/picker, not a launch timer.
            guard focus != nil else { return }
            switch mode {
            case .account:
                guard case .onboarding(.selectingServer, false) = app.state, connection != nil else { return }
            case .profile:
                guard app.state == .ready, app.profileFlow.isChoosingProfile else { return }
            case .seed: return
            }
            if reference == nil {
                reference = link.targetTimestamp
                values["referenceTargetUs"] = us(link.targetTimestamp)
                marker?.mark(0, .yellow)
                save()
                return
            }
            // Keep the pre-auth reference visible in a lower-frame-rate external recording.
            guard let reference, link.timestamp >= reference + 0.1 else { return }
            if hold {
                guard now >= nextGateCheck else { return }
                nextGateCheck = now + 0.1
                let go = URL.cachesDirectory.appendingPathComponent("first-frame-\(getpid()).go")
                guard FileManager.default.fileExists(atPath: go.path) else { return }
                try? FileManager.default.removeItem(at: go)
            }
            started = true
            stamp("gateUs")
            marker?.mark(1, .magenta)
            if mode == .profile {
                app.profileFlow.selectProfileFromPicker(to: ProfileStore.defaultProfileID)
                guard app.isActiveProfileAuthorized, !app.profileFlow.isPresentingProfileSelection else {
                    fail(6); return
                }
                stamp("profileAuthorizedUs")
                marker?.mark(2, .orange)
                save()
            } else if let creds = connection {
                connection = nil
                Task { await authenticate(creds, app: app) }
            }
            return
        }
        if values["libraryRouteUs"] != nil || values["profileAuthorizedUs"] != nil {
            if values["firstCallbackUs"] == nil {
                values["firstCallbackUs"] = us(now)
                values["firstCallbackTargetUs"] = us(link.targetTimestamp)
                values["transitionCallbackGapUs"] = gap
                marker?.mark(3, .cyan)
                save()
            }
            if mode == .account {
                if (focus as? any UIAccessibilityIdentification)?.accessibilityIdentifier == "library-selection-continue" {
                    stamp("libraryFocusUs")
                    marker?.mark(5, .white)
                    stop()
                } else if us(now) - (values["firstCallbackUs"] ?? us(now)) >= 3_000_000 {
                    stop() // AX identifier propagation is optional; the recording is authoritative.
                }
                return
            }
            guard MainThreadStallProbe.context == "home" else { return }
            if values["homeContextUs"] == nil { stamp("homeContextUs"); save() }
            for region in regions.allObjects where region.preference == .content && region.window === window {
                guard isVisible(region, in: window) else { continue }
                if values["contentRegionUs"] == nil {
                    stamp("contentRegionUs")
                    marker?.mark(4, .green)
                    save()
                }
                if NativeFocusRegion.contains(focus, in: region) {
                    stamp("contentFocusUs")
                    marker?.mark(5, .white)
                    stop()
                    return
                }
            }
            if let content = values["contentRegionUs"], us(now) - content >= 3_000_000 { stop() }
        }
    }

    private func authenticate(_ creds: Credentials, app: AppState) async {
        do {
            let server = MediaServer(id: "measurement", name: "Jellyfin", baseURL: creds.baseURL, provider: .jellyfin)
            let service = PasswordSignInService(server: server, deviceID: app.accountsProviders.deviceID)
            stamp("authSubmitUs")
            save()
            let session = try await service.signIn(username: creds.username, password: creds.password)
            guard !finished else { return }
            stamp("authSuccessUs")
            marker?.mark(2, .orange)
            // The reducer accepts an authenticated session from the chooser. Deliver it directly
            // to AuthView's production success handler, without putting a Quick Connect code on camera.
            guard app.didAuthenticate(session), case .onboarding(.selectLibraries, _) = app.state
            else { fail(7); return }
            stamp("libraryRouteUs")
            save()
        } catch { fail(8) }
    }

    private func isVisible(_ view: UIView, in window: UIWindow) -> Bool {
        var rect = view.convert(view.bounds, to: window).intersection(window.bounds)
        var ancestor: UIView? = view
        while let current = ancestor {
            if current.isHidden || current.alpha < 0.01 { return false }
            if current.clipsToBounds { rect = rect.intersection(current.convert(current.bounds, to: window)) }
            ancestor = current.superview
        }
        return !rect.isEmpty
    }

    private func fail(_ code: Int) {
        values["failure"] = code
        marker?.mark(0, .red)
        stop()
    }

    private func stop() {
        finished = true
        display?.invalidate()
        display = nil
        if let regionObserver { NotificationCenter.default.removeObserver(regionObserver) }
        stamp("endUs")
        save()
    }
}

/// Independent bits: if two changes coalesce into one presented frame, neither edge is overwritten.
fileprivate final class FirstFrameMarker: UIView {
    private let bits = (0..<6).map { _ in CALayer() }
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        isUserInteractionEnabled = false
        for bit in bits { layer.addSublayer(bit) }
        mark(0, .blue)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layoutSubviews() {
        super.layoutSubviews()
        let w = bounds.width / CGFloat(bits.count)
        for (i, bit) in bits.enumerated() {
            bit.frame = CGRect(x: CGFloat(i) * w, y: 0, width: w, height: bounds.height)
        }
    }
    func mark(_ index: Int, _ color: UIColor) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bits[index].backgroundColor = color.cgColor
        CATransaction.commit()
    }
}

struct SignInFirstFrameFixture: View {
    @ObservedObject var run: SignInFirstFrameRun

    var body: some View {
        Group {
            if let app = run.app { RootView(appState: app) } else { Color.black }
        }
        .overlay(alignment: .topTrailing) {
            Marker(run: run).frame(width: 120, height: 20).allowsHitTesting(false).accessibilityHidden(true)
        }
    }

    private struct Marker: UIViewRepresentable {
        let run: SignInFirstFrameRun
        func makeUIView(context: Context) -> UIView {
            let view = FirstFrameMarker(frame: .zero)
            run.marker = view
            return view
        }
        func updateUIView(_ uiView: UIView, context: Context) {}
    }
}
