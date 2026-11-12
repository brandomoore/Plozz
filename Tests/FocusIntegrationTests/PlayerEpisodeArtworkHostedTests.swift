import CoreModels
import MetadataKit
import Observation
@testable import CoreUI
@testable import FeaturePlayback
import SwiftUI
import TVUIKit
import UIKit
import Vision
import XCTest

@MainActor
final class PlayerEpisodeArtworkHostedTests: XCTestCase {
    private var savedProviders = MetadataProviderSettings.default

    func testProductionCardTabsDoNotRestoreAnEarlierNativeFocusTarget() async throws {
        _ = try await exerciseCardTabs(measuring: false)
    }

    func testPerformancePlayerCardFirstVisits() async throws {
        try await PerformanceProbe.measure(self, scenario: "player-card-first-visits") {
            try await self.exerciseCardTabs(measuring: true)
        }
    }

    func testPerformanceContinueWatchingControls() async throws {
        try await PerformanceProbe.measure(self, scenario: "player-continue-watching-controls") {
            try await self.exerciseContinueWatchingControls(enabled: true)
        }
    }

    func testPerformanceContinueWatchingDisabled() async throws {
        try await PerformanceProbe.measure(self, scenario: "player-continue-watching-disabled") {
            try await self.exerciseContinueWatchingControls(enabled: false)
        }
    }

    func testHiddenOptionalTabsLeaveInfoFocusable() async throws {
        _ = try await exerciseContinueWatchingControls(enabled: false, infoOnly: true)
    }

    func testContinueWatchingPendingArtworkDoesNotBlockNativeNavigation() async throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 6)).image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 6))
        }
        let server = try LibraryArtworkServer(
            images: ["poster": XCTUnwrap(image.pngData())], delays: ["poster": 10]
        )
        let port = try await server.start()
        defer { server.stop() }
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/poster"))
        let counters = try await exerciseContinueWatchingControls(enabled: true, artworkURL: url, server: server)
        XCTAssertGreaterThan(server.requestCount(for: "/poster"), 0, "The real artwork lane must have started.")
        XCTAssertLessThan(counters["revealMicroseconds"] ?? .max, 500_000)
        XCTAssertLessThan(counters["navigationMaxMainActorGapMicroseconds"] ?? .max, 500_000)
    }

    private func exerciseContinueWatchingControls(
        enabled: Bool, artworkURL: URL? = nil, server: LibraryArtworkServer? = nil, infoOnly: Bool = false
    ) async throws -> [String: Int] {
        try await waitUntil {
            UIApplication.shared.connectedScenes.contains { $0.activationState == .foregroundActive }
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let provider = EpisodeRowProvider()
        var settings = PlaybackSettings()
        settings.continueWatchingInPlayer = enabled
        if infoOnly {
            for tab in PlayerOptionalTab.allCases {
                settings[keyPath: tab.visibilityKeyPath] = false
            }
        }
        let player = PlayerViewModel(provider: provider, itemID: "playing", playbackSettings: settings)
        let items = (0..<180).map { index in
            MediaItem(
                id: "resume-\(index)", title: "Continue watching \(index)", kind: .episode,
                overview: String(repeating: "A metadata-rich Home episode. ", count: 40),
                seasonNumber: 1, episodeNumber: index + 1, seriesID: "series-\(index)",
                runtime: 3600, resumePosition: 900, posterURL: artworkURL,
                seriesPosterURL: artworkURL, backdropURL: artworkURL, fallbackArtworkURL: artworkURL,
                sourceAccountID: "account-\(index % 12)"
            )
        }
        var snapshotReads = 0
        player.continueWatchingSnapshot = {
            snapshotReads += 1
            return items
        }
        let model = PlayerControlsModel()
        model.title = "Continue Watching responsiveness"
        model.duration = 3600
        model.currentSeconds = 600
        model.infoCard.chapters = (0..<20).map { .init(start: Double($0) * 120, title: "Chapter \($0)") }
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        var largestGap = Duration.zero
        let heartbeat = Task {
            var last = ContinuousClock.now
            while !Task.isCancelled {
                try await Task.sleep(for: .milliseconds(2))
                let now = ContinuousClock.now
                largestGap = max(largestGap, last.duration(to: now))
                last = now
            }
        }
        defer {
            heartbeat.cancel()
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        let host = CardTabFocusHost(rootView:
            PlayerControls(model: model, player: player, palette: .dark, actions: .init(), onExitToSurface: {})
                .environment(\.locale, Locale(identifier: "en_US"))
                .environment(\.scenePhase, .active)
                .background(.black)
        )
        window.rootViewController = host
        window.makeKeyAndVisible()
        try await Task.sleep(for: .milliseconds(300))
        largestGap = .zero
        let revealStart = ContinuousClock.now
        model.controlsVisible = true
        try await waitUntil { model.subtitleLayout.frame(for: .timeline) != nil }
        let reveal = revealStart.duration(to: .now)
        try await Task.sleep(for: .milliseconds(450))
        let revealGap = largestGap
        let revealReads = snapshotReads
        if let server { XCTAssertEqual(server.requestCount(for: "/poster"), 0) }
        model.controlBar.entry = .info
        model.controlBar.settled = false
        model.controlBarVisible = true
        try await waitUntil { model.controlBar.focusArmed }
        try await Task.sleep(for: .milliseconds(600))
        model.controlBar.settled = true
        if server != nil { try await Task.sleep(for: .milliseconds(50)) }
        let system = try XCTUnwrap(UIFocusSystem.focusSystem(for: window))
        let recorder = CardTabFocusRecorder(window: window, model: model)
        defer { NotificationCenter.default.removeObserver(recorder) }
        let tabs = infoOnly ? ["info"]
            : enabled ? ["continueWatching", "chapters", "continueWatching", "info"] : ["chapters", "info"]
        if infoOnly {
            for tab in ["chapters", "cast", "episodes", "playlist", "continueWatching"] {
                XCTAssertNil(model.subtitleLayout.frame(for: .tab(tab)))
            }
        }
        var focusDuration = Duration.zero
        var navigationGap = Duration.zero
        for tab in tabs {
            window.layoutIfNeeded()
            let frame = try XCTUnwrap(
                model.subtitleLayout.frame(for: .tab(tab)),
                "Missing \(tab) anchor"
            )
            let target = try XCTUnwrap(cardTabFocusItems(in: window).first {
                guard let bounds = cardTabFocusFrame($0, in: window) else { return false }
                return frame.contains(CGPoint(x: bounds.midX, y: bounds.midY))
            }, "Missing native target for \(tab)")
            recorder.tabs = []
            await Task.yield()
            largestGap = .zero
            let start = ContinuousClock.now
            host.target = target
            system.requestFocusUpdate(to: host)
            system.updateFocusIfNeeded()
            host.target = nil
            focusDuration = max(focusDuration, start.duration(to: .now))
            try await Task.sleep(for: .milliseconds(250))
            navigationGap = max(navigationGap, largestGap)
            XCTAssertTrue(system.focusedItem === target)
            XCTAssertTrue(recorder.tabs.allSatisfy { $0 == tab })
            let card = try XCTUnwrap(model.subtitleLayout.frame(for: .card))
            XCTAssertTrue(cardTabFocusItems(in: window).contains {
                guard let bounds = cardTabFocusFrame($0, in: window) else { return false }
                return card.contains(CGPoint(x: bounds.midX, y: bounds.midY))
            }, "A populated, focusable card must finish mounting.")
            if tab == "continueWatching", let server {
                try await waitUntil { server.requestCount(for: "/poster") > 0 }
            }
        }
        heartbeat.cancel()
        _ = await heartbeat.result
        let requests = await provider.requests
        XCTAssertTrue(requests.isEmpty, "Opening controls must not fetch provider metadata.")
        XCTAssertEqual(player.continueWatchingItems.count, enabled ? 180 : 0)
        func microseconds(_ duration: Duration) -> Int {
            let parts = duration.components
            return Int(parts.seconds * 1_000_000 + parts.attoseconds / 1_000_000_000_000)
        }
        return [
            "items": items.count, "tabVisits": tabs.count, "providerRequests": requests.count,
            "snapshotReads": snapshotReads, "revealSnapshotReads": revealReads,
            "revealMicroseconds": microseconds(reveal),
            "revealMaxMainActorGapMicroseconds": microseconds(revealGap),
            "focusUpdateMicroseconds": microseconds(focusDuration),
            "navigationMaxMainActorGapMicroseconds": microseconds(navigationGap)
        ]
    }

    func testProductionCardContentAndNativeEntryOnFirstVisits() async throws {
        _ = try await exerciseCardTabs(measuring: false, checkingContent: true)
    }

    private func exerciseCardTabs(measuring: Bool, checkingContent: Bool = false) async throws -> [String: Int] {
        try await waitUntil {
            UIApplication.shared.connectedScenes.contains { $0.activationState == .foregroundActive }
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        for reducedGlass in measuring ? [false] : [false, true] {
            let player = PlayerViewModel(provider: EpisodeRowProvider(), itemID: "card-tabs")
            let model = PlayerControlsModel()
            model.title = "Card tab focus"
            model.duration = 3600
            model.currentSeconds = 600
            model.engineCapabilities = [.playbackSpeed]
            model.controlsVisible = true
            model.infoCard.chapters = (0..<20).map { .init(start: Double($0) * 120, title: "Chapter \($0)") }
            model.infoCard.cast = (0..<20).map { .init(id: "person-\($0)", name: "Person \($0)") }
            let host = CardTabFocusHost(rootView:
                PlayerControls(model: model, player: player, palette: .dark, actions: .init(), onExitToSurface: {})
                    .environment(\.plozzReducePanelGlass, reducedGlass)
                    .environment(\.locale, Locale(identifier: "en_US"))
                    .background(.black)
            )
            window.rootViewController = host
            window.makeKeyAndVisible()
            window.layoutIfNeeded()
            let system = try XCTUnwrap(UIFocusSystem.focusSystem(for: window))
            try await waitUntil { model.subtitleLayout.frame(for: .timeline) != nil }
            system.requestFocusUpdate(to: host)
            system.updateFocusIfNeeded()
            var largestGap = Duration.zero
            let heartbeat: Task<Void, Error>? = measuring ? Task {
                var last = ContinuousClock.now
                while !Task.isCancelled {
                    try await Task.sleep(for: .milliseconds(2))
                    let now = ContinuousClock.now
                    largestGap = max(largestGap, last.duration(to: now))
                    last = now
                }
            } : nil
            defer { heartbeat?.cancel() }
            await Task.yield()
            model.controlBar.entry = .info
            model.controlBar.settled = false
            model.controlBarVisible = true
            try await waitUntil { model.controlBar.focusArmed }
            try await Task.sleep(for: .milliseconds(600))
            model.controlBar.settled = true
            let firstInfoGap = largestGap
            let recorder = CardTabFocusRecorder(window: window, model: model)
            defer { NotificationCenter.default.removeObserver(recorder) }
            if measuring {
                try await Task.sleep(for: .milliseconds(50))
                window.layoutIfNeeded()
                var targets: [String: any UIFocusItem] = [:]
                for tab in ["info", "chapters", "cast"] {
                    let frame = try XCTUnwrap(model.subtitleLayout.frame(for: .tab(tab)))
                    targets[tab] = try XCTUnwrap(cardTabFocusItems(in: window).first {
                        guard let bounds = cardTabFocusFrame($0, in: window) else { return false }
                        return frame.contains(CGPoint(x: bounds.midX, y: bounds.midY))
                    })
                }
                XCTAssertTrue(system.focusedItem === targets["info"])
                XCTAssertTrue(model.controlBar.infoCardOpen)
                XCTAssertNotNil(model.subtitleLayout.frame(for: .card))
                func microseconds(_ duration: Duration) -> Int {
                    let parts = duration.components
                    return Int(parts.seconds * 1_000_000 + parts.attoseconds / 1_000_000_000_000)
                }
                var counters = [
                    "freshHierarchies": 1, "firstVisits": 3,
                    "infoMaxMainActorGapMicroseconds": microseconds(firstInfoGap)
                ]
                for tab in ["chapters", "cast"] {
                    let item = try XCTUnwrap(targets[tab])
                    recorder.tabs = []
                    await Task.yield()
                    largestGap = .zero
                    let start = ContinuousClock.now
                    host.target = item
                    system.requestFocusUpdate(to: host)
                    system.updateFocusIfNeeded()
                    host.target = nil
                    counters["\(tab)FocusUpdateMicroseconds"] = microseconds(start.duration(to: .now))
                    XCTAssertTrue(system.focusedItem === item)
                    try await Task.sleep(for: .milliseconds(200))
                    counters["\(tab)MaxMainActorGapMicroseconds"] = microseconds(largestGap)
                    XCTAssertTrue(system.focusedItem === item)
                    XCTAssertTrue(recorder.tabs.allSatisfy { $0 == tab })
                    let card = try XCTUnwrap(model.subtitleLayout.frame(for: .card))
                    XCTAssertTrue(cardTabFocusItems(in: window).contains {
                        guard let bounds = cardTabFocusFrame($0, in: window) else { return false }
                        return card.contains(CGPoint(x: bounds.midX, y: bounds.midY))
                    }, "First visit must build focusable \(tab) content, not an empty stage.")
                }
                heartbeat?.cancel()
                _ = await heartbeat?.result
                return counters
            }
            for pause in checkingContent ? [300] : [20, 100, 300] {
                for tab in ["info", "chapters", "cast", "chapters", "info"] {
                    window.layoutIfNeeded()
                    let frame = try XCTUnwrap(model.subtitleLayout.frame(for: .tab(tab)), "Missing \(tab) frame")
                    let item = try XCTUnwrap(cardTabFocusItems(in: window).first {
                        guard let bounds = cardTabFocusFrame($0, in: window) else { return false }
                        return frame.contains(CGPoint(x: bounds.midX, y: bounds.midY))
                    }, "Missing native target for \(tab)")
                    recorder.tabs = []
                    host.target = item
                    system.requestFocusUpdate(to: host)
                    system.updateFocusIfNeeded()
                    host.target = nil
                    XCTAssertTrue(system.focusedItem === item, "The native move must reach \(tab).")
                    try await Task.sleep(for: .milliseconds(pause))
                    XCTAssertTrue(system.focusedItem === item, "Focus must stay on \(tab), not bounce after content changes.")
                    XCTAssertTrue(recorder.tabs.allSatisfy { $0 == tab },
                                  "Native focus bounced while entering \(tab): \(recorder.tabs)")
                    if checkingContent {
                        let card = try XCTUnwrap(model.subtitleLayout.frame(for: .card))
                        let contentTarget = try XCTUnwrap(cardTabFocusItems(in: window).first {
                            guard let bounds = cardTabFocusFrame($0, in: window) else { return false }
                            return card.contains(CGPoint(x: bounds.midX, y: bounds.midY))
                        })
                        host.target = contentTarget
                        system.requestFocusUpdate(to: host)
                        system.updateFocusIfNeeded()
                        host.target = nil
                        try await Task.sleep(for: .milliseconds(200))
                        XCTAssertTrue(system.focusedItem === contentTarget,
                                      "The first \(tab) content must accept and retain native focus.")
                        let image = DetailTransitionSnapshot.image(of: window)
                        let recognition = VNRecognizeTextRequest()
                        recognition.recognitionLevel = .accurate
                        recognition.recognitionLanguages = ["en-US"]
                        try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([recognition])
                        let text = (recognition.results ?? [])
                            .compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
                        let expected = ["info": "Now Playing", "chapters": "Chapter 5", "cast": "Person 1"]
                        XCTAssertTrue(text.contains(try XCTUnwrap(expected[tab])), "Missing \(tab) content: \(text)")
                        let attachment = XCTAttachment(image: image)
                        attachment.name = "\(tab) content - \(reducedGlass ? "reduced" : "native glass")"
                        attachment.lifetime = .keepAlways
                        add(attachment)
                        host.target = item
                        system.requestFocusUpdate(to: host)
                        system.updateFocusIfNeeded()
                        host.target = nil
                        try await Task.sleep(for: .milliseconds(100))
                        XCTAssertTrue(system.focusedItem === item)
                    }
                }
            }
            let finalFocus = system.focusedItem
            try await Task.sleep(for: .milliseconds(500))
            XCTAssertTrue(system.focusedItem === finalFocus, "No queued restoration may outlive the last tab move.")
            XCTAssertTrue(recorder.tabs.allSatisfy { $0 == "info" })
            let image = XCTAttachment(image: DetailTransitionSnapshot.image(of: window))
            image.name = "Stable card tab focus - \(reducedGlass ? "reduced" : "native glass")"
            image.lifetime = .keepAlways
            add(image)
        }
        return [:]
    }

    override func setUp() async throws {
        try await super.setUp()
        let store = MetadataProviderSettingsStore()
        savedProviders = store.load()
        store.save(.init(orderMode: .custom, disabledOrder: MetadataEnrichmentConfig.defaultBaseOrder.map(\.rawValue)))
    }

    override func tearDown() async throws {
        MetadataProviderSettingsStore().save(savedProviders)
        try await super.tearDown()
    }

    func testNativeEpisodeArtworkIsIsolatedAcrossReuseAccountsAndPolicy() throws {
        let store = MetadataProviderSettingsStore()
        let original = store.load()
        defer { store.save(original) }
        let shared = URL(string: "https://art.example.test/\(UUID())/shared.jpg")!
        let first = MediaItem(
            id: UUID().uuidString, title: "First", kind: .episode, posterURL: shared
        ).taggingSource("one")
        var second = first
        second.id = UUID().uuidString
        let cell = PlayerEpisodeNativeCell()
        defer { cell.cancelArtwork() }
        for online in [true, false] {
            var settings = original
            settings.preferOnlineArtwork = online
            store.save(settings)
            for (index, item) in [first, second, first.taggingSource("two")].enumerated() {
                let channel = online ? index : (index + 1) % 3
                let color = [UIColor.red, .green, .blue][channel]
                let source = EpisodeArtworkSource(item: item, spoilerSettings: .default)
                seedArtwork(color, source: source)
                let image = try configuredArtwork(cell, item: item)
                let pixel = try artworkPixel(image)
                XCTAssertGreaterThan(pixel[channel], 220)
                for other in 0..<3 where other != channel { XCTAssertLessThan(pixel[other], 25) }
                XCTAssertEqual(cell.accessibilityLabel, item.title)
            }
        }
    }

    func testNativeEpisodeSpoilersMaskTitlesAndExcludeHiddenStills() throws {
        let cell = PlayerEpisodeNativeCell()
        defer { cell.cancelArtwork() }
        var item = MediaItem(
            id: UUID().uuidString, title: "A revealing title", kind: .episode,
            seasonNumber: 2, episodeNumber: 3,
            posterURL: URL(string: "https://art.example.test/\(UUID())/episode.jpg")!,
            fallbackArtworkURL: URL(string: "https://art.example.test/\(UUID())/show.jpg")!
        )
        let visible = EpisodeArtworkSource(item: item, spoilerSettings: .default)
        let hidden = SpoilerSettings(isEnabled: true, mode: .placeholder)
        let safe = EpisodeArtworkSource(item: item, spoilerSettings: hidden)
        seedArtwork(.red, source: visible)
        seedArtwork(.green, source: safe)
        XCTAssertFalse(safe.references.contains(.remote(try XCTUnwrap(item.posterURL))))
        let protected = try artworkPixel(configuredArtwork(cell, item: item, spoilers: hidden))
        XCTAssertGreaterThan(protected[1], 220)
        XCTAssertLessThan(protected[0], 25)
        XCTAssertEqual(cell.accessibilityLabel, "Episode 3")
        XCTAssertEqual(views(in: cell, of: UILabel.self).first?.text, "Episode 3")

        item.resumePosition = 60
        let inProgress = try artworkPixel(configuredArtwork(cell, item: item, spoilers: hidden))
        XCTAssertGreaterThan(inProgress[0], 220, "In-progress episodes keep their own still.")
        XCTAssertEqual(cell.accessibilityLabel, "Episode 3")
        item.isPlayed = true
        _ = try configuredArtwork(cell, item: item, spoilers: hidden)
        XCTAssertEqual(cell.accessibilityLabel, item.title)
        XCTAssertEqual(views(in: cell, of: UILabel.self).first?.text, item.title)
    }

    func testProductionEpisodePanelUsesThePlayersSpoilerSettings() async throws {
        let playing = EpisodeRowProvider.episode(season: 2, number: 2)
        let player = PlayerViewModel(
            provider: EpisodeRowProvider(), itemID: playing.id, episodeItem: playing,
            spoilerSettings: .init(isEnabled: true, mode: .placeholder)
        )
        let browser = try XCTUnwrap(player.episodeBrowser)
        await browser.loadIfNeeded()
        try await withProductionPanel(player) { _, window in
            try await self.waitUntil { !self.nativePosters(in: window).isEmpty }
            let labels = self.nativePosters(in: window).compactMap(\.accessibilityLabel)
            XCTAssertTrue(labels.allSatisfy { $0.hasPrefix("Episode ") })
            XCTAssertFalse(labels.contains(playing.title))
        }
    }

    func testNativeEpisodeBlurDisappearsForInProgressArtwork() throws {
        let cell = PlayerEpisodeNativeCell()
        defer { cell.cancelArtwork() }
        var item = MediaItem(
            id: UUID().uuidString, title: "Hidden title", kind: .episode, episodeNumber: 4
        )
        let source = EpisodeArtworkSource(item: item, spoilerSettings: .default)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 160, height: 90)).image {
            UIColor.red.setFill()
            $0.fill(CGRect(x: 0, y: 0, width: 80, height: 90))
            UIColor.blue.setFill()
            $0.fill(CGRect(x: 80, y: 0, width: 80, height: 90))
        }
        seedArtwork(image, source: source)
        let hidden = SpoilerSettings(isEnabled: true, mode: .blur)
        let blurred = try artworkPixel(configuredArtwork(cell, item: item, spoilers: hidden), x: 0.47)
        XCTAssertGreaterThan(blurred[2], 20)
        XCTAssertLessThan(blurred[0], 230)
        XCTAssertEqual(cell.accessibilityLabel, "Episode 4")
        item.resumePosition = 30
        XCTAssertFalse(item.hasVisiblePlaybackProgress)
        XCTAssertTrue(hidden.shouldHideThumbnail(for: item))
        item.resumePosition = 60
        XCTAssertTrue(item.hasVisiblePlaybackProgress)
        XCTAssertFalse(hidden.shouldHideThumbnail(for: item))
        let visible = try artworkPixel(configuredArtwork(cell, item: item, spoilers: hidden), x: 0.47)
        XCTAssertGreaterThan(visible[0], 240)
        XCTAssertLessThan(visible[2], 10)
        XCTAssertEqual(cell.accessibilityLabel, "Episode 4")
    }

    func testLeavingCollectionReplacesArtworkButHorizontalMovesPreserveIt() async throws {
        let playing = EpisodeRowProvider.episode(season: 2, number: 2)
        let player = PlayerViewModel(provider: EpisodeRowProvider(), itemID: playing.id, episodeItem: playing)
        let browser = try XCTUnwrap(player.episodeBrowser)
        await browser.loadIfNeeded()
        try await withProductionPanel(player) { model, window in
            try await self.waitUntil { model.observedFocus == .button(.episodes) }
            let entry = try XCTUnwrap(browser.initialEntryID)
            model.target = entry
            try await self.waitUntil {
                (UIFocusSystem.focusSystem(for: window)?.focusedItem as? PlayerEpisodeNativeCell)?
                    .accessibilityLabel == playing.title
            }
            let cell = try XCTUnwrap(self.nativePosters(in: window).first(where: \.isFocused))
            let artwork = try XCTUnwrap(cell.contentView as? TVMediaItemContentView)
            let configuration = try XCTUnwrap(artwork.configuration as? TVMediaItemContentConfiguration)
            let next = try XCTUnwrap(browser.episodes.first { $0.item.id == "2-3" })
            try self.focusEpisode(next.id, in: window)
            try await self.waitUntil { !cell.isFocused }
            XCTAssertTrue(cell.contentView === artwork, "Horizontal browsing must not recreate artwork.")
            try self.focusEpisode(entry, in: window)
            try await self.waitUntil { cell.isFocused }
            let collection = try XCTUnwrap(self.scrollView(in: window) as? UICollectionView)
            let coordinator = try XCTUnwrap(collection.delegate as? PlayerEpisodeNativeRow.Coordinator)
            try await self.waitUntil {
                coordinator.focusAnimations == 0 && !browser.isLoadingPrevious && !browser.isLoadingNext
            }
            model.target = nil
            try await self.waitUntil { model.observedFocus == .button(.episodes) && !cell.isFocused }
            XCTAssertTrue(self.nativePosters(in: window).contains { $0 === cell })
            XCTAssertFalse(cell.contentView === artwork,
                           "Leaving for a SwiftUI tab must actually replace the native projection owner.")
            let replacement = try XCTUnwrap(cell.contentView as? TVMediaItemContentView)
            let replacementConfiguration = try XCTUnwrap(
                replacement.configuration as? TVMediaItemContentConfiguration
            )
            XCTAssertTrue(replacementConfiguration.image === configuration.image,
                          "Resetting focus must reuse the prepared artwork bitmap.")
        }
    }

    func testDisablingFocusedArtworkClearsPresentationBeforeUIKitMovesFocus() async throws {
        let provider = EpisodeRowProvider()
        let playing = EpisodeRowProvider.episode(season: 2, number: 2)
        let player = PlayerViewModel(provider: provider, itemID: playing.id, episodeItem: playing)
        let browser = try XCTUnwrap(player.episodeBrowser)
        await browser.loadIfNeeded()
        try await withProductionPanel(player) { model, window in
            try await self.waitUntil { model.observedFocus == .button(.episodes) }
            let entry = try XCTUnwrap(browser.episodes.first { $0.item.id == playing.id })
            model.target = entry.id
            try await self.waitUntil {
                (UIFocusSystem.focusSystem(for: window)?.focusedItem as? PlayerEpisodeNativeCell)?
                    .accessibilityLabel == playing.title
            }
            try await Task.sleep(for: .milliseconds(300))
            let cell = try XCTUnwrap(self.nativePosters(in: window).first(where: \.isFocused))
            let caption = try XCTUnwrap(self.views(in: cell, of: NativePosterCaptionLine.self).first)
            let layout = PlayerSequenceLayout(metrics: .tv, cardMetrics: .standard, contained: true, hasError: false)
            var environment = EnvironmentValues()
            environment.isEnabled = false
            cell.configure(.episode(entry), layout: layout, environment: environment)
            cell.updateConfiguration(using: cell.configurationState)
            cell.layoutIfNeeded()
            XCTAssertFalse(cell.canBecomeFocused)
            XCTAssertEqual(caption.transform.ty, 0, accuracy: 0.1,
                           "Parking must clear the caption without waiting for UIKit's focus departure.")
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
                XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = "Disabled episode artwork before focus departure"
            attachment.lifetime = .keepAlways
            self.add(attachment)
            let cgImage = try XCTUnwrap(image.cgImage)
            let scale = CGFloat(cgImage.width) / window.bounds.width
            let frame = cell.convert(cell.bounds, to: window)
            let crop = try XCTUnwrap(cgImage.cropping(to: CGRect(
                x: frame.midX * scale, y: frame.minY * scale, width: 1, height: 30 * scale
            ).integral))
            var pixels = [UInt8](repeating: 0, count: crop.width * crop.height * 4)
            let firstArtworkRow = try pixels.withUnsafeMutableBytes { bytes -> Int? in
                let context = try XCTUnwrap(CGContext(
                    data: bytes.baseAddress, width: crop.width, height: crop.height,
                    bitsPerComponent: 8, bytesPerRow: crop.width * 4,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                ))
                context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
                return (0..<crop.height).first {
                    let offset = $0 * crop.width * 4
                    return max(bytes[offset], bytes[offset + 1], bytes[offset + 2]) > 50
                }
            }
            XCTAssertEqual(CGFloat(try XCTUnwrap(firstArtworkRow)) / scale, 12, accuracy: 2,
                           "A disabled card must paint at resting size, even before the focus system catches up.")
        }
    }

    func testNativeMarqueePaintFadesBothEdgesAndKeepsRestingTextInsideTheFade() throws {
        for direction in [UISemanticContentAttribute.forceLeftToRight, .forceRightToLeft] {
            let caption = NativePosterCaptionLine()
            caption.semanticContentAttribute = direction
            caption.frame = CGRect(x: 0, y: 0, width: 240, height: 26)
            caption.configure(
                text: "A long episode name that extends beyond the caption's readable area",
                font: .systemFont(ofSize: 21), color: .white, scrolls: false,
                centersShortText: false, horizontalInset: 12
            )
            caption.layoutIfNeeded()
            let label = try XCTUnwrap(views(in: caption, of: UILabel.self).first)
            if direction == .forceLeftToRight {
                XCTAssertEqual(label.frame.minX, 12, accuracy: 0.1)
            } else {
                XCTAssertEqual(label.frame.maxX, 228, accuracy: 0.1)
            }
            // Solid test ink isolates the mask from individual glyph shapes.
            let ink = UIView(frame: caption.bounds)
            ink.backgroundColor = .white
            caption.addSubview(ink)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = false
            let rendered = UIGraphicsImageRenderer(size: caption.bounds.size, format: format).image {
                caption.layer.render(in: $0.cgContext)
            }
            let image = try XCTUnwrap(rendered.cgImage)
            var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
            try pixels.withUnsafeMutableBytes { bytes in
                let context = try XCTUnwrap(CGContext(
                    data: bytes.baseAddress, width: image.width, height: image.height,
                    bitsPerComponent: 8, bytesPerRow: image.width * 4,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                ))
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                let row = image.height / 2 * image.width
                XCTAssertLessThan(bytes[(row + 1) * 4 + 3], 60)
                XCTAssertGreaterThan(bytes[(row + 12) * 4 + 3], 245)
                XCTAssertGreaterThan(bytes[(row + image.width - 13) * 4 + 3], 245)
                XCTAssertLessThan(bytes[(row + image.width - 2) * 4 + 3], 60)
            }
        }
    }

    func testSingleLineEpisodeCaptionFollowsLeadingEdgeWhenDirectionChanges() throws {
        let layout = PlayerSequenceLayout(metrics: .tv, cardMetrics: .standard, contained: true, hasError: false)
        let cell = PlayerEpisodeNativeCell(frame: CGRect(x: 0, y: 0, width: layout.cardWidth, height: layout.rowHeight))
        let entry = PlayerEpisodeEntry(
            item: MediaItem(id: "episode", title: "A short title", kind: .episode),
            seasonID: "season", seasonNumber: 1
        )
        var environment = EnvironmentValues()
        for direction in [LayoutDirection.leftToRight, .rightToLeft, .leftToRight] {
            environment.layoutDirection = direction
            cell.configure(.episode(entry), layout: layout, environment: environment)
            cell.updateConfiguration(using: cell.configurationState)
            cell.layoutIfNeeded()
            let caption = try XCTUnwrap(views(in: cell, of: NativePosterCaptionLine.self).first)
            caption.layoutIfNeeded()
            let label = try XCTUnwrap(views(in: caption, of: UILabel.self).first)
            XCTAssertEqual(label.numberOfLines, 1)
            let inset = layout.cardMetrics.landscapeCaptionInset
            XCTAssertEqual(
                label.frame.minX,
                direction == .rightToLeft ? caption.bounds.width - inset - label.frame.width : inset,
                accuracy: 0.1
            )
            XCTAssertNil(label.layer.animation(forKey: "captionMarquee"))
        }
        cell.prepareForReuse()
        XCTAssertNil(cell.contentConfiguration)
        XCTAssertFalse(cell.canBecomeFocused)
    }

    func testPrependingEpisodesPreservesNativeFocusAndExactViewport() async throws {
        try await assertStablePrepend(direction: .leftToRight)
        try await assertStablePrepend(direction: .rightToLeft)
    }

    func testOpeningMiddleEpisodeShowsPreviousArtworkAndKeepsTheFocusedCardFullyVisible() async throws {
        for direction in [LayoutDirection.leftToRight, .rightToLeft] {
            let playing = EpisodeRowProvider.episode(season: 2, number: 2)
            let player = PlayerViewModel(provider: EpisodeRowProvider(), itemID: playing.id, episodeItem: playing)
            let browser = try XCTUnwrap(player.episodeBrowser)
            await browser.loadIfNeeded()
            try await withProductionPanel(player, direction: direction) { model, window in
                try await self.waitUntil {
                    !self.nativePosters(in: window).isEmpty && model.observedFocus == .button(.episodes)
                }
                try await Task.sleep(for: .milliseconds(200))
                let collection = try XCTUnwrap(self.scrollView(in: window) as? UICollectionView)
                let previous = try XCTUnwrap(self.nativePosters(in: window).first { $0.accessibilityLabel == "Season 2 Episode 1" })
                let viewport = collection.convert(collection.bounds, to: window)
                let artwork = previous.contentView.convert(previous.contentView.bounds, to: window)
                XCTAssertEqual(artwork.intersection(viewport).width, 24, accuracy: 1)
                let current = try XCTUnwrap(self.nativePosters(in: window).first { $0.accessibilityLabel == playing.title })
                let currentArtwork = current.contentView.convert(current.contentView.bounds, to: window)
                let gap = direction == .leftToRight
                    ? currentArtwork.minX - artwork.maxX : artwork.minX - currentArtwork.maxX
                XCTAssertEqual(gap, 52, accuracy: 1)
                model.target = browser.initialEntryID
                try await self.waitUntil {
                    (UIFocusSystem.focusSystem(for: window)?.focusedItem as? PlayerEpisodeNativeCell)?
                        .accessibilityLabel == playing.title
                }
                try await Task.sleep(for: .milliseconds(300))
                let focused = try XCTUnwrap(self.nativePosters(in: window).first(where: \.isFocused))
                XCTAssertTrue(viewport.contains(focused.convert(focused.bounds, to: window)))
                XCTAssertGreaterThanOrEqual(previous.contentView.convert(previous.contentView.bounds, to: window)
                    .intersection(viewport).width, 24,
                    "Native focus may reveal more of the previous card to fit its lift, but must not hide the peek.")
            }
            await player.stop()
        }
    }

    private func assertStablePrepend(direction: LayoutDirection) async throws {
        let provider = EpisodeRowProvider()
        await provider.hold("season-1")
        defer { Task { await provider.release("season-1") } }
        let playing = EpisodeRowProvider.episode(season: 2, number: 2)
        let player = PlayerViewModel(provider: provider, itemID: playing.id, episodeItem: playing)
        let browser = try XCTUnwrap(player.episodeBrowser)
        await browser.loadIfNeeded()
        let requests = await provider.requests
        XCTAssertEqual(requests, ["series", "season-2"])
        XCTAssertNil(browser.loadError)
        XCTAssertEqual(browser.episodes.map(\.item.id), (1...8).map { "2-\($0)" })
        try await withProductionPanel(player, direction: direction) { model, window in
            try await self.waitUntil {
                !self.views(in: window, of: PlayerEpisodeNativeCell.self).isEmpty && model.observedFocus == .button(.episodes)
            }
            let entry = try XCTUnwrap(browser.initialEntryID)
            model.target = entry
            try await self.waitUntil {
                (UIFocusSystem.focusSystem(for: window)?.focusedItem as? PlayerEpisodeNativeCell)?
                    .accessibilityLabel == playing.title
            }
            try await self.waitUntil { await provider.isHolding("season-1") }
            for number in [3, 2] {
                let target = try XCTUnwrap(browser.episodes.first { $0.item.id == "2-\(number)" })
                try self.focusEpisode(target.id, in: window)
                try await self.waitUntil {
                    (UIFocusSystem.focusSystem(for: window)?.focusedItem as? PlayerEpisodeNativeCell)?
                        .accessibilityLabel == target.item.title
                }
            }
            try await Task.sleep(for: .milliseconds(300))
            let poster = try XCTUnwrap(UIFocusSystem.focusSystem(for: window)?.focusedItem as? PlayerEpisodeNativeCell)
            let scroll = try XCTUnwrap(self.scrollView(in: window))
            try await self.waitUntil { !scroll.isDecelerating && !scroll.isDragging }
            // Preserve even a viewport parked between card slots.
            scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x + 47, y: 0), animated: false)
            try await Task.sleep(for: .milliseconds(100))
            let frame = poster.convert(poster.bounds, to: window)
            let width = scroll.contentSize.width
            let count = browser.episodes.count
            await provider.release("season-1")
            try await self.waitUntil { browser.episodes.count >= count + 8 && scroll.contentSize.width > width + 1000 }
            for _ in 0..<20 {
                try await Task.sleep(for: .milliseconds(20))
                XCTAssertTrue(UIFocusSystem.focusSystem(for: window)?.focusedItem === poster)
                XCTAssertEqual(model.observedFocus, .episodeItem(entry))
                XCTAssertEqual(poster.convert(poster.bounds, to: window).minX, frame.minX, accuracy: 1,
                               "Prepending must preserve the offset within the card, not realign it.")
            }
        }
    }

    func testPrependFinishingDuringNativeFocusTransitionNeverMovesFocusToAnotherEpisode() async throws {
        let provider = EpisodeRowProvider()
        await provider.hold("season-1")
        defer { Task { await provider.release("season-1") } }
        let playing = EpisodeRowProvider.episode(season: 2, number: 2)
        let player = PlayerViewModel(provider: provider, itemID: playing.id, episodeItem: playing)
        let browser = try XCTUnwrap(player.episodeBrowser)
        await browser.loadIfNeeded()
        try await withProductionPanel(player) { model, window in
            try await self.waitUntil {
                !self.views(in: window, of: PlayerEpisodeNativeCell.self).isEmpty && model.observedFocus == .button(.episodes)
            }
            model.target = browser.initialEntryID
            try await self.waitUntil {
                UIFocusSystem.focusSystem(for: window)?.focusedItem is PlayerEpisodeNativeCell
            }
            for number in [2, 3, 2] {
                let entry = try XCTUnwrap(browser.episodes.first { $0.item.id == "2-\(number)" })
                try self.focusEpisode(entry.id, in: window)
                try await self.waitUntil {
                    (UIFocusSystem.focusSystem(for: window)?.focusedItem as? PlayerEpisodeNativeCell)?
                        .accessibilityLabel == entry.item.title
                }
            }
            try await self.waitUntil { await provider.isHolding("season-1") }
            let poster = try XCTUnwrap(UIFocusSystem.focusSystem(for: window)?.focusedItem as? PlayerEpisodeNativeCell)
            let scroll = try XCTUnwrap(self.scrollView(in: window))
            let width = scroll.contentSize.width
            let count = browser.episodes.count
            let coordinator = try XCTUnwrap((scroll as? UICollectionView)?.delegate as? PlayerEpisodeNativeRow.Coordinator)
            XCTAssertGreaterThan(coordinator.focusAnimations, 0, "Complete the request during a native focus transition.")
            await provider.release("season-1")
            var priorX = poster.convert(poster.bounds, to: window).minX
            for _ in 0..<75 {
                try await Task.sleep(for: .milliseconds(20))
                XCTAssertTrue(UIFocusSystem.focusSystem(for: window)?.focusedItem === poster)
                let x = poster.convert(poster.bounds, to: window).minX
                XCTAssertLessThan(abs(x - priorX), 80, "Loading must not snap the viewport.")
                priorX = x
            }
            XCTAssertGreaterThanOrEqual(browser.episodes.count, count + 8)
            XCTAssertGreaterThan(scroll.contentSize.width, width + 1000, "Apply the loaded season after scrolling settles.")
        }
    }

    func testAppendingEpisodesPreservesFocusAfterMovingLeftDuringLoading() async throws {
        let provider = EpisodeRowProvider()
        await provider.hold("season-3")
        defer { Task { await provider.release("season-3") } }
        let playing = EpisodeRowProvider.episode(season: 2, number: 7)
        let player = PlayerViewModel(provider: provider, itemID: playing.id, episodeItem: playing)
        let browser = try XCTUnwrap(player.episodeBrowser)
        await browser.loadIfNeeded()
        try await withProductionPanel(player) { model, window in
            try await self.waitUntil {
                !self.views(in: window, of: PlayerEpisodeNativeCell.self).isEmpty && model.observedFocus == .button(.episodes)
            }
            model.target = browser.initialEntryID
            try await self.waitUntil {
                UIFocusSystem.focusSystem(for: window)?.focusedItem is PlayerEpisodeNativeCell
            }
            for number in [8, 7] {
                let target = try XCTUnwrap(browser.episodes.first { $0.item.id == "2-\(number)" })
                try self.focusEpisode(target.id, in: window)
                try await self.waitUntil {
                    (UIFocusSystem.focusSystem(for: window)?.focusedItem as? PlayerEpisodeNativeCell)?
                        .accessibilityLabel == target.item.title
                }
            }
            try await self.waitUntil { await provider.isHolding("season-3") }
            let scroll = try XCTUnwrap(self.scrollView(in: window))
            try await self.waitUntil { !scroll.isDecelerating && !scroll.isDragging }
            try await Task.sleep(for: .milliseconds(100))
            let poster = try XCTUnwrap(UIFocusSystem.focusSystem(for: window)?.focusedItem as? PlayerEpisodeNativeCell)
            let frame = poster.convert(poster.bounds, to: window)
            let count = browser.episodes.count
            await provider.release("season-3")
            try await self.waitUntil { browser.episodes.count == count + 8 }
            for _ in 0..<20 {
                try await Task.sleep(for: .milliseconds(20))
                XCTAssertTrue(UIFocusSystem.focusSystem(for: window)?.focusedItem === poster)
                XCTAssertEqual(poster.convert(poster.bounds, to: window).minX, frame.minX, accuracy: 1)
            }
        }
    }

    func testProductionEpisodePanelAcquiresBrowseFocusAcrossWindowHandoffs() async throws {
        let playing = EpisodeRowProvider.episode(season: 2, number: 7)
        let player = PlayerViewModel(provider: EpisodeRowProvider(), itemID: playing.id, episodeItem: playing)
        let browser = try XCTUnwrap(player.episodeBrowser)
        await browser.loadIfNeeded()
        for _ in 0..<3 {
            try await withProductionPanel(player) { model, window in
                XCTAssertEqual(model.observedFocus, .button(.episodes))
                let system = try XCTUnwrap(UIFocusSystem.focusSystem(for: window))
                XCTAssertNotNil(system.focusedItem)
                XCTAssertFalse(self.nativePosters(in: window).contains(where: \.isFocused))
                model.target = browser.initialEntryID
                try await self.waitUntil {
                    (system.focusedItem as? PlayerEpisodeNativeCell)?.accessibilityLabel == playing.title
                }
                let collection = try XCTUnwrap(self.scrollView(in: window) as? UICollectionView)
                let coordinator = try XCTUnwrap(collection.delegate as? PlayerEpisodeNativeRow.Coordinator)
                model.target = nil
                try await self.waitUntil {
                    model.observedFocus == .button(.episodes) && coordinator.focusAnimations == 0
                }
                XCTAssertNotNil(system.focusedItem)
                XCTAssertFalse(system.focusedItem is PlayerEpisodeNativeCell,
                               "A deferred episode request must not steal focus back from Browse.")
            }
        }
    }

    func testLeadingRetryInsertionAndSelectionPreserveTheEpisodeViewport() async throws {
        let provider = EpisodeRowProvider()
        await provider.hold("season-1")
        await provider.failNext("season-1")
        defer { Task { await provider.release("season-1") } }
        let playing = EpisodeRowProvider.episode(season: 2, number: 2)
        let player = PlayerViewModel(provider: provider, itemID: playing.id, episodeItem: playing)
        let browser = try XCTUnwrap(player.episodeBrowser)
        await browser.loadIfNeeded()
        try await withProductionPanel(player) { model, window in
            try await self.waitUntil { model.observedFocus == .button(.episodes) }
            model.target = browser.initialEntryID
            try await self.waitUntil {
                UIFocusSystem.focusSystem(for: window)?.focusedItem is PlayerEpisodeNativeCell
            }
            try await self.waitUntil { await provider.isHolding("season-1") }
            let cell = try XCTUnwrap(UIFocusSystem.focusSystem(for: window)?.focusedItem as? PlayerEpisodeNativeCell)
            let collection = try XCTUnwrap(self.scrollView(in: window) as? UICollectionView)
            let source = try XCTUnwrap(collection.dataSource as? UICollectionViewDiffableDataSource<Int, NativeEpisodeElement.ID>)
            try await Task.sleep(for: .milliseconds(300))
            let x = cell.convert(cell.bounds, to: window).minX
            await provider.release("season-1")
            try await self.waitUntil { source.indexPath(for: .previousError) != nil }
            XCTAssertTrue(UIFocusSystem.focusSystem(for: window)?.focusedItem === cell)
            XCTAssertEqual(cell.convert(cell.bounds, to: window).minX, x, accuracy: 1)
            let retry = try XCTUnwrap(source.indexPath(for: .previousError))
            collection.delegate?.collectionView?(collection, didSelectItemAt: retry)
            try await self.waitUntil {
                browser.previousLoadError == nil && browser.episodes.first?.seasonNumber == 1
                    && source.indexPath(for: .previousError) == nil
            }
            try await Task.sleep(for: .milliseconds(150))
            XCTAssertTrue(UIFocusSystem.focusSystem(for: window)?.focusedItem === cell)
            XCTAssertEqual(cell.convert(cell.bounds, to: window).minX, x, accuracy: 1)
        }
    }

    func testInitialLoadingUsesNonfocusableSkeletonsAndDoesNotStealBrowseFocus() async throws {
        let provider = EpisodeRowProvider()
        await provider.hold("series")
        defer { Task { await provider.release("series") } }
        let playing = EpisodeRowProvider.episode(season: 2, number: 2)
        let player = PlayerViewModel(provider: provider, itemID: playing.id, episodeItem: playing)
        let browser = try XCTUnwrap(player.episodeBrowser)
        try await withProductionPanel(player) { model, window in
            try await self.waitUntil { await provider.isHolding("series") }
            try await self.waitUntil { model.observedFocus == .button(.episodes) }
            XCTAssertFalse(browser.hasLoaded)
            XCTAssertTrue(self.views(in: window, of: PlayerEpisodeNativeCell.self).isEmpty)
            XCTAssertTrue(self.views(in: window, of: UIActivityIndicatorView.self).isEmpty)
            let before = try XCTUnwrap(UIFocusSystem.focusSystem(for: window)?.focusedItem)
            let loadingScroll = try XCTUnwrap(self.scrollView(in: window))
            let scrollFrame = loadingScroll.convert(loadingScroll.bounds, to: window)
            let attachment = XCTAttachment(image: DetailTransitionSnapshot.image(of: window))
            attachment.name = "Episode loading skeleton"
            attachment.lifetime = .keepAlways
            self.add(attachment)
            await provider.release("series")
            try await self.waitUntil { browser.hasLoaded && !self.views(in: window, of: PlayerEpisodeNativeCell.self).isEmpty }
            try await Task.sleep(for: .milliseconds(250))
            XCTAssertTrue(UIFocusSystem.focusSystem(for: window)?.focusedItem === before)
            XCTAssertEqual(model.observedFocus, .button(.episodes))
            let loadedScroll = try XCTUnwrap(self.scrollView(in: window))
            XCTAssertEqual(loadedScroll.convert(loadedScroll.bounds, to: window).height, scrollFrame.height, accuracy: 1)
        }
    }

    func testLoadingArtworkMatchesResolvedEpisodeFramesIncludingThePreviousPeek() async throws {
        for direction in [LayoutDirection.leftToRight, .rightToLeft] {
            for number in [1, 2] {
                let provider = EpisodeRowProvider()
                await provider.hold("series")
                let playing = EpisodeRowProvider.episode(season: 1, number: number)
                let player = PlayerViewModel(provider: provider, itemID: playing.id, episodeItem: playing)
                let browser = try XCTUnwrap(player.episodeBrowser)
                try await withProductionPanel(player, direction: direction) { model, window in
                    try await self.waitUntil { await provider.isHolding("series") }
                    try await self.waitUntil { model.observedFocus == .button(.episodes) }
                    try await Task.sleep(for: .milliseconds(150))
                    let skeleton = try XCTUnwrap(DetailTransitionSnapshot.image(of: window))
                    let loadingAttachment = XCTAttachment(image: skeleton)
                    loadingAttachment.name = "Episode \(number) skeleton \(direction)"
                    loadingAttachment.lifetime = .keepAlways
                    self.add(loadingAttachment)
                    await provider.release("series")
                    try await self.waitUntil { browser.hasLoaded && !self.nativePosters(in: window).isEmpty }
                    try await Task.sleep(for: .milliseconds(200))
                    let cell = try XCTUnwrap(self.nativePosters(in: window).first { $0.accessibilityLabel == playing.title })
                    let artwork = cell.contentView.convert(cell.contentView.bounds, to: window)
                    for edge in [
                        (CGPoint(x: artwork.minX + 4, y: artwork.midY), CGPoint(x: artwork.minX - 4, y: artwork.midY)),
                        (CGPoint(x: artwork.maxX - 4, y: artwork.midY), CGPoint(x: artwork.maxX + 4, y: artwork.midY)),
                        (CGPoint(x: artwork.midX, y: artwork.minY + 4), CGPoint(x: artwork.midX, y: artwork.minY - 4)),
                        (CGPoint(x: artwork.midX, y: artwork.maxY - 4), CGPoint(x: artwork.midX, y: artwork.maxY + 4))
                    ] {
                        let inside = try self.brightness(of: skeleton, at: edge.0, in: window)
                        let outside = try self.brightness(of: skeleton, at: edge.1, in: window)
                        XCTAssertGreaterThan(inside - outside, 8,
                                             "Skeleton must paint the same artwork edges as loaded episode \(number), \(direction): \(artwork)")
                    }
                    if number > 1 {
                        let previous = try XCTUnwrap(self.nativePosters(in: window).first { $0.accessibilityLabel == "Season 1 Episode 1" })
                        let collection = try XCTUnwrap(self.scrollView(in: window))
                        let viewport = collection.convert(collection.bounds, to: window)
                        let peek = previous.contentView.convert(previous.contentView.bounds, to: window).intersection(viewport)
                        XCTAssertEqual(peek.width, 24, accuracy: 1)
                        let peekInk = try self.brightness(of: skeleton, at: CGPoint(x: peek.midX, y: peek.midY), in: window)
                        let gap = CGPoint(x: direction == .leftToRight ? peek.maxX + 8 : peek.minX - 8, y: peek.midY)
                        let gapInk = try self.brightness(of: skeleton, at: gap, in: window)
                        XCTAssertGreaterThan(peekInk - gapInk, 8)
                    }
                    let loadedAttachment = XCTAttachment(image: DetailTransitionSnapshot.image(of: window))
                    loadedAttachment.name = "Episode \(number) loaded \(direction)"
                    loadedAttachment.lifetime = .keepAlways
                    self.add(loadedAttachment)
                }
                await player.stop()
            }
        }
    }

    private func brightness(of image: UIImage, at point: CGPoint, in window: UIWindow) throws -> Int {
        let source = try XCTUnwrap(image.cgImage)
        let scale = CGFloat(source.width) / window.bounds.width
        let crop = try XCTUnwrap(source.cropping(to: CGRect(
            x: point.x * scale, y: point.y * scale, width: 1, height: 1
        )))
        var pixel = [UInt8](repeating: 0, count: 4)
        try pixel.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(
                data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return Int(pixel[0]) + Int(pixel[1]) + Int(pixel[2])
    }

    func testReopeningEpisodesWhileCancelledRequestDrainsLoadsWithoutAnotherTabChange() async throws {
        let provider = EpisodeRowProvider()
        await provider.hold("series")
        defer { Task { await provider.release("series") } }
        let playing = EpisodeRowProvider.episode(season: 2, number: 2)
        let player = PlayerViewModel(provider: provider, itemID: playing.id, episodeItem: playing)
        let browser = try XCTUnwrap(player.episodeBrowser)
        try await withProductionPanel(player) { model, window in
            try await self.waitUntil { await provider.isHolding("series") }
            model.panelVisible = false
            try await self.waitUntil { model.panelDisappearances == 1 }
            model.panelVisible = true
            try await self.waitUntil { model.panelAppearances == 2 }
            XCTAssertTrue(browser.isLoading, "Hold the cancelled request until the new panel is present.")
            await provider.release("series")
            try await self.waitUntil { browser.hasLoaded && !self.nativePosters(in: window).isEmpty }
            XCTAssertNil(browser.loadError)
            XCTAssertEqual(model.panelAppearances, 2, "No extra reopen should be required.")
            let requests = await provider.requests
            XCTAssertEqual(requests.filter { $0 == "series" }.count, 2)
            XCTAssertTrue(browser.episodes.contains { $0.item.id == playing.id })
        }
        await player.stop()
    }

    func testChangingRetainedSequencePanelFromPlaylistToEpisodesStartsLoading() async throws {
        let provider = EpisodeRowProvider()
        let playing = EpisodeRowProvider.episode(season: 2, number: 2)
        let player = PlayerViewModel(provider: provider, itemID: playing.id, episodeItem: playing)
        let browser = try XCTUnwrap(player.episodeBrowser)
        try await withProductionPanel(player, initialSource: .playlist) { model, window in
            try await self.waitUntil { model.panelAppearances == 1 }
            XCTAssertFalse(browser.hasLoaded)
            model.source = .episodes
            try await self.waitUntil { browser.hasLoaded && !self.nativePosters(in: window).isEmpty }
            XCTAssertEqual(model.panelAppearances, 1, "The source change must rerun loading without remounting.")
            XCTAssertNil(browser.loadError)
        }
        await player.stop()
    }

    func testOnlyCurrentArtworkKeepsNativeFocusAndOverflowStaysInsidePanel() async throws {
        try await waitUntil {
            UIApplication.shared.connectedScenes.contains { $0.activationState == .foregroundActive }
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let model = EpisodeArtworkFixtureModel()
        let entries = (1...6).map { (number: Int) in
            PlayerEpisodeEntry(
                item: MediaItem(
                    id: "episode-\(number)",
                    title: number == 3
                        ? "An episode with a long title that must scroll without widening the artwork or wrapping"
                        : "Episode \(number)",
                    kind: .episode, episodeNumber: number
                ),
                seasonID: "season", seasonNumber: 2
            )
        }
        let host = UIHostingController(rootView: EpisodeArtworkFixture(
            model: model, entries: entries
        ))
        window.rootViewController = host
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }

        try await waitUntil { !self.nativePosters(in: window).isEmpty }
        for index in [0, 1, 2, 3, 2] {
            if index == 0 {
                model.target = entries[index].id
            } else {
                try focusEpisode(entries[index].id, in: window)
            }
            try await waitUntil {
                (UIFocusSystem.focusSystem(for: window)?.focusedItem as? PlayerEpisodeNativeCell)?
                    .accessibilityLabel == entries[index].item.title
            }
            try await Task.sleep(for: .milliseconds(250))
            let posters = nativePosters(in: window)
            XCTAssertEqual(posters.filter(\.isFocused).count, 1)
            XCTAssertEqual(model.observedFocus, .episodeItem(entries[index].id))
            XCTAssertTrue(posters.filter { $0.accessibilityLabel != entries[index].item.title }
                .allSatisfy { !$0.isFocused })
            XCTAssertTrue(posters.filter(\.isFocused).allSatisfy {
                guard let media = self.views(in: $0, of: TVMediaItemContentView.self).first,
                      let configuration = media.configuration as? TVMediaItemContentConfiguration else { return false }
                return configuration.text?.isEmpty != false && configuration.secondaryText?.isEmpty != false
            },
                          "Titles must remain outside the native artwork projection.")
        }

        let focused = try XCTUnwrap(nativePosters(in: window).first(where: \.isFocused))
        let media = try XCTUnwrap(views(in: focused, of: TVMediaItemContentView.self).first)
        let caption = try XCTUnwrap(views(in: focused, of: NativePosterCaptionLine.self).first)
        let label = try XCTUnwrap(views(in: caption, of: UILabel.self).first)
        XCTAssertEqual(label.numberOfLines, 1)
        XCTAssertEqual(caption.bounds.height, caption.lineHeight, accuracy: 0.1)
        XCTAssertGreaterThan(media.bounds.height, 205)
        let travel: CGFloat = 8
        XCTAssertEqual(caption.transform.ty, travel, accuracy: 0.1)
        XCTAssertEqual(media.frame.minY, focused.bounds.maxY - caption.frame.maxY + travel, accuracy: 0.1,
                       "Resting insets remain balanced; focus only moves the caption down.")
        XCTAssertEqual(caption.bounds.width, media.bounds.width)
        let mask = try XCTUnwrap(caption.layer.mask as? CAGradientLayer)
        let colors = try XCTUnwrap(mask.colors as? [CGColor])
        XCTAssertEqual(colors.map(\.alpha), [0, 1, 1, 0])
        try await waitUntil { abs(label.layer.presentation()?.transform.m41 ?? 0) > 2 }
        XCTAssertNotNil(label.layer.animation(forKey: "captionMarquee"))
        for other in nativePosters(in: window) where other !== focused {
            for title in views(in: other, of: NativePosterCaptionLine.self).flatMap({ views(in: $0, of: UILabel.self) }) {
                XCTAssertNil(title.layer.animation(forKey: "captionMarquee"))
            }
        }
        let configuration = try XCTUnwrap(media.configuration as? TVMediaItemContentConfiguration)
        let projectedImage = try XCTUnwrap(configuration.image?.cgImage)
        var artworkPixels = [UInt8](repeating: 0, count: projectedImage.width * projectedImage.height * 4)
        let artworkContext = try XCTUnwrap(CGContext(
            data: &artworkPixels, width: projectedImage.width, height: projectedImage.height,
            bitsPerComponent: 8, bytesPerRow: projectedImage.width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        artworkContext.draw(projectedImage, in: CGRect(x: 0, y: 0, width: projectedImage.width, height: projectedImage.height))
        XCTAssertGreaterThan(stride(from: 0, to: artworkPixels.count, by: 4).filter {
            min(artworkPixels[$0], artworkPixels[$0 + 1], artworkPixels[$0 + 2]) > 230
        }.count, 20, "The native focus projection must include the white season/episode label.")

        let screenshot = DetailTransitionSnapshot.image(of: window)
        let image = try XCTUnwrap(screenshot.cgImage)
        let scale = CGFloat(image.width) / window.bounds.width
        for x: CGFloat in [448, 1468] {
            let strip = try XCTUnwrap(image.cropping(to: CGRect(
                x: x * scale, y: 440 * scale, width: 4 * scale, height: 180 * scale
            )))
            var pixels = [UInt8](repeating: 0, count: strip.width * strip.height * 4)
            let context = try XCTUnwrap(CGContext(
                data: &pixels, width: strip.width, height: strip.height,
                bitsPerComponent: 8, bytesPerRow: strip.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(strip, in: CGRect(x: 0, y: 0, width: strip.width, height: strip.height))
            let brightPixels = stride(from: 0, to: pixels.count, by: 4).filter {
                max(pixels[$0], pixels[$0 + 1], pixels[$0 + 2]) > 30
            }
            XCTAssertTrue(brightPixels.isEmpty,
                          "Artwork and native focus projection must not bleed past the panel.")
        }
        let attachment = XCTAttachment(image: screenshot)
        attachment.name = "Episode row native focus and clipped edges"
        attachment.lifetime = .keepAlways
        add(attachment)
        try focusEpisode(entries[1].id, in: window)
        try await waitUntil {
            !focused.isFocused && label.layer.animation(forKey: "captionMarquee") == nil
        }
        XCTAssertEqual(label.layer.transform.m41, 0, accuracy: 0.1,
                       "Leaving focus must restore the beginning of the title.")
        try await waitUntil {
            abs(caption.layer.presentation()?.transform.m42 ?? caption.layer.transform.m42) < 0.1
        }
        XCTAssertEqual(caption.transform.ty, 0, accuracy: 0.1)
    }

    private func seedArtwork(_ color: UIColor, source: EpisodeArtworkSource) {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 160, height: 90)).image {
            color.setFill()
            $0.fill(CGRect(x: 0, y: 0, width: 160, height: 90))
        }
        seedArtwork(image, source: source)
    }

    private func seedArtwork(_ image: UIImage, source: EpisodeArtworkSource) {
        ArtworkSeedMemo.store(
            FirstPaintArtwork(
                image: image, reference: .remote(URL(string: "https://art.example.test/\(UUID()).jpg")!),
                variant: .landscapeCard
            ), for: source.requestIdentity
        )
    }

    private func configuredArtwork(
        _ cell: PlayerEpisodeNativeCell, item: MediaItem, spoilers: SpoilerSettings = .default
    ) throws -> UIImage {
        let layout = PlayerSequenceLayout(metrics: .tv, cardMetrics: .standard, contained: true, hasError: false)
        var environment = EnvironmentValues()
        environment.locale = Locale(identifier: "en_US")
        environment.displayScale = 1
        cell.frame = CGRect(x: 0, y: 0, width: layout.cardWidth, height: layout.rowHeight)
        cell.configure(
            .episode(PlayerEpisodeEntry(item: item, seasonID: "season", seasonNumber: 2)),
            layout: layout, environment: environment, spoilerSettings: spoilers
        )
        cell.updateConfiguration(using: cell.configurationState)
        cell.layoutIfNeeded()
        let content = try XCTUnwrap(cell.contentView as? TVMediaItemContentView)
        return try XCTUnwrap((content.configuration as? TVMediaItemContentConfiguration)?.image)
    }

    private func artworkPixel(_ image: UIImage, x: CGFloat = 0.5) throws -> [UInt8] {
        let source = try XCTUnwrap(image.cgImage)
        let crop = try XCTUnwrap(source.cropping(to: CGRect(
            x: CGFloat(source.width) * x, y: CGFloat(source.height) / 3, width: 1, height: 1
        )))
        var pixel = [UInt8](repeating: 0, count: 4)
        try pixel.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(
                data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return pixel
    }

    private func focusEpisode(_ id: PlayerEpisodeEntry.ID, in window: UIWindow) throws {
        let collection = try XCTUnwrap(scrollView(in: window) as? UICollectionView)
        let dataSource = try XCTUnwrap(collection.dataSource as? UICollectionViewDiffableDataSource<Int, NativeEpisodeElement.ID>)
        let index = try XCTUnwrap(dataSource.indexPath(for: .episode(id)))
        if collection.cellForItem(at: index) == nil {
            collection.scrollToItem(at: index, at: [], animated: false)
            collection.layoutIfNeeded()
        }
        let coordinator = try XCTUnwrap(collection.delegate as? PlayerEpisodeNativeRow.Coordinator)
        coordinator.requestFocus(at: index)
    }

    private func nativePosters(in view: UIView) -> [PlayerEpisodeNativeCell] {
        (view as? PlayerEpisodeNativeCell).map { [$0] } ?? view.subviews.flatMap { nativePosters(in: $0) }
    }

    private func scrollView(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView { return scroll }
        return view.subviews.lazy.compactMap { self.scrollView(in: $0) }.first
    }

    private func views<T: UIView>(in view: UIView, of type: T.Type) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { views(in: $0, of: type) }
    }

    private func withProductionPanel(
        _ player: PlayerViewModel,
        direction: LayoutDirection = .leftToRight,
        initialSource: PlayerSequencePanel.Source = .episodes,
        body: (EpisodeArtworkFixtureModel, UIWindow) async throws -> Void
    ) async throws {
        try await waitUntil {
            UIApplication.shared.connectedScenes.contains { $0.activationState == .foregroundActive }
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let model = EpisodeArtworkFixtureModel()
        model.source = initialSource
        let host = UIHostingController(rootView: ProductionEpisodeFixture(
            player: player, model: model
        ).environment(\.layoutDirection, direction))
        window.rootViewController = host
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        let focusSystem = try XCTUnwrap(UIFocusSystem.focusSystem(for: window))
        // Activate native focus before reissuing the fixture's SwiftUI entry request.
        try await waitUntil {
            window.layoutIfNeeded()
            focusSystem.requestFocusUpdate(to: host)
            focusSystem.updateFocusIfNeeded()
            return focusSystem.focusedItem != nil
        }
        model.focusRequestID = UUID()
        try await waitUntil {
            model.appliedFocusRequestID == model.focusRequestID
                && model.observedFocus == .button(.episodes) && focusSystem.focusedItem != nil
                && !(focusSystem.focusedItem is PlayerEpisodeNativeCell)
        }
        do {
            try await body(model, window)
        } catch {
            let image = XCTAttachment(image: DetailTransitionSnapshot.image(of: window))
            image.name = "Episode panel failure"
            image.lifetime = .keepAlways
            add(image)
            let focused = focusSystem.focusedItem as? NSObject
            let scroll = scrollView(in: window)
            let coordinator = (scroll as? UICollectionView)?.delegate as? PlayerEpisodeNativeRow.Coordinator
            let state = XCTAttachment(string: """
                Requested episode: \(String(describing: model.target))
                Observed focus: \(String(describing: model.observedFocus))
                Native focus label: \(focused?.accessibilityLabel ?? "nil")
                Focus animations: \(String(describing: coordinator?.focusAnimations))
                Scroll offset: \(String(describing: scroll?.contentOffset))
                Cells: \(nativePosters(in: window).map { "\($0.accessibilityLabel ?? "nil"): focusable=\($0.canBecomeFocused), focused=\($0.isFocused)" })
                """)
            state.name = "Episode panel focus state"
            state.lifetime = .keepAlways
            add(state)
            throw error
        }
    }

    private func waitUntil(
        file: StaticString = #filePath, line: UInt = #line,
        _ condition: () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Timed out waiting for the episode row.", file: file, line: line)
        throw EpisodeArtworkFixtureError.focusTimeout
    }
}

@MainActor
private final class CardTabFocusHost<Content: View>: UIHostingController<Content> {
    weak var target: (any UIFocusEnvironment)?
    override var preferredFocusEnvironments: [any UIFocusEnvironment] {
        target.map { [$0] } ?? super.preferredFocusEnvironments
    }
}

@MainActor
private func cardTabFocusFrame(_ item: any UIFocusItem, in window: UIWindow) -> CGRect? {
    var environment: (any UIFocusEnvironment)? = item
    while let current = environment {
        if let container = current.focusItemContainer {
            return container.coordinateSpace.convert(item.frame, to: window)
        }
        environment = current.parentFocusEnvironment
    }
    return nil
}

@MainActor
private func cardTabFocusItems(in window: UIWindow) -> [any UIFocusItem] {
    var containers: [any UIFocusItemContainer] = [window]
    var seen = Set<ObjectIdentifier>()
    var items: [ObjectIdentifier: any UIFocusItem] = [:]
    while let container = containers.popLast() {
        guard seen.insert(ObjectIdentifier(container)).inserted else { continue }
        for item in container.focusItems(in: container.coordinateSpace.convert(window.bounds, from: window)) {
            if let child = item.focusItemContainer { containers.append(child) }
            if let view = item as? UIView { containers.append(view) }
            if item.canBecomeFocused, !(item is UIScrollView) { items[ObjectIdentifier(item)] = item }
        }
    }
    return Array(items.values)
}

@MainActor
private final class CardTabFocusRecorder: NSObject {
    var tabs: [String] = []
    weak var window: UIWindow?
    let model: PlayerControlsModel

    init(window: UIWindow, model: PlayerControlsModel) {
        self.window = window
        self.model = model
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(record(_:)), name: UIFocusSystem.didUpdateNotification, object: nil
        )
    }

    @objc private func record(_ notification: Notification) {
        guard let context = notification.userInfo?[UIFocusSystem.focusUpdateContextUserInfoKey]
            as? UIFocusUpdateContext, let item = context.nextFocusedItem, let window,
              let frame = cardTabFocusFrame(item, in: window) else { return }
        let center = CGPoint(x: frame.midX, y: frame.midY)
        for tab in ["info", "chapters", "cast"] where model.subtitleLayout.frame(for: .tab(tab))?.contains(center) == true {
            tabs.append(tab)
        }
    }
}

private enum EpisodeArtworkFixtureError: Error { case focusTimeout }

@MainActor @Observable
private final class EpisodeArtworkFixtureModel {
    var target: PlayerEpisodeEntry.ID?
    var focusRequestID = UUID()
    var appliedFocusRequestID: UUID?
    var observedFocus: PlayerControls.FocusSlot?
    var panelVisible = true
    var source: PlayerSequencePanel.Source = .episodes
    var panelAppearances = 0
    var panelDisappearances = 0
}

private struct EpisodeArtworkFixture: View {
    let model: EpisodeArtworkFixtureModel
    let entries: [PlayerEpisodeEntry]
    @FocusState private var focus: PlayerControls.FocusSlot?
    @State private var currentID: PlayerEpisodeEntry.ID?
    private let layout = PlayerSequenceLayout(
        metrics: .tv, cardMetrics: .standard, contained: true, hasError: false
    )

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            PlayerEpisodeNativeRow(
                items: entries.map(NativeEpisodeElement.episode), initialID: entries.first?.id,
                layout: layout, focus: $focus, onVisible: { _ in },
                onFocus: { currentID = $0 }, onSelect: { _ in }
            )
                .frame(height: layout.rowHeight)
                .modifier(PlayerEpisodePanelSurface(layout: layout))
                .frame(width: 1000)
                .focused($focus, equals: (currentID ?? entries.first?.id).map(PlayerControls.FocusSlot.episodeItem))
                .onChange(of: currentID) { _, id in
                    if let id { focus = .episodeItem(id) }
                }
                .onChange(of: model.target) { _, id in
                    if let id { focus = .episodeItem(id) }
                }
        }
        .environment(\.plozzCardFocusStyle, .system)
        .onChange(of: focus) { _, value in model.observedFocus = value }
    }
}

private struct ProductionEpisodeFixture: View {
    let player: PlayerViewModel
    let model: EpisodeArtworkFixtureModel
    @FocusState private var focus: PlayerControls.FocusSlot?

    var body: some View {
        VStack {
            Button("Browse") {}
                .focused($focus, equals: .button(.episodes))
            if model.panelVisible {
                PlayerSequencePanel(player: player, source: model.source, focus: $focus)
                    .frame(width: 1000)
                    .onAppear { model.panelAppearances += 1 }
                    .onDisappear { model.panelDisappearances += 1 }
            }
        }
        .defaultFocus($focus, .button(.episodes), priority: .userInitiated)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
        .environment(\.plozzCardFocusStyle, .system)
        .task(id: model.focusRequestID) {
            let requestID = model.focusRequestID
            focus = nil
            await Task.yield()
            guard !Task.isCancelled else { return }
            focus = .button(.episodes)
            model.appliedFocusRequestID = requestID
        }
        .onChange(of: model.target) { _, id in
            focus = id.map(PlayerControls.FocusSlot.episodeItem) ?? .button(.episodes)
        }
        .onChange(of: focus) { _, value in model.observedFocus = value }
    }
}

private actor EpisodeRowProvider: MediaProvider {
    nonisolated let kind = ProviderKind.jellyfin
    nonisolated let session = UserSession(
        server: MediaServer(id: "fixture", name: "Fixture", baseURL: URL(string: "https://fixture.test")!, provider: .jellyfin),
        userID: "viewer", userName: "Viewer", deviceID: "fixture", accessToken: "fixture"
    )
    private var heldIDs: Set<String> = []
    private var pending: [String: CheckedContinuation<Void, Never>] = [:]
    private var failures: Set<String> = []
    private(set) var requests: [String] = []

    nonisolated static func episode(season: Int, number: Int) -> MediaItem {
        MediaItem(
            id: "\(season)-\(number)", title: "Season \(season) Episode \(number)", kind: .episode,
            seasonNumber: season, episodeNumber: number, seriesID: "series", seasonID: "season-\(season)"
        )
    }

    func hold(_ id: String) { heldIDs.insert(id) }
    func failNext(_ id: String) { failures.insert(id) }
    func isHolding(_ id: String) -> Bool { pending[id] != nil }
    func release(_ id: String) {
        heldIDs.remove(id)
        pending.removeValue(forKey: id)?.resume()
    }
    func children(of itemID: String) async throws -> [MediaItem] {
        requests.append(itemID)
        if heldIDs.contains(itemID) {
            await withCheckedContinuation { pending[itemID] = $0 }
        }
        if failures.remove(itemID) != nil { throw AppError.invalidResponse }
        if itemID == "series" {
            return (1...3).map { (number: Int) in
                MediaItem(id: "season-\(number)", title: "Season", kind: .season, seasonNumber: number)
            }
        }
        guard let season = Int(itemID.replacingOccurrences(of: "season-", with: "")) else {
            throw AppError.notFound
        }
        return (1...8).map { Self.episode(season: season, number: $0) }
    }
    func libraries() async throws -> [MediaLibrary] { [] }
    func continueWatching(limit: Int) async throws -> [MediaItem] { [] }
    func latest(limit: Int) async throws -> [MediaItem] { [] }
    func item(id: String) async throws -> MediaItem {
        let parts = id.split(separator: "-")
        guard parts.count == 2, let season = Int(parts[0]), let number = Int(parts[1]) else {
            throw AppError.notFound
        }
        return Self.episode(season: season, number: number)
    }
    func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        MediaPage(items: [], startIndex: page.startIndex, totalCount: 0)
    }
    func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
    func playbackInfo(for itemID: String) async throws -> PlaybackRequest { throw AppError.notFound }
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {}
    nonisolated func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
}
