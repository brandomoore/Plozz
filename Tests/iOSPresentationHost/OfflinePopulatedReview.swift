import AVFoundation
import CoreModels
import CoreUI
import FeatureAuth
import FeatureHomeCore
import FeaturePlayback
import FeatureSearchCore
import MediaDownloads
import SwiftUI
import UIKit
@testable import AppRuntime
@testable import AppShelliOS

/// Populates the ordinary durable download path, not a replacement browsing UI.
@MainActor
enum OfflinePopulatedReview {
    static let accountID = "offline-review-jellyfin"
    static let titles = ["Amber Harbor", "Blue Mountain", "Cedar Road"]

    static func seed(profile: Profile, account: Account, secondProfile: Bool = false) throws {
        let storage = PlatformDownloadStorageLocator(subdirectory: "PlozzDownloads/\(profile.id)")
        _ = try KeychainStore(service: DurableLocalStateStore.keychainService)
            .readString(for: "offline-review-storage-probe")
        let store = try DurableDownloadedMediaStore(
            store: DurableLocalStateStoreFactory.userIndependent(), profileID: profile.id
        )
        _ = store.load()
        guard let movie = Bundle.main.url(forResource: "live-continuity", withExtension: "mp4") else {
            throw CocoaError(.fileNoSuchFile)
        }
        let user = WatchMutationServerScope.AccountIdentity(account: account, profile: profile).downloadUserID
        var records: [DownloadedMediaRecord] = []
        func append(
            _ item: MediaItem, version: String = "hd", status: DownloadStatus = .completed,
            exists: Bool = true, viewer: String? = nil
        ) throws {
            guard let identity = DownloadMediaIdentity.requestIdentity(for: item, existingRecords: []) else {
                throw AppError.invalidResponse
            }
            var snapshot = PinnedMediaSnapshot(item: item, sourceUserID: viewer ?? user)
            snapshot.artworkFileName = "poster.png"
            let record = DownloadedMediaRecord(
                identity: identity, versionID: version, versionLabel: version.uppercased(),
                groupID: item.seriesID, sourceKind: .managedHTTP, status: status,
                localFileName: "media.mp4", bytesDownloaded: 9_383_198, totalBytes: 9_383_198,
                snapshot: snapshot, updatedAt: Date(timeIntervalSince1970: 1_800_000_000 + Double(records.count))
            )
            let folder = try storage.pinnedFolderURL(forKey: record.identityKey)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let destination = try storage.pinnedFileURL(for: record)
            if exists, !FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.copyItem(at: movie, to: destination)
            }
            let artwork = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 450)).pngData { context in
                UIColor(hue: CGFloat(records.count % 8) / 8, saturation: 0.6, brightness: 0.45, alpha: 1).setFill()
                context.fill(CGRect(x: 0, y: 0, width: 300, height: 450))
                ((item.parentTitle ?? item.title) as NSString).draw(
                    in: CGRect(x: 20, y: 150, width: 260, height: 240),
                    withAttributes: [.font: UIFont.boldSystemFont(ofSize: 32), .foregroundColor: UIColor.white]
                )
            }
            try artwork.write(to: folder.appendingPathComponent("poster.png"), options: .atomic)
            records.append(record)
        }
        for (index, title) in titles.enumerated() {
            let item = MediaItem(
                id: "movie-\(index)", title: title, kind: .movie,
                overview: "A local playback fixture.", productionYear: 2020 + index,
                officialRating: "PG", genres: [index == 1 ? "Comedy" : "Drama"],
                runtime: 420, resumePosition: index == 1 ? 45 : 0, isPlayed: index == 2,
                sourceAccountID: account.id, libraryID: "movies"
            )
            try append(item)
            if index == 0 { try append(item, version: "sd") }
        }
        for (id, status, exists, viewer) in [
            ("Missing file", DownloadStatus.completed, false, user),
            ("Partial download", .paused, true, user),
            ("Different viewer", .completed, true, "another-viewer")
        ] {
            try append(MediaItem(id: id, title: id, kind: .movie, sourceAccountID: account.id, libraryID: "movies"),
                       status: status, exists: exists, viewer: viewer)
        }
        for episode in [1, 3, 4] {
            try append(MediaItem(
                id: "episode-\(episode)", title: "Trail \(episode)", kind: .episode,
                overview: "A downloaded episode fixture.", parentTitle: "The Local Trail",
                seasonNumber: 1, episodeNumber: episode, productionYear: 2023,
                officialRating: "TV-PG", genres: ["Documentary"], seriesID: "trail", seasonID: "trail-s1",
                runtime: 420, resumePosition: episode == 1 ? 30 : 0, isPlayed: episode == 4,
                sourceAccountID: account.id, libraryID: "shows"
            ))
        }
        if secondProfile {
            records = records.filter { $0.snapshot.sourceItemID == "movie-2" }
            records[0].snapshot.sourceItemID = "sam-movie"
            records[0].snapshot.title = "Sam's Movie"
        }
        try store.save(.init(records: Dictionary(uniqueKeysWithValues: records.map { ($0.identityKey, $0) })))
    }

    static func configure(_ app: PlozziOSAppModel) {
        let libraries = [
            MediaLibrary(id: "movies", title: "Movies", kind: .movie),
            MediaLibrary(id: "shows", title: "TV Shows", kind: .series)
        ].map {
            AggregatedLibrary(accountID: accountID, accountName: "Alex", serverName: "Offline fixture",
                              providerKind: .jellyfin, library: $0)
        }
        app.settings.navigation.updateContentLibraries(
            libraries, accountIDs: [accountID], unreachableAccountIDs: []
        )
        let available = NavigationDestinationDefaults.iOS(visibleLibraries: libraries)
        let enabled = [
            NavigationLibraryLayout.homeKey, "\(accountID):movies", "\(accountID):shows",
            NavigationLibraryLayout.watchlistKey, NavigationLibraryLayout.downloadsKey,
            NavigationLibraryLayout.searchKey, NavigationLibraryLayout.discoverKey, NavigationLibraryLayout.liveTVKey
        ]
        app.settings.navigation.applyLibrarySections(
            .init(enabled: enabled, disabled: available.filter { !enabled.contains($0) }),
            available: available, automaticallyHiddenKeys: []
        )
    }

    static func prepareWatchlist(_ app: PlozziOSAppModel) async throws {
        try app.universalWatchlist.activate(profileID: app.profiles.activeProfileID)
        guard let provider = app.accountsProviders.homeAccounts.first?.provider else { throw AppError.notFound }
        for id in ["movie-0", "movie-2", "trail"] {
            let item = try await provider.item(id: id)
            guard await app.performUniversalWatchlist(adding: true, item: item) else { throw AppError.invalidResponse }
        }
        let onlineOnly = MediaItem(
            id: "not-downloaded", title: "Online Only", kind: .movie,
            sourceAccountID: accountID, libraryID: "movies"
        )
        guard await app.performUniversalWatchlist(adding: true, item: onlineOnly) else { throw AppError.invalidResponse }
    }

    struct Result: Codable {
        let name: String
        let passed: Bool
        let observed: String
    }

    static func verifyDisabled(_ app: PlozziOSAppModel) async throws {
        var results: [Result] = []
        func check(_ name: String, _ passed: Bool, _ observed: String) {
            results.append(Result(name: name, passed: passed, observed: observed))
        }
        check("disabled flag suppresses availability", !app.isOfflineModeAvailable, "availability \(app.isOfflineModeAvailable)")
        check("disabled flag ignores saved active mode", !app.isOfflineMode && !OfflineMode.shared.isEnabled,
              "mode \(app.isOfflineMode), policy \(OfflineMode.shared.isEnabled)")
        check("saved preference retained", UserDefaults.standard.bool(forKey: OfflineMode.preferenceKey), "device preference")
        check("online routing restored", app.accountsProviders.localProviders == nil, "local provider override")
        check("download files retained", app.downloads.playableRecords.count == 7, "playable \(app.downloads.playableRecords.count)")
        check("saved progress retained", app.downloads.records.filter {
            $0.snapshot.sourceItemID == "movie-0"
        }.allSatisfy { $0.snapshot.resumePosition == 65 }, "both movie versions")
        check("disabled status starts hidden", app.offlineMode.notice == nil, "notice \(String(describing: app.offlineMode.notice))")
        for platform: SettingsSearchEntry.Platform in [.phone, .tablet] {
            let entries = SettingsSearchCatalog.entries(on: platform, featureFlags: app.runtimeFeatureFlags)
            check("settings search hides mode on \(platform)", !entries.contains { $0.id == "offline-mode" },
                  "offline search entry")
            check("settings search retains downloads on \(platform)", entries.contains { $0.id == "downloads-cellular" },
                  "ordinary download settings")
        }
        await app.setOfflineMode(true)
        check("disabled flag rejects activation", !app.isOfflineMode && !OfflineMode.shared.isEnabled
              && app.accountsProviders.localProviders == nil, "mode remains disabled")
        try OfflineMode.shared.requireNetworkAccess()
        check("network admission restored", true, "requireNetworkAccess succeeded")
        let disabledPolicy = OfflineMode(featureFlags: app.runtimeFeatureFlags)
        disabledPolicy.setEnabled(true)
        check("disabled policy refuses activation", !disabledPolicy.isEnabled, "separate policy object")

        let defaults = UserDefaults(suiteName: "OfflineFlagAuthReview.\(UUID())")!
        let profiles = ProfilesModel(store: ProfileStore(defaults: defaults))
        let accounts = AccountStore(secureStore: InMemorySecureStore())
        let account = Account(
            id: "flag-plex", server: .init(id: "flag-plex", name: "Fixture",
                                          baseURL: URL(string: "https://fixture.invalid")!, provider: .plex),
            userID: "owner", userName: "Owner", deviceID: "fixture"
        )
        try accounts.add(account, token: "FIXTURE-OWNER")
        let providers = AccountsProvidersModel(
            accountStore: accounts, registry: ProviderRegistry(), profilesModel: profiles
        )
        providers.reloadAccounts()
        profiles.update(profiles.activeProfile.settingHomeUserBinding(
            .init(homeUserID: "viewer", name: "Viewer", requiresPIN: false, pinRequirementVerified: true),
            forPlexAccount: account.id
        ))
        let proofs = OfflinePlexSignInStore(secureStore: InMemorySecureStore(), defaults: defaults)
        try proofs.save(profile: profiles.activeProfile, account: account, pinVerifier: nil, serverToken: "FIXTURE-VIEWER")
        let auth = PlexHomeUsersModel(
            accountsProviders: providers, profilesModel: profiles,
            plexHomeUserTokenCache: .init(store: InMemorySecureStore()),
            automaticSignInStore: .init(defaults: defaults, secureStore: InMemorySecureStore()),
            offlineSignInStore: proofs, runtimeFeatureFlags: app.runtimeFeatureFlags, switchProfile: { _ in }
        )
        auth.plexHomeUsersFetch = { _, _ in throw URLError(.notConnectedToInternet) }
        auth.plexHomeUserSwitch = { _, _, _, _ in throw URLError(.notConnectedToInternet) }
        auth.ensurePlexIdentityForActiveProfile()
        await auth.waitForPlexPINRequirementCheck()
        check("cached Plex fallback disabled", auth.resolvedToken(for: account.id) == nil
              && auth.pendingPlexPINRequest != nil, "outage requires online authentication")
        check("cached proof retained", try proofs.load(profile: profiles.activeProfile, account: account) != nil,
              "existing device-local proof")
        auth.plexHomeUsersFetch = { _, _ in [.init(id: "viewer", name: "Viewer", requiresPIN: false)] }
        auth.plexHomeUserSwitch = { _, _, _, _ in "FIXTURE-CLOUD" }
        auth.plexServerTokenResolve = { _, _, _ in "FIXTURE-ONLINE-SERVER" }
        auth.retryPlexPINRequirement()
        await auth.waitForPlexPINRequirementCheck()
        check("ordinary online Plex sign-in retained", auth.pendingPlexPINRequest == nil
              && auth.resolvedToken(for: account.id) == "FIXTURE-ONLINE-SERVER", "online identity resolved")
        check("disabled flag does not update offline proof",
              try proofs.load(profile: profiles.activeProfile, account: account)?.serverToken == "FIXTURE-VIEWER",
              "original proof unchanged")
        try JSONEncoder().encode(results).write(
            to: URL.documentsDirectory.appendingPathComponent("offline-disabled-verification.json"), options: .atomic
        )
    }

    static func verify(_ app: PlozziOSAppModel) async throws {
        var results: [Result] = []
        func check(_ name: String, _ passed: Bool, _ observed: String) {
            results.append(Result(name: name, passed: passed, observed: observed))
            do {
                try JSONEncoder().encode(results).write(
                    to: URL.documentsDirectory.appendingPathComponent("offline-verification.json"), options: .atomic
                )
            } catch { fatalError("Could not persist offline verification: \(error)") }
        }
        guard let provider = app.accountsProviders.homeAccounts.first?.provider else { throw AppError.notFound }
        let eligible: Set<String> = ["movie-0", "movie-1", "movie-2", "episode-1", "episode-3", "episode-4"]
        let latest = try await provider.latest(limit: 100)
        check("catalog eligibility", Set(latest.map(\.id)) == eligible, latest.map(\.title).joined(separator: ", "))
        check("download-list eligibility", app.downloads.playableRecords.count == 7,
              "playable \(app.downloads.playableRecords.count); total \(app.downloads.records.count)")
        for (name, filters, expected) in [
            ("unwatched", LibraryFilters(filter: .unwatched), ["movie-0", "movie-1"]),
            ("in progress", .init(filter: .inProgress), ["movie-1"]),
            ("genre", .init(genre: "Drama"), ["movie-0", "movie-2"]),
            ("year", .init(year: 2021), ["movie-1"]),
            ("combined facets", .init(filter: .unwatched, genre: "Drama", year: 2020), ["movie-0"])
        ] {
            let page = try await provider.items(in: "movies", kind: .movie, page: .init(filters: filters))
            check("provider filter: \(name)", Set(page.items.map(\.id)) == Set(expected), page.items.map(\.id).joined(separator: ","))
        }
        let descending = try await provider.items(
            in: "movies", kind: .movie, page: .init(sort: .init(field: .year, direction: .descending))
        )
        check("year sort", descending.items.map(\.id) == ["movie-2", "movie-1", "movie-0"],
              descending.items.map(\.id).joined(separator: ","))
        let defaults = UserDefaults(suiteName: "OfflineVerify.\(UUID())")!
        let browse = LibraryBrowseViewModel(
            provider: provider, containerID: "movies", containerKind: .movie, defaults: defaults,
            sourceAccountID: accountID, initialContentMode: .titles
        )
        await browse.loadFirstPage()
        check("library model populated", browse.totalCount == 3, "count \(browse.totalCount)")
        check("library filter menu available", browse.showsFilterMenu, "showsFilterMenu \(browse.showsFilterMenu)")
        await browse.setFilters(.init(filter: .unwatched))
        check("library UI filter applies", browse.totalCount == 2, "count \(browse.totalCount), filter \(browse.filters.filter)")
        let shows = try await provider.children(of: "shows")
        let seasons = try await provider.children(of: "trail")
        let episodes = try await provider.children(of: "trail-s1")
        check("show-season-episode hierarchy", shows.map(\.id) == ["trail"] && seasons.map(\.id) == ["trail-s1"]
              && episodes.map(\.id) == ["episode-1", "episode-3", "episode-4"], episodes.map(\.id).joined(separator: ","))
        let series = try await provider.item(id: "trail")
        check("series metadata retained", series.genres == ["Documentary"] && series.productionYear == 2023,
              "genres \(series.genres), year \(String(describing: series.productionYear))")
        let neighbors = app.downloads.offlineNeighborItems(for: try await provider.item(id: "episode-1"))
        check("next downloaded episode", neighbors?.next?.id == "episode-3", neighbors?.next?.id ?? "nil")
        let search = SearchViewModel(accounts: app.accountsProviders.homeAccounts, debounceMilliseconds: 0)
        search.query = "Trail"
        await search.search()
        let searched = search.state.value?.flatMap(\.items) ?? []
        check("search uses local catalog", Set(searched.map(\.id)) == ["trail", "episode-1", "episode-3", "episode-4"],
              searched.map(\.id).joined(separator: ","))
        let movie = try await provider.item(id: "movie-0")
        check("downloaded versions only", Set(movie.versions.map(\.id)) == ["hd", "sd"], movie.versions.map(\.id).joined(separator: ","))
        let playback = try await provider.playbackInfo(for: "movie-0", mediaSourceID: "sd", forceTranscode: false)
        check("exact local version", playback.streamURL?.isFileURL == true && playback.item.selectedVersionID == "sd",
              playback.item.selectedVersionID ?? "nil")
        do {
            _ = try await provider.playbackInfo(for: "movie-0", mediaSourceID: "absent", forceTranscode: false)
            check("absent version rejected", false, "returned playback")
        } catch { check("absent version rejected", error as? AppError == .notFound, String(describing: error)) }
        let shell = PlozziOSTabShell(
            appModel: app, homeViewModelBox: LazyViewState<HomeViewModel>(),
            onAddServer: {}, showingSettings: .constant(false), showingProfileSwitcher: .constant(false),
            deferredPairingURL: .constant(nil), systemColorScheme: .dark
        )
        let home = shell.sharedHomeViewModel
        await home.load()
        let content = home.state.value
        check("Home populated and local", content?.latest.isEmpty == false
              && Set(content?.latest.map(\.id) ?? []).isSubset(of: eligible),
              "latest: \(content?.latest.map(\.id).joined(separator: ",") ?? "nil")")
        check("Home continue watching", Set(content?.continueWatching.map(\.id) ?? []) == ["movie-1", "episode-1"],
              content?.continueWatching.map(\.id).joined(separator: ",") ?? "nil")
        check("watchlist excludes online-only", Set(content?.watchlist.map(\.id) ?? []) == ["movie-0", "movie-2", "trail"],
              content?.watchlist.map(\.id).joined(separator: ",") ?? "nil")
        try await provider.reportPlayback(
            .init(itemID: "movie-0", playSessionID: nil, positionSeconds: 65, isPaused: true), event: .stop
        )
        let resumed = try await provider.item(id: "movie-0")
        check("local progress persisted", resumed.resumePosition == 65, "resume \(String(describing: resumed.resumePosition))")
        let store = try DurableDownloadedMediaStore(
            store: DurableLocalStateStoreFactory.userIndependent(), profileID: app.profiles.activeProfileID
        )
        check("fresh store reads progress", store.load().records.values.filter {
            $0.snapshot.sourceItemID == "movie-0"
        }.allSatisfy { $0.snapshot.resumePosition == 65 }, "two versions, fresh durable store")
        let player = PlayerViewModel(
            provider: provider, itemID: "movie-1", offlineItem: try await provider.item(id: "movie-1"),
            offlinePlaybackResolver: app.downloads.offlineResolver, startPosition: 45, engineFactory: .native
        )
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else {
            throw AppError.invalidResponse
        }
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let playbackWindow = UIWindow(windowScene: scene)
        playbackWindow.rootViewController = UIHostingController(rootView: PlayerView(viewModel: player))
        playbackWindow.makeKeyAndVisible()
        defer {
            playbackWindow.isHidden = true
            previousWindow?.makeKey()
        }
        do {
            let deadline = ContinuousClock.now + .seconds(30)
            while player.controls.currentSeconds < 47, ContinuousClock.now < deadline {
                if case .failed = player.phase { break }
                try await Task.sleep(for: .milliseconds(200))
            }
            let advanced = player.controls.currentSeconds >= 47
            check("real local video advances", advanced,
                  "position \(player.controls.currentSeconds), phase \(player.phase)")
            player.setPaused(true)
            try await Task.sleep(for: .milliseconds(300))
            let paused = player.controls.currentSeconds
            try await Task.sleep(for: .seconds(1))
            check("local playback pauses", advanced && abs(player.controls.currentSeconds - paused) < 0.5,
                  "before \(paused), after \(player.controls.currentSeconds)")
            await player.seek(to: 120)
            try await Task.sleep(for: .seconds(1))
            check("local playback seeks", abs(player.controls.currentSeconds - 120) < 2,
                  "position \(player.controls.currentSeconds)")
        } catch {
            await player.stop()
            throw error
        }
        await player.stop()
        playbackWindow.isHidden = true
        previousWindow?.makeKey()
        let originalProfile = app.profiles.activeProfileID
        if let sam = app.profiles.profiles.first(where: { $0.name == "Sam" }) {
            app.selectProfile(sam.id)
            let deadline = ContinuousClock.now + .seconds(15)
            while !app.downloads.playableRecords.contains(where: { $0.snapshot.sourceItemID == "sam-movie" }),
                  ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(100))
            }
            check("profile isolation", app.downloads.playableRecords.map(\.snapshot.sourceItemID) == ["sam-movie"],
                  app.downloads.playableRecords.map(\.snapshot.title).joined(separator: ","))
            do {
                _ = try await provider.latest(limit: 100)
                check("old profile provider revoked", false, "returned content")
            } catch { check("old profile provider revoked", true, String(describing: error)) }
            app.selectProfile(originalProfile)
            let restoreDeadline = ContinuousClock.now + .seconds(15)
            while app.downloads.playableRecords.count != 7, ContinuousClock.now < restoreDeadline {
                try await Task.sleep(for: .milliseconds(100))
            }
            check("original profile restored", app.downloads.playableRecords.count == 7,
                  "playable \(app.downloads.playableRecords.count)")
        }
        await app.setOfflineMode(false)
        check("online providers restored", !app.isOfflineMode
              && app.accountsProviders.homeAccounts.allSatisfy { !($0.provider is OfflineMediaProvider) },
              "offline \(app.isOfflineMode), accounts \(app.accountsProviders.homeAccounts.count)")
        await app.setOfflineMode(true)
        let reentryDeadline = ContinuousClock.now + .seconds(15)
        while app.downloads.playableRecords.count != 7, ContinuousClock.now < reentryDeadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        check("offline reentry restores downloads", app.isOfflineMode && app.downloads.playableRecords.count == 7,
              "playable \(app.downloads.playableRecords.count)")
        configure(app)
        let reentryHome = PlozziOSTabShell(
            appModel: app, homeViewModelBox: LazyViewState<HomeViewModel>(),
            onAddServer: {}, showingSettings: .constant(false), showingProfileSwitcher: .constant(false),
            deferredPairingURL: .constant(nil), systemColorScheme: .dark
        ).sharedHomeViewModel
        await reentryHome.load()
        check("watchlist survives profile and mode transitions",
              Set(reentryHome.state.value?.watchlist.map(\.id) ?? []) == ["movie-0", "movie-2", "trail"],
              reentryHome.state.value?.watchlist.map(\.id).joined(separator: ",") ?? "nil")
        let data = try JSONEncoder().encode(results)
        try data.write(to: URL.documentsDirectory.appendingPathComponent("offline-verification.json"), options: .atomic)
    }
}
