import CoreModels
import CoreUI
@testable import FeaturePlayback
import SwiftUI
import UIKit
import FeatureHomeCore
#if os(iOS)
import FeatureAuth
@testable import AppShelliOS
#else
@testable import FeatureHome
#endif

/// Real production views with deterministic, local-only disc data for visual review.
@MainActor
struct DiscReviewFixture: View {
    @State private var fixture = DiscReviewState()
    #if os(iOS)
    @State private var keyboardActions = PlozziOSPlayerKeyboardActions()
    #endif

    var body: some View {
        Group {
            if fixture.scenario == "detail-atlas" { AtlasRoot() } else if fixture.scenario.hasPrefix("detail") {
                DiscReviewDetail(item: fixture.item, isHome: fixture.scenario == "detail-home-resume")
                .environment(\.discPlaybackDefault,
                              fixture.scenario == "detail-menu-default" ? .openMenu : .playVideo)
            } else {
                player
            }
        }
        .background(.black)
        .environment(\.themePalette, .dark)
        .environment(\.colorScheme, .dark)
        .environment(\.locale, Locale(identifier: "en_US"))
        .preferredColorScheme(.dark)
    }

    @MainActor
    private struct DiscReviewDetail: View {
        let item: MediaItem
        let isHome: Bool
        @State private var trailer = HeroTrailerController()
        #if os(tvOS)
        @State private var background = HeroBackgroundSettingsModel(store: InMemoryHeroBackgroundSettingsStore())

        var body: some View {
            DetailHeroView(
                item: item, spoilerSettings: .default, playTitle: "Play", onPlay: {}, onPlayDisc: { _ in }
            )
            .environment(trailer)
            .environment(background)
        }
        #else
        @State private var appModel: PlozziOSAppModel = {
            SyncSetupFeatureFlag().isEnabled = false
            let defaults = UserDefaults(suiteName: "DiscReview.\(UUID().uuidString)")!
            let model = PlozziOSAppModel(
                accountStore: AccountStore(secureStore: InMemorySecureStore()),
                profileStore: ProfileStore(defaults: defaults)
            )
            model.settings.heroBackground.settings.detailMode = .off
            return model
        }()
        @State private var sidebar = PlozziOSSidebarGeometryModel()
        @State private var actions = DiscReviewActions()
        @State private var pendingResume: MediaItem?

        var body: some View {
            NavigationStack {
                ScrollView {
                    if isHome {
                        PlozziOSHomeHeroForeground(
                            item: item, detailItem: item, watchlistItem: item,
                            presentation: HeroPresentation(item: item, artworkStyle: .landscape, surface: .home),
                            style: UIDevice.current.userInterfaceIdiom == .phone ? .compactPortrait : .landscape,
                            onPlay: { pendingResume = $0 }
                        )
                        .padding(24)
                        .frame(maxWidth: .infinity, minHeight: 600, alignment: .bottomLeading)
                    } else {
                        PlozziOSDetailHeroSection(
                            item: item, backdropItem: item, playableItem: item, sources: [],
                            selectedSourceAccountID: nil, versions: item.versions, selectedVersionID: nil,
                            onSelectSource: { _ in }, onSelectVersion: { _ in }, actionHandler: actions,
                            onPlay: { selected, _ in pendingResume = selected }
                        )
                    }
                }
            }
            .resumePrompt(item: $pendingResume, anchorID: isHome ? item.id : "play") { _, _ in
                pendingResume = nil
            }
            .environment(appModel)
            .environment(trailer)
            .environment(sidebar)
            .environment(\.plozzMetrics, .touch(density: .standard))
        }
        #endif
    }

    @MainActor
    private final class DiscReviewActions: MediaItemActionHandling {
        func actions(for item: MediaItem, context: MediaItemActionContext) -> [MediaItemAction] {
            [.addToWatchlist, .markWatched]
        }
        func perform(_ action: MediaItemAction, on item: MediaItem, context: MediaItemActionContext) {}
    }

    private var player: some View {
        ZStack {
            #if os(tvOS)
            PlayerView(viewModel: fixture.player)
            #else
            PlayerView(viewModel: fixture.player, showsSharedControls: false, showsLoadingOverlay: false)
            if fixture.player.phase == .ready, !fixture.player.showBringUpSpinner,
               fixture.engine.discMenu?.presentsMenu != true {
                PlozziOSPlayerControlsOverlay(
                    viewModel: fixture.player, keyboardActions: keyboardActions,
                    hasVersions: false, versionsPresented: false,
                    onShowVersions: {}, onClose: {}
                )
            } else {
                VStack {
                    HStack {
                        PlozziOSPlayerCloseButton(action: {})
                        Spacer()
                    }
                    Spacer()
                }
                .foregroundStyle(.white)
                .modifier(PlayerTouchChromePadding())
            }
            PlayerLoadingOverlay(viewModel: fixture.player, discMenuRequested: fixture.opensMenu)
            #endif
        }
        .onChange(of: fixture.player.phase) { _, phase in
            if phase == .ready, fixture.scenario == "videos" { fixture.player.showsDiscVideos = true }
        }
    }
}

@MainActor
private final class DiscReviewState {
    let scenario: String
    let opensMenu: Bool
    let item: MediaItem
    let engine: DiscReviewEngine
    let player: PlayerViewModel

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        let index = arguments.firstIndex(of: "--disc-review-fixture")
        scenario = index.flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil } ?? "menu"
        opensMenu = ["menu", "failure", "loading", "notice"].contains(scenario)
        var version = MediaVersion(id: "disc", container: "bdmv")
        version.discMenuAvailability = scenario == "detail-unavailable" ? .unavailable(.unsupportedRuntime) : .unknown
        item = MediaItem(id: "disc-review", title: "Original disc fixture", kind: .movie,
                         runtime: 7200, resumePosition: scenario.hasSuffix("-resume") ? 600 : nil,
                         allowsTitleBasedMetadataMatching: false, versions: [version])
        engine = DiscReviewEngine(scenario: scenario, opensMenu: opensMenu)
        var settings = PlaybackSettings.default
        settings.discPlayback = opensMenu ? .openMenu : .playVideo
        settings.fadeOnDynamicRangeChange = false
        settings.fadeOnFrameRateChange = false
        settings.useCommunityMarkers = false
        let engine = engine
        player = PlayerViewModel(
            provider: DiscReviewProvider(movie: item), itemID: item.id,
            playbackSettings: settings,
            engineFactory: .init(makeNative: { _ in engine }, makePlozzigen: { engine })
        )
    }
}

@MainActor
private final class DiscReviewEngine: VideoEngine {
    let displayName = "Local visual-review fixture"
    let status: VideoEngineStatus = .ready
    var isPaused = true
    let hasPresentedVideoFrame: Bool
    let currentTime: TimeInterval = 720
    let duration: TimeInterval = 7200
    let furthestObservedPosition: TimeInterval = 720
    let audioTracks: [MediaTrack] = []
    let subtitleTracks: [MediaTrack] = []
    var discMenu: DiscMenuPlaybackState?
    var onProgress: (@MainActor () -> Void)?
    var onFailure: (@MainActor (AppError) -> Void)?
    var onEnded: (@MainActor () -> Void)?
    var onTracksChanged: (@MainActor () -> Void)?
    var onProbedSourceFactsChanged: (@MainActor (EngineProbedSourceFacts) -> Void)?
    var onSubtitleCues: (@MainActor ([SubtitleCue]) -> Void)?
    var onSecondarySubtitleCues: (@MainActor ([SubtitleCue]) -> Void)?
    private let surface = UIView()

    init(scenario: String, opensMenu: Bool) {
        hasPresentedVideoFrame = scenario != "loading"
        surface.backgroundColor = UIColor(red: 0.035, green: 0.07, blue: 0.1, alpha: 1)
        if opensMenu {
            let state = DiscMenuPlaybackState()
            state.isActive = true
            state.isOpening = scenario == "loading"
            state.hasPresentedVideoFrame = hasPresentedVideoFrame
            state.isFirstPlay = scenario == "loading"
            state.isMenuVisible = scenario == "menu"
            if scenario == "failure" { state.failure = "This disc's menu format is not supported" }
            if scenario == "notice" { state.audioSelectionUnavailable = true }
            discMenu = state
        }
    }

    func load(request: PlaybackRequest, startPosition: TimeInterval) async {}
    func play() { isPaused = false }
    func pause() { isPaused = true }
    func seek(to seconds: TimeInterval) async {}
    func stop() {}
    func selectAudioTrack(_ track: MediaTrack?) {}
    func selectSubtitleTrack(_ track: MediaTrack?) {}
    func makeVideoOutputView() -> UIView { surface }
    func discVideos() async throws -> [DiscVideo] {
        [
            .init(playlist: 800, duration: 7200, chapterCount: 18),
            .init(playlist: 801, duration: 7440, chapterCount: 19),
            .init(playlist: 12, duration: 840, chapterCount: 3)
        ]
    }
}

private struct DiscReviewProvider: MediaProvider {
    let movie: MediaItem
    let kind = ProviderKind.jellyfin
    let session = UserSession(
        server: .init(id: "fixture", name: "Fixture", baseURL: URL(string: "https://fixture.invalid")!,
                      provider: .jellyfin),
        userID: "fixture", userName: "Fixture", deviceID: "fixture", accessToken: "fixture"
    )
    func libraries() async throws -> [MediaLibrary] { [] }
    func continueWatching(limit: Int) async throws -> [MediaItem] { [] }
    func latest(limit: Int) async throws -> [MediaItem] { [] }
    func item(id: String) async throws -> MediaItem { movie }
    func children(of itemID: String) async throws -> [MediaItem] { [] }
    func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
    func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        .init(items: [], startIndex: page.startIndex, totalCount: 0)
    }
    func playbackInfo(for itemID: String) async throws -> PlaybackRequest {
        let anchor = try NetworkFileLocator(
            accountID: "fixture", sourceID: "fixture", credentialRevision: CredentialRevision(),
            relativePath: "Movie/BDMV/index.bdmv",
            representation: .init(size: 40, identity: .init(kind: .strongETag, value: "\"index\""),
                                  consistency: .changeDetecting),
            formatHint: .init(container: "bdmv")
        )
        var request = PlaybackRequest(item: movie, streamURL: URL(fileURLWithPath: "/fixture/BDMV/index.bdmv"))
        request.playbackSource = .networkDisc(try NetworkDiscLocator(
            anchor: anchor, files: [.init(path: "BDMV/index.bdmv", locator: anchor)]
        ))
        return request
    }
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {}
    func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
}

@testable import FeatureSettings
import AppRuntime
import CoreNetworking
import CoreTrackerAuth
import SimklService
import WetrakrService
import TraktService
import Observation
@testable import PublicMetaDBService
private struct AtlasRoot: View {
    @State var data = AtlasModel()
    @State var reviewed: TrackerHistoryImportSession?
    @State var exportReady=false
    let mode = UserDefaults.standard.string(forKey:"AtlasPage") ?? "comparison"
    @ViewBuilder var body: some View {
        NavigationStack {
            switch mode {
            case "comparison": TrackerHistoryImportView(makeSession: data.makeSession)
            case "sync": if let reviewed, let sync = reviewed.ongoingSync { TrackerHistorySyncSettingsView(session: reviewed, sync: sync) }
            case "trakt-export": if exportReady { TraktHistoryExportView(service:data.trakt) }
            case "simkl-export": if exportReady { SimklHistoryExportView(service:data.simkl) }
            case "wetrakr-export": if exportReady { WetrakrHistoryExportView(service:data.wetrakr) }
            #if os(iOS)
            case "trackers":
                SettingsPageList {
                    NavigationLink("Trackers") {
                        AtlasPublic(mode: "connected", data: data)
                            .navigationTitle("Trackers")
                    }
                }
                .navigationTitle("Settings")
            #else
            case "trackers": AtlasExtra(mode: mode, data: data)
            #endif
            case "anilist-export","mal-export","onboarding": AtlasExtra(mode:mode,data:data)
            default: AtlasPublic(mode:mode,data:data)
            }
        }.preferredColorScheme(.dark).environment(\.themePalette,.dark).task {
            if mode == "sync" { let session = data.makeSession(); await session.compare(); reviewed = session }
            if mode == "trakt-export" { await data.trakt.refreshStatus() }
            if mode == "simkl-export" { await data.simkl.refreshStatus() }
            if mode == "wetrakr-export" { await data.wetrakr.refreshStatus() }
            exportReady=true
        }
    }
}

import LastFmService
import CoreSecureStore
private final class AtlasCreds: PublicMetaDBCredentialStoring, @unchecked Sendable {
    let lock = NSLock()
    private var value: PublicMetaDBCredentials?
    func load(namespace:String?) -> PublicMetaDBCredentials? { lock.withLock { value } }
    func save(_ credentials:PublicMetaDBCredentials, namespace:String?) throws { lock.withLock { value = credentials } }
    func clear(namespace:String?) throws { lock.withLock { value = nil } }
}
private struct AtlasHTTP: HTTPClient {
    static let movie = #"{"tmdb_id":82501,"media_type":"movie"}"#
    static let show = #"{"tmdb_id":82502,"media_type":"tv"}"#
    static let watch = #"{"id":"harbor","tmdb_id":82501,"media_type":"movie","watched_at":"2026-10-24T20:30:00Z"}"#
    static let resume = #"{"id":"lantern","tmdb_id":82501,"media_type":"movie","position_ms":1500000,"runtime_ms":6000000}"#
    static let dropped = #"{"id":"north","tmdb_id":82502,"media_type":"tv"}"#
    static let list = #"{"id":"weekend","name":"Weekend matinees","description":"Quiet adventures for a rainy afternoon.","slug":"weekend-matinees","is_public":false,"type":"watchlist","contributor":"Mara"}"#
    static let publicList = #"{"id":"harbor-lights","name":"Harbor lights","slug":"harbor-lights","is_public":true,"type":"custom","contributor":"Theo"}"#
    static let rating = #"{"id":"score","tmdb_id":82501,"media_type":"movie","label":"Atmosphere","score":85,"contributor":"Mara"}"#
    static let pick = #"{"id":"shore","slug":"shore","name":"Coastal mysteries","description":"Slow-burn stories along the shore.","seed_type":"movie","exclude_watched":true,"exclude_watchlist":false}"#
    static func decode<T:Decodable>(_ json:String,_ t:T.Type)->T { try! JSONDecoder().decode(t,from:Data(json.utf8)) }
    func send(_ endpoint:Endpoint,baseURL:URL) async throws -> (Data,HTTPURLResponse) {
        let p=endpoint.path, q=Dictionary(endpoint.queryItems.compactMap { i in i.value.map { (i.name,$0) } },uniquingKeysWith:{a,_ in a})
        let size=max(1,Int(q["perPage"] ?? "100") ?? 100)
        func page(_ items:[String],_ extra:String="")->String { let n=items.count; return "{\"items\":[\(items.prefix(size).joined(separator:","))],\"total\":\(n),\"page\":1,\"perPage\":\(size),\"totalPages\":\((n+size-1)/size)\(extra)}" }
        let json:String; var status=200
        if p.contains("/pairing") {
            if p.hasSuffix("/pairing") { status=201; json="{\"code\":\"CEDARARC\",\"expiresAt\":\(Int(Date().addingTimeInterval(600).timeIntervalSince1970)*1000)}" }
            else { status=202; json="{}" }
        } else {
            guard endpoint.method == .get else { throw AppError.invalidResponse }
            if p.hasSuffix("/lists") { json=page([Self.list,Self.publicList]) }
            else if p.contains("/lists/") { let l=p.contains("/u/") || p.contains("harbor-lights") ? Self.publicList:Self.list; json=page([#"{"id":"item","tmdb_id":82501,"media_type":"movie"}"#],",\"list\":\(l)") }
            else if p.hasSuffix("/watched") { json=page([Self.watch]) }
            else if p.hasSuffix("/resume") { json=page([Self.resume]) }
            else if p.hasSuffix("/dropped") { json=page([Self.dropped]) }
            else if p.hasSuffix("/catalogs") { json="{\"items\":[\(Self.pick)],\"total\":1}" }
            else if p.contains("/catalogs/") { json=page([#"{"tmdb_id":82501,"media_type":"movie","title":"The Last Lantern","year":"2024","reasons":[]}"#],",\"cached\":true,\"catalog\":\(Self.pick)") }
            else if p.hasSuffix("/votes") { json = #"{"items":[],"total":0,"summary":{"upvotes":0,"downvotes":0,"score":0},"userVote":null}"# }
            else if p.hasSuffix("/ratings") { json="{\"items\":[\(Self.rating)],\"total\":1,\"average\":85}" }
            else if p.hasSuffix("/episode-ratings/batch") { json = #"{"tmdb_id":82502,"media_type":"tv","season":1,"episodes":[{"episode":1,"total":1,"ratings":[{"id":"pilot","tmdb_id":82502,"media_type":"tv","season":1,"episode":1,"label":"Overall","score":85,"contributor":"Mara"}],"aggregates":{"overall":{"label":"overall","count":1,"average":85}}}],"totalRatings":1,"episodeCount":1,"seasonAverage":85}"# }
            else if p.hasSuffix("/mappings") { json = #"{"tmdb_id":82501,"media_type":"movie","mappings":{"imdb":[{"id":"map","value":"tt4082150","contributor":"Theo"}]},"total":1}"# }
            else if p.hasSuffix("/lookup") { json="{\"results\":[\(Self.movie)],\"total\":1}" }
            else if p.contains("anime") { json = #"{"tmdb_id":82502,"seasons":[{"pmdb_id":"tide","season_number":1,"season_name":"Spring Tide","source":"user","contributor":"Mara","votes":0,"recommended":true,"chunks":[{"id":"c1","tmdb_season":1,"tmdb_episode_start":1,"tmdb_episode_end":8}]}],"total":1}"# }
            else if p.contains("2.0") { json = ##"{"recenttracks":{"track":[{"name":"Eastbound Ferry","artist":{"#text":"Signal House"},"album":{"#text":"Harbor Sessions"},"date":{"uts":"1792873800"}}],"@attr":{"user":"Mara","page":"1","perPage":"50","totalPages":"1","total":"1"}}}"## }
            else { throw AppError.invalidResponse }
        }
        return (Data(json.utf8),HTTPURLResponse(url:baseURL,statusCode:status,httpVersion:nil,headerFields:nil)!)
    }
}
@MainActor private struct AtlasPublic: View {
    let mode:String
    let data:AtlasModel
    @State private var service: PublicMetaDBService
    init(mode: String, data: AtlasModel) {
        self.mode = mode
        self.data = data
        let trackingPage = ["connected", "disconnected", "account", "reporting", "reporting-on"].contains(mode)
        _service = State(initialValue: PublicMetaDBService(
            accountToolsEnabled: !trackingPage, credentials: AtlasCreds(), http: AtlasHTTP(),
            defaults: UserDefaults(suiteName: "local-only.tracker-atlas")!,
            watchlistReceiptStore: try? DurableLocalStateStore(secureStore: InMemorySecureStore())
        ))
    }
    @State private var last = LastFmService(config:.init(apiKey:"not-networked",sharedSecret:"not-networked"),http:AtlasHTTP(),tokenStore:InMemoryLastFmTokenStore(tokens:.init(sessionKey:"not-networked",username:"Mara")))
    @State private var ready=false
    let movie = try! PublicMetaDB.Content(tmdbID:82501,mediaType:.movie)
    let show = try! PublicMetaDB.Content(tmdbID:82502,mediaType:.tv)
    let episode = try! PublicMetaDB.Content(tmdbID:82502,mediaType:.tv,season:1,episode:1)
    let savedList=AtlasHTTP.decode(AtlasHTTP.list,PublicMetaDB.List.self)
    @ViewBuilder var body: some View {
        Group { if ready { page } else { ProgressView() } }.environment(\.publicMetaDBCatalogService,service).task {
            service.makeHistoryExportSource={ data.makeExportSource() }
            service.resolveCatalogItem={ c in MediaItem(id:String(c.tmdbID),title:c.mediaType == .movie ? "The Last Lantern":"The Mariner's Almanac",kind:c.mediaType == .movie ? .movie:.series,providerIDs:["Tmdb":String(c.tmdbID)]) }
            if mode != "disconnected" { await service.connect(key:"pm-"+String(repeating:"9",count:60)) }
            if mode == "reporting-on",let id=service.connectionID { try? service.enablePlayback(expectedConnectionID:id) }
            if mode == "watchlist-on",let id=service.connectionID { try? await service.enableWatchlist(savedList,expectedConnectionID:id) }
            if mode == "lastfm" { await last.refreshStatus() }
            ready=true
        }
    }
    @ViewBuilder var page: some View {
        switch mode {
        case "connected","disconnected","account": PublicMetaDBPage {
            #if os(iOS)
            PublicMetaDBSettingsContent(service:service,makeHistoryImport:data.makeSession)
            #else
            SettingsSectionGroup(verbatim:"PublicMetaDB") { PublicMetaDBSettingsContent(service:service,makeHistoryImport:data.makeSession) }
            #endif
        }
        case "reporting","reporting-on": PublicMetaDBPlaybackSettingsView(service:service)
        case "watchlist","watchlist-on": PublicMetaDBWatchlistSettingsView(service:service)
        case "create-list": PublicMetaDBCreateListView(service:service)
        case "open-list": PublicMetaDBOpenListView(service:service)
        case "list-detail": PublicMetaDBOwnedListView(service:service,list:savedList)
        case "add-to-list": PublicMetaDBAddToListView(service:service,content:movie)
        case "movie","show","episode": PublicMetaDBContentView(service:service,content:mode == "show" ? show : mode == "movie" ? movie:episode,title:mode == "movie" ? "The Last Lantern":"The Mariner's Almanac")
        case "drop-record": PublicMetaDBHistoryRecordView(service:service,action:.drop(show))
        case "new-play": PublicMetaDBHistoryDateView(service:service,content:movie)
        case "bulk": PublicMetaDBBulkHistoryView(service:service)
        case "ratings": PublicMetaDBContentRatingsView(service:service,content:movie)
        case "season": PublicMetaDBSeasonRatingsView(service:service,tmdbID:82502,initialSeason:1)
        case "anime": PublicMetaDBAnimeMappingsView(service:service,tmdbID:82502)
        case "mappings": PublicMetaDBMappingsView(service:service,content:movie)
        case "lookup": PublicMetaDBMappingLookupView(service:service)
        case "public-export": PublicMetaDBHistoryExportView(service:service)
        case "lastfm": LastFmListeningHistoryView(service:last)
        default: EmptyView()
        }
    }
}

import AniListService
import MALService
#if os(tvOS)
@testable import AppShell
#endif
private struct AtlasAnimeHTTP: HTTPClient {
    func send(_ endpoint:Endpoint,baseURL:URL) async throws -> (Data,HTTPURLResponse) {
        let body:String
        if endpoint.method == .post, endpoint.path.isEmpty, let raw=endpoint.body,
           let obj=try JSONSerialization.jsonObject(with:raw) as? [String:Any],
           let query=obj["query"] as? String, query.contains("Viewer"), !query.contains("mutation") {
            body = #"{"data":{"Viewer":{"id":37,"name":"Mara"},"Media":{"id":601,"idMal":701,"type":"ANIME","format":"MOVIE","mediaListEntry":null},"Page":{"pageInfo":{"currentPage":1,"perPage":50,"hasNextPage":false},"mediaList":[]}}}"#
        } else if endpoint.method == .get && endpoint.path.hasSuffix("/users/@me") { body = #"{"id":37,"name":"Mara"}"# }
        else if endpoint.method == .get && endpoint.path.hasSuffix("/animelist") { body = #"{"data":[],"paging":{}}"# }
        else if endpoint.method == .get && endpoint.path.hasSuffix("/anime/701") { body = #"{"id":701,"title":"The Last Lantern","media_type":"movie","my_list_status":null}"# }
        else { throw AppError.invalidResponse }
        return (Data(body.utf8),HTTPURLResponse(url:baseURL,statusCode:200,httpVersion:nil,headerFields:nil)!)
    }
}
@MainActor private struct AtlasExtra:View {
    let mode:String, data:AtlasModel
    @State var ani=AniListService(config:.init(clientID:"local"),http:AtlasAnimeHTTP(),tokenStore:InMemoryAniListTokenStore(tokens:.init(accessToken:"local")),namespace:"fixture-profile")
    @State var mal=MALService(config:.init(clientID:"local"),http:AtlasAnimeHTTP(),tokenStore:InMemoryMALTokenStore(tokens:.init(accessToken:"local",refreshToken:"local",expiresAt:.distantFuture)),namespace:"fixture-profile")
    @State var playback=PlaybackSettingsModel(store:PlaybackSettingsStore(defaults:UserDefaults(suiteName:"local-only.tracker-atlas")!))
    @State var last=LastFmService(config:.init(apiKey:"not-networked",sharedSecret:"not-networked"),http:AtlasHTTP(),tokenStore:InMemoryLastFmTokenStore(tokens:.init(sessionKey:"not-networked",username:"Mara")))
    @State var pub=PublicMetaDBService(accountToolsEnabled:false,credentials:AtlasCreds(),http:AtlasHTTP(),defaults:UserDefaults(suiteName:"local-only.tracker-atlas")!)
    #if os(tvOS)
    @State private var trackerNavigation = SettingsPageNavigation<Int>()
    #endif
    @State var ready=false
    @ViewBuilder var body:some View {
        Group {
            if !ready { ProgressView() }
            else if mode=="anilist-export" { AniListHistoryExportView(service:ani) }
            else if mode=="mal-export" { MALHistoryExportView(service:mal) }
            #if os(tvOS)
            elseViewTV
            #endif
        }.task {
            guard !ready else {return}
            let source=data.makeExportSource()
            if let store=try? DurableLocalStateStore(secureStore:InMemorySecureStore()) {
                ani.makeHistoryExport = {try ani.makeHistoryExportSession(source:source,store:store)}
                mal.makeHistoryExport = {try mal.makeHistoryExportSession(source:source,store:store)}
            }
            await ani.refreshStatus(); await mal.refreshStatus(); await last.refreshStatus()
            if mode=="trackers" { await pub.connect(key:"pm-"+String(repeating:"9",count:60)); await data.trakt.refreshStatus();await data.simkl.refreshStatus();await data.wetrakr.refreshStatus() }
            ready=true
        }
    }
    #if os(tvOS)
    @ViewBuilder var elseViewTV:some View {
        if ready && mode=="onboarding" { AddAccountView(deviceID:"local",canReturnToApp:false,onMediaBrowserServerSelected:{_ in},onPlexAuthenticated:{_ in},onCancel:{},onSetUpFromAnotherDevice:{}) }
        if ready && mode == "trackers" {
            SettingsPageStack(navigation: trackerNavigation, pageWidth: SettingsFormMetrics.pageWidth, onRootBack: nil) {
                IntegrationsDetailView(
                    trakt: data.trakt, simkl: data.simkl, wetrakr: data.wetrakr, publicMetaDB: pub,
                    makePublicMetaDBHistoryImport: data.makeSession, makeTraktHistoryImport: data.makeSession,
                    makeSimklHistoryImport: data.makeSession, makeWetrakrHistoryImport: data.makeSession,
                    makeAniListHistoryImport: data.makeSession, makeMALHistoryImport: data.makeSession,
                    anilist: ani, mal: mal, lastfm: last, playback: playback, serverCount: 2
                )
            } destination: { _ in EmptyView() }
            .safeAreaPadding(.top, 36)
            .ignoresSafeArea(.container, edges: .vertical)
            .environment(\.settingsInWorkspace, true)
            .background(ThemePalette.dark.settingsBackground)
        }
    }
    #endif
}

@MainActor @Observable
private final class AtlasModel {
    let providers: [AtlasSourceProvider]
    let scope: WatchMutationServerScope
    let index: IdentityIndexSnapshot
    var authorized = true
    var trackerReads = 0
    var trackerWrites = 0
    var newPlay = 0
    var exported = false
    var storageFailed = false
    private let arguments = ProcessInfo.processInfo.arguments

    @ObservationIgnored private let outbox = InMemoryWatchMutationStore()
    @ObservationIgnored private var syncStore: DurableLocalStateStore?
    @ObservationIgnored lazy var wetrakr: WetrakrService = {
        let http = WetrakrExportFixtureHTTP(
            read: { [weak self] in
                guard let self else { throw CancellationError() }
                self.trackerReads += 1
                return self.exported
            },
            wrote: { [weak self] in
                guard let self else { throw CancellationError() }
                self.trackerWrites += 1
                self.exported = true
            }
        )
        let service = WetrakrService(
            config: .init(clientID: "native-export-fixture"), http: http,
            tokenStore: InMemoryTrackerTokenStore(tokens: .init(
                accessToken: "fixture", refreshToken: "fixture", expiresAt: .distantFuture
            )), namespace: scope.profileID
        )
        service.makeHistoryExport = { [weak self, weak service] in
            guard let self, let service else { throw CancellationError() }
            guard let store = self.syncStore else { throw DurableLocalStateError.storageUnavailable }
            return try service.makeHistoryExportSession(source: self.makeExportSource(), store: store)
        }
        return service
    }()
    @ObservationIgnored lazy var simkl: SimklService = {
        let http = SimklExportFixtureHTTP(
            read: { [weak self] in
                guard let self else { throw CancellationError() }
                self.trackerReads += 1
                return self.exported
            },
            wrote: { [weak self] in
                guard let self else { throw CancellationError() }
                self.trackerWrites += 1
                self.exported = true
            }
        )
        let service = SimklService(
            config: .init(clientID: "native-export-fixture"), http: http,
            tokenStore: InMemorySimklTokenStore(tokens: .init(accessToken: "fixture")), namespace: scope.profileID
        )
        service.makeHistoryExport = { [weak self, weak service] in
            guard let self, let service else { throw CancellationError() }
            guard let store = self.syncStore else { throw DurableLocalStateError.storageUnavailable }
            return try service.makeHistoryExportSession(source: self.makeExportSource(), store: store)
        }
        return service
    }()
    @ObservationIgnored lazy var trakt: TraktService = {
        let http = TraktExportFixtureHTTP(
            read: { [weak self] in
                guard let self else { throw CancellationError() }
                self.trackerReads += 1
                return self.exported
            },
            wrote: { [weak self] in
                guard let self else { throw CancellationError() }
                self.trackerWrites += 1
                self.exported = true
            }
        )
        let service = TraktService(
            config: .init(clientID: "native-export-fixture"), http: http,
            tokenStore: InMemoryTraktTokenStore(tokens: .init(
                accessToken: "fixture", refreshToken: "fixture", expiresAt: .distantFuture
            )), namespace: scope.profileID
        )
        service.makeHistoryExport = { [weak self, weak service] in
            guard let self, let service else { throw CancellationError() }
            guard let store = self.syncStore else { throw DurableLocalStateError.storageUnavailable }
            return try service.makeHistoryExportSession(source: self.makeExportSource(), store: store)
        }
        return service
    }()
    @ObservationIgnored private lazy var sync: TrackerHistorySyncController? = {
        guard let syncStore else { return nil }
        return TrackerHistorySyncController(
            identity: .init(
                trackerID: "publicmetadb", connectionID: "fixture-connection",
                allowsForegroundChecks: !arguments.contains("--history-manual-sync")
            ),
            scope: scope, store: syncStore,
            supportedCategories: arguments.contains("--history-watched-only") ? [.watched] : [.watched, .resume],
            isAuthorized: { [weak self] in self?.authorized ?? false },
            makeSession: { [weak self] scope, allowed in
                guard let self else { throw TrackerHistoryError.scopeChanged }
                return self.makeSession(scope: scope, allowed: allowed)
            }
        )
    }()

    private func makeReconciler() -> WatchStateReconciler {
        let index = self.index
        return WatchStateReconciler(
            store: outbox,
            applier: AppShellWatchMutationApplier(
                isActive: { await self.authorized },
                validateServerScope: { try await self.requireScope($0) },
                resolveProvider: { await self.provider($0) },
                applyTrakt: { _ in try await self.unexpectedTrackerWrite() },
                applySimkl: { _ in try await self.unexpectedTrackerWrite() },
                applyAniList: { _ in try await self.unexpectedTrackerWrite() },
                applyMAL: { _ in try await self.unexpectedTrackerWrite() },
                wetrakrAccountIdentity: { "fixture-wetrakr" },
                applyWetrakr: { _, _, _, _ in try await self.unexpectedTrackerWrite() },
                applyTrackerPlayback: { _ in try await self.unexpectedTrackerWrite() },
                allAccountIDs: { await self.providers.map(\.account.id) },
                indexedSources: { identities, kind, _, _, _ in
                    index.sources(forIdentities: identities, kind: kind)
                },
                indexedAccountIDs: { index.indexedAccountIDs }
            )
        )
    }

    init() {
        var sources = [
            AtlasSourceProvider(kind: .jellyfin, id: "jellyfin", name: "Lantern House", user: "Mara"),
            AtlasSourceProvider(kind: .plex, id: "plex", name: "Northbank Cinema", user: "Theo")
        ]
        if arguments.contains("--history-ongoing-sync"), !arguments.contains("--history-servers-only") {
            sources += [
                .init(kind: .mediaShare, id: "cedar", name: "Cedar Loft", user: "Mara"),
                .init(kind: .mediaShare, id: "mariner", name: "Mariner Archive", user: "Theo")
            ]
        }
        providers = sources
        scope = WatchMutationServerScope(
            profile: .init(id: "fixture-profile", name: "Mara"),
            accounts: providers.map(\.account)
        )
        index = IdentityIndexSnapshot(byIdentity: [
            .external(source: "tmdb", value: "550"): providers.map {
                .init(accountID: $0.account.id, itemID: "movie", providerKind: $0.kind, kind: .movie)
            }
        ])
        do { syncStore = try DurableLocalStateStore(secureStore: AtlasSourceStorage()) }
        catch { storageFailed = true }
    }

    var report: String {
        providers.map {
            "\($0.account.id)=\($0.writes),played=\($0.current.isPlayed),playback=\($0.playbackWrites),resume=\(Int($0.current.resumePosition ?? 0))"
        }.joined(separator: ";") + ";trackers=\(trackerWrites)"
            + (arguments.contains("--history-ongoing-sync")
                ? ";sync=\(sync?.isEnabled ?? false);destinations=\(sync?.grant?.scope.accounts.map(\.accountID).sorted().joined(separator: ",") ?? "");categories=\(sync?.grant?.categories.map(\.rawValue).sorted().joined(separator: ",") ?? "");storageFailed=\(storageFailed)"
                : "")
            + ";reads=\(trackerReads)"
    }

    func makeSession() -> TrackerHistoryImportSession {
        let session = makeSession(scope: scope, allowed: { true })
        if arguments.contains("--history-ongoing-sync") { session.ongoingSync = sync }
        return session
    }

    func makeExportSource() -> TrackerServerHistorySource {
        TrackerServerHistorySource(
            scope: scope, accounts: providers.map {
                .init(id: $0.account.id, serverName: $0.account.server.name, userName: $0.account.userName)
            },
            resolveProvider: {
                guard let provider = self.provider($0) else { throw TrackerHistoryError.scopeChanged }
                return provider
            },
            isAuthorized: { self.authorized }, isPlaying: { _, _ in false }
        )
    }

    func makeExportSession() throws -> TrackerHistoryExportSession<String> {
        guard let syncStore else { throw DurableLocalStateError.storageUnavailable }
        let source = makeExportSource()
        return .init(
            trackerID: "fixture", trackerName: "Fixture", connectionID: "fixture", snapshotConnectionID: "fixture",
            source: source, store: syncStore, preservesWatchDates: false,
            isConnected: { self.authorized }, supports: { $0.kind == .movie },
            readAll: { try self.exportSnapshot() },
            resolve: { _ in "550" },
            readTarget: { _ in try .init(observations: self.exportSnapshot().observations) },
            write: { _, _, _, validate in
                try await validate()
                self.trackerWrites += 1
                self.exported = true
                if self.arguments.contains("--history-lost-write-reply") {
                    throw TrackerHistoryExportError.uncertainWrite
                }
            }
        )
    }

    @MainActor
    private final class WetrakrExportFixtureHTTP: HTTPClient {
        let read: @MainActor () throws -> Bool
        let wrote: @MainActor () throws -> Void
        init(read: @escaping @MainActor () throws -> Bool, wrote: @escaping @MainActor () throws -> Void) {
            self.read = read
            self.wrote = wrote
        }

        func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
            try await sendRaw(endpoint, baseURL: baseURL)
        }

        func sendRaw(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
            guard endpoint.headers["Authorization"] == "Bearer fixture" else { throw AppError.unauthorized }
            let exported = try read()
            var count = 0
            let json: String
            switch (endpoint.method, endpoint.path) {
            case (.get, "/account/settings"):
                json = #"{"id":42,"info":{"username":"fixture"}}"#
            case (.get, "/sync/last_activities"):
                json = #"{"all":"2020-01-02T03:04:05.000Z"}"#
            case (.get, "/media/external/tmdb/550"):
                json = #"{"id":10,"type":"movie"}"#
            case (.get, "/movies/10"):
                json = #"{"id":10,"type":"movie","ids":{"tmdb":550},"interactions":{"user":{"tracking":{"last":{"status":"\#(exported ? "watched" : "none")"}}}}}"#
            case (.get, "/movies/10/tracking/history"):
                json = exported
                    ? #"{"data":[{"tracks":[{"_track_log_id":"play","target":"movie","status":"watched","tracked_at":"2020-01-02T03:04:05.000Z","tracked_at_unknown":true}]}],"meta":{"page":1,"limit":20,"total":1,"totalPages":1}}"#
                    : #"{"data":[],"meta":{"page":1,"limit":20,"total":0,"totalPages":0}}"#
            case (.get, "/sync/tracking/watched/history/movies"):
                count = exported ? 1 : 0
                json = exported
                    ? #"[{"id":10,"type":"movie","ids":{"tmdb":550},"play_id":"play","watched_at":"2020-01-02T03:04:05.000Z","watched_at_unknown":true}]"#
                    : "[]"
            case (.get, let path) where [
                "/sync/tracking/watched/history/episodes", "/sync/tracking/playing/movies", "/sync/tracking/playing/episodes",
                "/sync/tracking/planning/movies", "/sync/tracking/planning/shows",
                "/sync/tracking/dropped/movies", "/sync/tracking/dropped/shows", "/sync/tracking/hold/shows"
            ].contains(path):
                json = "[]"
            case (.post, "/sync/tracking"):
                guard let data = endpoint.body,
                      let body = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      body["allow_rewatch"] as? Bool == false,
                      let movies = body["movies"] as? [[String: Any]], movies.count == 1,
                      movies[0]["id"] as? Int == 10, movies[0]["status"] as? String == "watched",
                      movies[0]["tracked_at_unknown"] as? Bool == true,
                      Set(body.keys) == ["movies", "allow_rewatch"],
                      Set(movies[0].keys) == ["id", "status", "tracked_at_unknown"],
                      endpoint.headers["Idempotency-Key"]?.isEmpty == false else {
                    throw HTTPRequestNotSentError(underlying: .invalidResponse)
                }
                try wrote()
                json = #"{"added":{"plays":[{"id":10,"type":"movie","play_id":"play","watched_at":"2020-01-02T03:04:05.000Z"}]}}"#
            default:
                throw AppError.notFound
            }
            guard let response = HTTPURLResponse(
                url: baseURL, statusCode: 200, httpVersion: nil, headerFields: ["X-Pagination-Item-Count": String(count)]
            ) else { throw AppError.invalidResponse }
            return (Data(json.utf8), response)
        }
    }

    @MainActor
    private final class SimklExportFixtureHTTP: HTTPClient {
        let read: @MainActor () throws -> Bool
        let wrote: @MainActor () throws -> Void
        init(read: @escaping @MainActor () throws -> Bool, wrote: @escaping @MainActor () throws -> Void) {
            self.read = read
            self.wrote = wrote
        }

        func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
            try await sendRaw(endpoint, baseURL: baseURL)
        }

        func sendRaw(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
            let isPublic = ["/redirect", "/movies/10"].contains(endpoint.path)
            guard isPublic ? endpoint.headers["Authorization"] == nil
                : endpoint.headers["Authorization"] == "Bearer fixture" else { throw AppError.unauthorized }
            let exported = try read()
            var status = 200
            var headers: [String: String] = [:]
            let json: String
            switch (endpoint.method, endpoint.path) {
            case (.get, "/users/settings"):
                json = #"{"account":{"id":42},"user":{"name":"fixture"}}"#
            case (.get, "/redirect"):
                guard endpoint.redirectPolicy == .doNotFollow else { throw AppError.invalidResponse }
                status = 301
                headers["Location"] = "https://simkl.com/movies/10/fixture"
                json = ""
            case (.get, "/movies/10"):
                json = #"{"type":"movie","ids":{"simkl":10,"tmdb":550}}"#
            case (.get, "/sync/activities"):
                let stamp = exported ? "2020-01-03T00:00:00Z" : "2020-01-02T00:00:00Z"
                let fields = Dictionary(uniqueKeysWithValues: [
                    "all", "plantowatch", "watching", "completed", "hold", "dropped", "removed_from_list", "playback"
                ].map { ($0, stamp) })
                json = String(decoding: try JSONSerialization.data(withJSONObject: [
                    "all": stamp, "movies": fields, "tv_shows": fields, "anime": fields
                ]), as: UTF8.self)
            case (.get, "/sync/all-items/movies"):
                json = exported
                    ? #"{"movies":[{"status":"completed","last_watched_at":"1970-01-01T00:00:01Z","movie":{"ids":{"simkl":10,"tmdb":550}}}]}"#
                    : "{}"
            case (.get, "/sync/all-items/shows"), (.get, "/sync/all-items/anime"): json = "{}"
            case (.get, "/sync/playback"): json = "[]"
            case (.post, "/sync/history"):
                guard let data = endpoint.body,
                      let body = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      Set(body.keys) == ["movies"], let movies = body["movies"] as? [[String: Any]], movies.count == 1,
                      Set(movies[0].keys) == ["ids", "watched_at", "is_rewatch"],
                      movies[0]["ids"] as? [String: Int] == ["simkl": 10],
                      movies[0]["watched_at"] as? String == "1970-01-01T00:00:01Z",
                      movies[0]["is_rewatch"] as? Bool == false,
                      !endpoint.queryItems.contains(where: { $0.name == "allow_rewatch" }) else {
                    throw HTTPRequestNotSentError(underlying: .invalidResponse)
                }
                try wrote()
                status = 201
                json = #"{"added":{"movies":1,"shows":0,"episodes":0,"statuses":[{"request":{"type":"movie","ids":{"simkl":10},"watched_at":"1970-01-01T00:00:01Z"},"response":{"status":"completed","simkl_type":"movie"}}]},"not_found":{"movies":[],"shows":[],"episodes":[]}}"#
            default: throw AppError.notFound
            }
            guard let response = HTTPURLResponse(url: baseURL, statusCode: status, httpVersion: nil, headerFields: headers) else {
                throw AppError.invalidResponse
            }
            return (Data(json.utf8), response)
        }
    }

    @MainActor
    private final class TraktExportFixtureHTTP: HTTPClient {
        let read: @MainActor () throws -> Bool
        let wrote: @MainActor () throws -> Void
        init(read: @escaping @MainActor () throws -> Bool, wrote: @escaping @MainActor () throws -> Void) {
            self.read = read
            self.wrote = wrote
        }

        func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
            try await sendRaw(endpoint, baseURL: baseURL)
        }

        func sendRaw(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
            let isPublic = ["/search/tmdb/550", "/movies/10"].contains(endpoint.path)
            guard isPublic ? endpoint.headers["Authorization"] == nil
                : endpoint.headers["Authorization"] == "Bearer fixture" else { throw AppError.unauthorized }
            let exported = try read()
            let stamp = exported ? "2020-01-03T00:00:00Z" : "2020-01-02T00:00:00Z"
            let movie = #"{"ids":{"trakt":10,"tmdb":550}}"#
            var status = 200
            var headers: [String: String] = [:]
            let json: String
            switch (endpoint.method, endpoint.path) {
            case (.get, "/users/settings"):
                json = #"{"user":{"username":"fixture","ids":{"uuid":"fixture-owner"}}}"#
            case (.get, "/search/tmdb/550"): json = #"[{"type":"movie","movie":\#(movie)}]"#
            case (.get, "/movies/10"): json = movie
            case (.get, "/sync/last_activities"):
                json = #"{"all":"\#(stamp)","movies":{"watched_at":"\#(stamp)","paused_at":"\#(stamp)"},"episodes":{"watched_at":"\#(stamp)","paused_at":"\#(stamp)"},"watchlist":{"updated_at":"\#(stamp)"}}"#
            case (.get, "/users/me/history"), (.get, "/users/me/history/movies/10"):
                json = exported
                    ? #"[{"id":1,"type":"movie","action":"watch","watched_at":"2020-01-02T03:04:05.000Z","movie":\#(movie)}]"#
                    : "[]"
            case (.get, "/sync/watchlist/seasons/added/desc"), (.get, "/sync/watchlist/episodes/added/desc"),
                 (.get, "/sync/playback"), (.get, "/sync/watchlist/movies/added/desc"),
                 (.get, "/sync/watchlist/shows/added/desc"): json = "[]"
            case (.get, "/users/me/watching"): status = 204; json = ""
            case (.post, "/sync/history"):
                guard let data = endpoint.body,
                      let body = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      Set(body.keys) == ["movies"], let movies = body["movies"] as? [[String: Any]], movies.count == 1,
                      Set(movies[0].keys) == ["ids", "watched_at"],
                      movies[0]["ids"] as? [String: Int] == ["trakt": 10],
                      movies[0]["watched_at"] as? String == "2020-01-02T03:04:05.000Z" else {
                    throw HTTPRequestNotSentError(underlying: .invalidResponse)
                }
                try wrote()
                json = #"{"added":{"movies":1,"episodes":0},"updated":{"movies":0,"episodes":0},"not_found":{"movies":[],"shows":[],"seasons":[],"episodes":[]}}"#
            default: throw AppError.notFound
            }
            if endpoint.queryItems.contains(where: { $0.name == "page" }) {
                guard let count = (try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [Any])?.count else {
                    throw AppError.invalidResponse
                }
                headers = [
                    "X-Pagination-Page": "1", "X-Pagination-Limit": "100",
                    "X-Pagination-Page-Count": count == 0 ? "0" : "1", "X-Pagination-Item-Count": String(count)
                ]
            }
            guard let response = HTTPURLResponse(url: baseURL, statusCode: status, httpVersion: nil, headerFields: headers) else {
                throw AppError.invalidResponse
            }
            return (Data(json.utf8), response)
        }
    }

    private func exportSnapshot() throws -> TrackerHistorySnapshot {
        trackerReads += 1
        if trackerReads > 1, arguments.contains("--history-revoke-on-recheck") { authorized = false }
        let changed = trackerReads > 1 && arguments.contains("--history-change-on-recheck")
        let observations: [TrackerHistoryObservation]
        if changed || exported {
            observations = [try .init(
                recordID: "watch", kind: .movie, identities: [.external(source: "tmdb", value: "550")],
                fact: changed ? .resume(seconds: 50, runtime: 1_000, updatedAt: nil) : .watched(at: nil)
            )]
        } else { observations = [] }
        return try .init(trackerID: "fixture", connectionID: "fixture", observations: observations, completeness: .completeResponse)
    }

    private func makeSession(
        scope: WatchMutationServerScope, allowed: @escaping @MainActor @Sendable () -> Bool
    ) -> TrackerHistoryImportSession {
        return TrackerHistoryImportSession(
            scope: scope,
            destinations: providers.map {
                .init(id: $0.account.id, serverName: $0.account.server.name, userName: $0.account.userName)
            },
            reconciler: makeReconciler(),
            readSnapshot: { try self.snapshot() },
            index: { self.index },
            resolveProvider: {
                guard let provider = self.provider($0) else { throw AppError.serverUnreachable }
                return provider
            },
            isAuthorized: { self.authorized && allowed() }
        )
    }

    private func snapshot() throws -> TrackerHistorySnapshot {
        trackerReads += 1
        if trackerReads > 1, arguments.contains("--history-revoke-on-recheck") {
            authorized = false
        }
        let changed = trackerReads > 1 && arguments.contains("--history-change-on-recheck")
        return try TrackerHistorySnapshot(
            trackerID: "publicmetadb", connectionID: "fixture-connection",
            observations: [
                .init(
                    recordID: "watch-\(newPlay)", kind: .movie,
                    identities: [.external(source: "tmdb", value: "550")],
                    fact: .watched(at: Date(timeIntervalSince1970: changed ? 1_700_000_001 : 1_700_000_000))
                )
            ],
            completeness: .completeResponse
        )
    }

    private func requireScope(_ requested: WatchMutationServerScope) throws {
        guard authorized, requested.profileID == scope.profileID,
              Set(requested.accounts).isSubset(of: Set(scope.accounts)) else {
            throw WatchMutationServerScopeError.unavailable
        }
    }

    private final class AtlasSourceStorage: SecureStoring, @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: String] = [:]
        func setString(_ value: String, for key: String) throws {
            lock.lock(); defer { lock.unlock() }; values[key] = value
        }
        func string(for key: String) -> String? { lock.lock(); defer { lock.unlock() }; return values[key] }
        func readString(for key: String) throws -> String? { string(for: key) }
        func removeValue(for key: String) throws { lock.lock(); defer { lock.unlock() }; values[key] = nil }
    }

    private func provider(_ accountID: String) -> (any MediaProvider)? {
        guard authorized else { return nil }
        return providers.first { $0.account.id == accountID }
    }

    private func unexpectedTrackerWrite() throws {
        trackerWrites += 1
        throw AppError.invalidResponse
    }
}

@MainActor @Observable
private final class AtlasSourceProvider: MediaProvider, WatchStateProviding {
    let kind: ProviderKind
    let account: Account
    let session: UserSession
    var current: MediaItem
    var writes = 0
    var playbackWrites = 0
    private var reads = 0
    private let arguments = ProcessInfo.processInfo.arguments

    init(kind: ProviderKind, id: String, name: String, user: String) {
        self.kind = kind
        let server = MediaServer(
            id: id, name: name,
            baseURL: URL(string: kind == .mediaShare ? "smb://\(id).example.test/media" : "https://\(id).example.test")!, provider: kind
        )
        account = Account(
            id: id, server: server, userID: "\(id)-viewer", userName: user, deviceID: "fixture-device"
        )
        session = UserSession(
            server: server, userID: account.userID, userName: account.userName,
            deviceID: account.deviceID, accessToken: ""
        )
        current = MediaItem(
            id: "movie", title: "The Last Lantern", kind: .movie, runtime: 1_000,
            isPlayed: arguments.contains("--history-export"),
            providerIDs: ["Tmdb": "550"], sourceAccountID: account.id
        )
        if arguments.contains("--history-trakt-export") {
            current.lastPlayedAt = Date(timeIntervalSince1970: 1_577_934_245)
        }
    }

    func libraries() async throws -> [MediaLibrary] {
        arguments.contains("--history-export") ? [.init(id: "movies", title: "Movies", kind: .movie)] : []
    }
    func continueWatching(limit: Int) async throws -> [MediaItem] { [] }
    func latest(limit: Int) async throws -> [MediaItem] { [] }
    func item(id: String) async throws -> MediaItem {
        guard id == current.id else { throw AppError.notFound }
        reads += 1
        if reads > 1, arguments.contains("--history-server-change-on-recheck") {
            current.resumePosition = 50
        }
        return current
    }
    func children(of itemID: String) async throws -> [MediaItem] { throw AppError.notFound }
    func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        guard arguments.contains("--history-export"), containerID == "movies", kind == .movie else {
            throw AppError.notFound
        }
        return .init(items: page.startIndex == 0 ? [current] : [], startIndex: page.startIndex, totalCount: 1)
    }
    func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
    func playbackInfo(for itemID: String) async throws -> PlaybackRequest { throw AppError.notFound }
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {
        playbackWrites += 1
        throw AppError.invalidResponse
    }
    nonisolated func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
    func setPlayed(_ played: Bool, itemID: String) async throws {
        guard itemID == current.id else { throw AppError.notFound }
        current.isPlayed = played
        writes += 1
        if arguments.contains("--history-lost-write-reply") { throw AppError.serverUnreachable }
    }
}
