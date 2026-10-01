#if canImport(AVFoundation)
import XCTest
import CoreModels
import CoreUI
import MediaPlayer
@testable import FeaturePlayback
#if canImport(UIKit)
import UIKit
#endif

@MainActor
final class PlayerViewModelEOFTests: XCTestCase {
    func testSequenceCardsFillThePlayerBandWithRoomForArtworkAndTitles() {
        for metrics in [PlayerCardMetrics.tv, .horizontalWide, .horizontalNarrow] {
            let layout = PlayerSequenceLayout(
                metrics: metrics, cardMetrics: .standard, contained: false,
                hasError: false
            )
            XCTAssertEqual(layout.rowHeight, metrics.cardHeight)
            XCTAssertGreaterThan(layout.cardWidth, metrics.castCardWidth)
            XCTAssertGreaterThan(layout.imageHeight, metrics.castHeadshot * 0.9)
            XCTAssertGreaterThanOrEqual(
                layout.titleHeight, metrics.castNameSize * (layout.compact ? 1 : 2)
            )
            XCTAssertEqual(layout.cardWidth - layout.imageWidth, layout.cardMetrics.cardInset * 2)
            XCTAssertEqual(
                layout.imageHeight + layout.titleHeight + layout.cardMetrics.cardInset * 2
                    + layout.cardMetrics.landscapeCaptionInset
                    + layout.cardMetrics.landscapeCaptionTopSpacing,
                layout.rowHeight
            )

            let episodes = PlayerSequenceLayout(
                metrics: metrics, cardMetrics: .standard, contained: true,
                hasError: false
            )
            XCTAssertEqual(
                episodes.rowHeight + episodes.containerVerticalInset * 2,
                metrics.cardHeight
            )
            XCTAssertEqual(episodes.columnSpacing, metrics.columnSpacing)
            XCTAssertEqual(layout.columnSpacing, metrics.columnSpacing)
            XCTAssertGreaterThan(episodes.imageHeight, metrics.castHeadshot * 0.85)
            #if canImport(UIKit)
            XCTAssertEqual(
                episodes.titleHeight,
                ceil(UIFont.systemFont(ofSize: metrics.castNameSize, weight: .semibold).lineHeight)
            )
            #endif
            XCTAssertEqual(episodes.bottomInset, episodes.cardMetrics.cardInset)
            XCTAssertEqual(episodes.previousArtworkPeek, 24)
            XCTAssertEqual(episodes.episodeOffset(for: 0), 0)
            XCTAssertEqual(
                episodes.cardWidth - episodes.cardMetrics.cardInset - episodes.episodeOffset(for: 1),
                24, accuracy: 0.01
            )
            XCTAssertEqual(
                episodes.imageHeight + episodes.titleHeight + episodes.cardMetrics.landscapeCaptionTopSpacing
                    + episodes.cardMetrics.cardInset + episodes.bottomInset,
                episodes.rowHeight
            )
        }
        let portrait = PlayerSequenceLayout(
            metrics: .verticalNarrow, cardMetrics: .standard, contained: true,
            hasError: false
        )
        XCTAssertEqual(
            portrait.rowHeight + portrait.containerVerticalInset * 2,
            portrait.metrics.cardHeight
        )
        let tv = PlayerSequenceLayout(
            metrics: .tv, cardMetrics: .standard, contained: false,
            hasError: false
        )
        XCTAssertGreaterThan(tv.imageHeight, 175)
        let tvEpisodes = PlayerSequenceLayout(
            metrics: .tv, cardMetrics: .standard, contained: true, hasError: false
        )
        XCTAssertGreaterThan(tvEpisodes.imageHeight, 205)
        XCTAssertGreaterThan(tvEpisodes.imageWidth, 365)
        XCTAssertEqual(tvEpisodes.columnSpacing, 28)
        XCTAssertEqual(tvEpisodes.columnSpacing + tvEpisodes.cardMetrics.cardInset * 2, 52)
    }

    func testMobileWakeIntentCoversStartupAndBufferingButRespectsPause() async {
        let (viewModel, engine, _) = makeViewModel()
        XCTAssertEqual(viewModel.phase, .loading)
        XCTAssertFalse(engine.preventsDisplaySleep)
        XCTAssertTrue(viewModel.wantsForegroundDisplayAwake)

        viewModel.setPaused(true)
        XCTAssertFalse(viewModel.wantsForegroundDisplayAwake)
        viewModel.setPaused(false)
        XCTAssertTrue(viewModel.wantsForegroundDisplayAwake)

        await viewModel.load()
        XCTAssertEqual(viewModel.phase, .ready)
        engine.isPaused = true
        viewModel.controls.isPaused = true
        XCTAssertFalse(engine.preventsDisplaySleep)
        XCTAssertTrue(viewModel.wantsForegroundDisplayAwake,
                      "Waiting for frames is not a user pause")
        viewModel.setPaused(true)
        XCTAssertFalse(viewModel.wantsForegroundDisplayAwake)
        viewModel.setPaused(false)
        XCTAssertTrue(viewModel.wantsForegroundDisplayAwake)
        await viewModel.stop()
        XCTAssertFalse(viewModel.wantsForegroundDisplayAwake)
    }

    func testMobileWakeIntentEndsOnFailureAndReturnsForRetry() async {
        let (viewModel, _, _) = makeViewModel()
        await viewModel.load()
        XCTAssertTrue(viewModel.wantsForegroundDisplayAwake)
        viewModel.handoffSetPhase(.failed(.serverUnreachable))
        XCTAssertFalse(viewModel.wantsForegroundDisplayAwake)
        viewModel.handoffSetPhase(.loading)
        XCTAssertTrue(viewModel.wantsForegroundDisplayAwake)
        await viewModel.stop()
        XCTAssertFalse(viewModel.wantsForegroundDisplayAwake)
    }

    func testMobileWakeIntentEndsAtEOFEvenBeforePresentationDismisses() async {
        let (viewModel, engine, _) = makeViewModel()
        await viewModel.load()
        XCTAssertTrue(viewModel.wantsForegroundDisplayAwake)
        engine.onEnded?()
        XCTAssertFalse(viewModel.wantsForegroundDisplayAwake)
        await viewModel.stop()
    }

    func testDecoderPausedDuringStartupDoesNotBecomePausedPlaybackIntent() async {
        let (viewModel, engine, provider) = makeViewModel()
        engine.isPaused = true
        viewModel.controls.isPaused = true
        XCTAssertTrue(viewModel.wantsForegroundDisplayAwake)
        await viewModel.load()
        XCTAssertFalse(engine.isPaused)
        XCTAssertFalse(viewModel.controls.intendsPause)
        XCTAssertTrue(viewModel.wantsForegroundDisplayAwake)
        let reports = await provider.reports
        XCTAssertEqual(reports.first?.event.rawValue, "start")
        XCTAssertEqual(reports.first?.progress.isPaused, false)
        await viewModel.stop()
    }

    func testFailedEngineLoadDoesNotPublishReadyBeforeItsFailureCallbackRuns() async {
        let (viewModel, engine, provider) = makeViewModel()
        engine.failureDuringLoad = .invalidResponse
        await viewModel.load()
        XCTAssertEqual(engine.status, .failed(.invalidResponse))
        XCTAssertNotEqual(viewModel.phase, .ready)
        let reports = await provider.reports
        XCTAssertFalse(reports.contains { $0.event == .start })
        await viewModel.stop()
    }

    func testCancelledEngineLoadDoesNotPublishReadyOrPlaybackStart() async {
        let (viewModel, engine, provider) = makeViewModel()
        engine.cancelDuringLoad = true
        await viewModel.load()
        XCTAssertEqual(engine.status, .ready,
                       "Cancellation must win even if an engine returns a ready status")
        XCTAssertNotEqual(viewModel.phase, .ready)
        let reports = await provider.reports
        XCTAssertFalse(reports.contains { $0.event == .start })
        await viewModel.stop()
    }

    func testNowPlayingFollowsPauseSpeedAndEndsBeforeTransportDrain() async {
        let publisher = VideoNowPlayingPublisherSpy()
        let (viewModel, engine, _) = makeViewModel(nowPlayingPublisher: publisher)
        await viewModel.load()
        XCTAssertTrue(publisher.isActive)
        XCTAssertEqual(publisher.info[MPMediaItemPropertyTitle] as? String, "Movie")
        engine.preventsDisplaySleep = true
        viewModel.setPlaybackSpeed(1.5)
        XCTAssertEqual(publisher.info[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 1.5)
        engine.maximumPlaybackSpeed = 2
        viewModel.setPlaybackSpeed(4)
        XCTAssertEqual(viewModel.controls.playbackSpeed, 2)
        XCTAssertEqual(publisher.info[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 2)
        publisher.command?(.pause)
        XCTAssertTrue(engine.isPaused)
        XCTAssertEqual(publisher.info[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 0)
        publisher.command?(.play)
        XCTAssertTrue(viewModel.wantsForegroundDisplayAwake)

        let drain = PreCommitYieldGate()
        engine.drainGate = drain
        let stop = Task { await viewModel.stop() }
        await waitForGate(drain, entries: 1)
        XCTAssertFalse(publisher.isActive)
        XCTAssertTrue(publisher.info.isEmpty)
        XCTAssertFalse(viewModel.wantsForegroundDisplayAwake,
                       "A stopped player must release its lease before transport cleanup finishes")
        drain.releaseNext()
        await stop.value
    }

    func testNaturalEndClearsNowPlayingBeforeShellDismisses() async {
        let publisher = VideoNowPlayingPublisherSpy()
        let (viewModel, engine, _) = makeViewModel(nowPlayingPublisher: publisher)
        await viewModel.load()
        engine.onEnded?()
        XCTAssertTrue(viewModel.shouldDismiss)
        XCTAssertFalse(publisher.isActive)
        await viewModel.stop()
    }

    func testPlaylistOrderOverridesEpisodeAutoplayAtNaturalEnd() async {
        let first = MediaItem(id: "first", title: "First", kind: .episode, seriesID: "series", seasonID: "season")
        let second = MediaItem(id: "second", title: "Second", kind: .movie)
        let request = PlaybackRequest(
            item: first, streamURL: URL(string: "https://example.test/first.m3u8")!
        )
        let provider = RecordingPlaybackProvider(request: request, playlistMembers: [first, second])
        let origin = VideoPlaylistPlaybackOrigin(
            playlistID: "playlist", accountID: "account", index: 0, totalCount: 2,
            item: first.taggingSource("account")
        )
        let context = VideoPlaylistPlaybackContext(origin: origin, provider: provider)
        let engine = SpyVideoEngine()
        let viewModel = PlayerViewModel(
            provider: provider, itemID: first.id, episodeItem: first,
            playbackSettings: .init(autoPlayNextEpisode: false, autoPlayNextPlaylistItem: true),
            engineFactory: EngineFactory(makeNative: { _ in engine }),
            neighborResolver: { (nil, second) },
            playlistContext: context
        )
        await viewModel.load()
        engine.onEnded?()
        for _ in 0..<100 where viewModel.pendingPlaylistSelection == nil {
            await Task.yield()
        }
        XCTAssertEqual(viewModel.pendingPlaylistSelection?.index, 1)
        XCTAssertEqual(viewModel.pendingPlaylistSelection?.item.id, second.id)
        XCTAssertEqual(viewModel.pendingPlaylistSelection?.item.sourceAccountID, "account")
        XCTAssertNil(viewModel.pendingNextEpisode)
        XCTAssertFalse(viewModel.shouldDismiss)
        await viewModel.stop()
    }

    func testPlaylistAutoplayOffDoesNotFallThroughToEpisodeAutoplay() async {
        let first = MediaItem(id: "first", title: "First", kind: .episode, seriesID: "series", seasonID: "season")
        let next = MediaItem(id: "second", title: "Second", kind: .episode)
        let request = PlaybackRequest(
            item: first, streamURL: URL(string: "https://example.test/first.m3u8")!
        )
        let provider = RecordingPlaybackProvider(request: request, playlistMembers: [first, next])
        let context = VideoPlaylistPlaybackContext(
            origin: .init(playlistID: "playlist", accountID: "account", index: 0, totalCount: 2,
                          item: first.taggingSource("account")),
            provider: provider
        )
        let engine = SpyVideoEngine()
        let viewModel = PlayerViewModel(
            provider: provider, itemID: first.id, episodeItem: first,
            playbackSettings: .init(autoPlayNextEpisode: true, autoPlayNextPlaylistItem: false),
            engineFactory: EngineFactory(makeNative: { _ in engine }),
            neighborResolver: { (nil, next) },
            playlistContext: context
        )
        await viewModel.load()
        engine.onEnded?()
        XCTAssertTrue(viewModel.shouldDismiss)
        XCTAssertNil(viewModel.pendingNextEpisode)
        XCTAssertNil(viewModel.pendingPlaylistSelection)
        await viewModel.stop()
    }

    func testPlaylistContextPagesByIndexSoRepeatedMembersKeepTheirPositions() async throws {
        let repeated = MediaItem(id: "repeat", title: "Repeated", kind: .movie)
        let entries = (0..<50).map { index in
            index == 24 || index == 25
                ? repeated
                : MediaItem(id: "\(index)", title: "Movie \(index)", kind: .movie)
        }
        let provider = RecordingPlaybackProvider(
            request: PlaybackRequest(
                item: repeated, streamURL: URL(string: "https://example.test/repeat.m3u8")!
            ),
            playlistMembers: entries
        )
        let context = VideoPlaylistPlaybackContext(
            origin: .init(
                playlistID: "playlist", accountID: "account", index: 0,
                totalCount: entries.count, item: entries[0].taggingSource("account")
            ),
            provider: provider
        )
        let seeded = try await context.item(at: 0)
        let initialRequests = await provider.playlistMemberRequests
        let firstRepeat = try await context.item(at: 24)
        let secondRepeat = try await context.item(at: 25)
        let pageRequests = await provider.playlistMemberRequests
        XCTAssertEqual(seeded?.id, "0")
        XCTAssertEqual(initialRequests, 0)
        XCTAssertEqual(firstRepeat?.id, "repeat")
        XCTAssertEqual(secondRepeat?.id, "repeat")
        XCTAssertEqual(pageRequests, 1)
        XCTAssertEqual(context.items[24]?.sourceAccountID, "account")
        context.advance(to: 25)
        XCTAssertEqual(context.currentIndex, 25)
        let last = try await context.item(at: 49)
        let finalRequests = await provider.playlistMemberRequests
        XCTAssertEqual(last?.id, "49")
        XCTAssertEqual(finalRequests, 2)
    }

    func testPlaylistContextFillsShortServerPagesWithoutReordering() async throws {
        let entries = (0..<28).map {
            MediaItem(id: "\($0)", title: "Movie \($0)", kind: .movie)
        }
        let provider = RecordingPlaybackProvider(
            request: PlaybackRequest(
                item: entries[0], streamURL: URL(string: "https://example.test/movie.m3u8")!
            ),
            playlistMembers: entries,
            playlistPageLimit: 7
        )
        let context = VideoPlaylistPlaybackContext(
            origin: .init(
                playlistID: "playlist", accountID: "account", index: 0,
                totalCount: entries.count, item: entries[0].taggingSource("account")
            ),
            provider: provider
        )
        let nearEnd = try await context.item(at: 23)
        let last = try await context.item(at: 27)
        let requests = await provider.playlistMemberRequests
        XCTAssertEqual(nearEnd?.id, "23")
        XCTAssertEqual(last?.id, "27")
        XCTAssertEqual(requests, 5)
        XCTAssertEqual(context.items[27]?.sourceAccountID, "account")
    }

    func testEpisodeBrowserUsesThePlayingServersHierarchyInsteadOfRetargetedParents() async {
        for staleParentExists in [false, true] {
            let playing = MediaItem(
                id: "plex-episode", title: "Playing", kind: .episode,
                seriesID: "plex-series", seasonID: "plex-season"
            )
            var opened = playing.taggingSource("plex-account")
            opened.seriesID = "old-series"
            opened.seasonID = "old-season"
            let season = MediaItem(id: "plex-season", title: "Season", kind: .season)
            let provider = RecordingPlaybackProvider(
                request: PlaybackRequest(
                    item: playing, streamURL: URL(string: "https://example.test/episode.m3u8")!
                ),
                kind: .plex,
                childrenByParent: [
                    "plex-series": [season], "plex-season": [playing],
                    "old-series": [MediaItem(id: "unrelated", title: "Wrong show", kind: .episode)]
                ]
            )
            if !staleParentExists { await provider.setChildError(AppError.notFound, for: "old-series") }
            let browser = PlayerEpisodeBrowser(item: opened, provider: provider)
            await browser.loadIfNeeded()
            await browser.loadIfNeeded()
            XCTAssertNil(browser.loadError)
            XCTAssertEqual(browser.episodes.map(\.item.id), [playing.id])
            XCTAssertEqual(browser.initialEntryID?.seasonID, "plex-season")
            XCTAssertEqual(browser.episodes.first?.item.sourceAccountID, "plex-account")
            let children = await provider.requestedChildIDs()
            let metadataRequests = await provider.itemCallCount
            XCTAssertEqual(children, ["plex-series", "plex-season"])
            XCTAssertEqual(metadataRequests, 1)
        }
    }

    func testEpisodeBrowserDoesNotBrowseMetadataForADifferentEpisode() async {
        let opened = MediaItem(id: "playing", title: "Playing", kind: .episode, seriesID: "series")
        let unrelated = MediaItem(id: "different", title: "Wrong episode", kind: .episode, seriesID: "other")
        let provider = RecordingPlaybackProvider(request: PlaybackRequest(
            item: unrelated, streamURL: URL(string: "https://example.test/episode.m3u8")!
        ))
        let browser = PlayerEpisodeBrowser(item: opened, provider: provider)
        await browser.loadIfNeeded()
        XCTAssertEqual(browser.loadError, .invalidResponse)
        XCTAssertFalse(browser.hasLoaded)
        let children = await provider.requestedChildIDs()
        XCTAssertTrue(children.isEmpty)
    }

    func testEpisodeBrowserResolvesMissingOpeningParentsAndRetriesMetadataFailures() async throws {
        let playing = MediaItem(id: "episode", title: "Playing", kind: .episode, seriesID: "series")
        var opened = playing
        opened.seriesID = nil
        let provider = RecordingPlaybackProvider(
            request: PlaybackRequest(
                item: playing, streamURL: URL(string: "https://example.test/episode.m3u8")!
            ),
            childrenByParent: ["series": [playing]]
        )
        let player = PlayerViewModel(provider: provider, itemID: opened.id, episodeItem: opened)
        let browser = try XCTUnwrap(player.episodeBrowser)
        for error: any Error in [CancellationError(), AppError.cancelled, URLError(.cancelled)] {
            await provider.setItemError(error)
            await browser.loadIfNeeded()
            XCTAssertEqual(browser.loadError, .cancelled, "Provider cancellation on an active panel must offer Retry.")
            XCTAssertFalse(browser.isLoading)
            XCTAssertFalse(browser.hasLoaded)
        }
        await provider.setItemError(AppError.serverUnreachable)
        await browser.loadIfNeeded()
        XCTAssertEqual(browser.loadError, .serverUnreachable)
        XCTAssertFalse(browser.hasLoaded)
        await provider.setItemError(nil)
        await browser.loadIfNeeded()
        XCTAssertNil(browser.loadError)
        XCTAssertEqual(browser.episodes.map(\.item.id), [playing.id])
        await player.stop()
    }

    func testEpisodeBrowserShowsLooseEpisodesAndAvoidsRepeatedDiscovery() async {
        let episode = MediaItem(
            id: "loose", title: "Special", kind: .episode,
            seriesID: "series", seasonID: nil
        ).taggingSource("account")
        let provider = RecordingPlaybackProvider(
            request: PlaybackRequest(
                item: episode, streamURL: URL(string: "https://example.test/special.m3u8")!
            ),
            childrenByParent: ["series": [episode]]
        )
        let browser = PlayerEpisodeBrowser(item: episode, provider: provider)
        await browser.loadIfNeeded()
        await browser.loadIfNeeded()
        XCTAssertTrue(browser.seasons.isEmpty)
        XCTAssertEqual(browser.episodes.map(\.item.id), ["loose"])
        XCTAssertEqual(browser.episodes.first?.item.sourceAccountID, "account")
        let requests = await provider.childRequests
        XCTAssertEqual(requests, 1)
    }

    func testReopenedEpisodePanelCompletesAfterItsCancelledLoadDrains() async throws {
        let playing = MediaItem(
            id: "playing", title: "Playing", kind: .episode, seriesID: "series"
        )
        let provider = RecordingPlaybackProvider(
            request: PlaybackRequest(
                item: playing, streamURL: URL(string: "https://example.test/episode.m3u8")!
            ),
            childrenByParent: ["series": [playing]]
        )
        let browser = PlayerEpisodeBrowser(item: playing, provider: provider)
        let gate = PreCommitYieldGate()
        await provider.setChildGate(gate, for: "series")
        let firstOpening = Task { await browser.loadIfNeeded() }
        await waitForGate(gate, entries: 1)
        firstOpening.cancel()
        var reopenedFinished = false
        let reopened = Task {
            await browser.loadIfNeeded()
            reopenedFinished = true
        }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(reopenedFinished, "The reopened panel must await or replace the old request, not skip loading.")
        await provider.setChildGate(nil, for: "series")
        gate.releaseNext()
        await firstOpening.value
        await reopened.value
        XCTAssertTrue(browser.hasLoaded)
        XCTAssertFalse(browser.isLoading)
        XCTAssertNil(browser.loadError)
        XCTAssertEqual(browser.episodes.map(\.item.id), [playing.id])
        let requests = await provider.requestedChildIDs()
        XCTAssertEqual(requests, ["series", "series"], "Only the cancelled request is retried.")
    }

    func testConcurrentEpisodeOpeningsJoinTheSameUncancelledLoad() async {
        let playing = MediaItem(id: "playing", title: "Playing", kind: .episode, seriesID: "series")
        let provider = RecordingPlaybackProvider(
            request: PlaybackRequest(item: playing, streamURL: URL(string: "https://example.test/episode.m3u8")!),
            childrenByParent: ["series": [playing]]
        )
        let browser = PlayerEpisodeBrowser(item: playing, provider: provider)
        let gate = PreCommitYieldGate()
        await provider.setChildGate(gate, for: "series")
        let first = Task { await browser.loadIfNeeded() }
        await waitForGate(gate, entries: 1)
        let second = Task { await browser.loadIfNeeded() }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(gate.entryCount, 1)
        gate.releaseNext()
        await first.value
        await second.value
        XCTAssertTrue(browser.hasLoaded)
        let requests = await provider.requestedChildIDs()
        XCTAssertEqual(requests, ["series"])
    }

    func testStoppingPlayerCancelsEpisodeLoadAndPreventsLatePublication() async throws {
        let playing = MediaItem(id: "playing", title: "Playing", kind: .episode, seriesID: "series")
        let provider = RecordingPlaybackProvider(
            request: PlaybackRequest(item: playing, streamURL: URL(string: "https://example.test/episode.m3u8")!),
            childrenByParent: ["series": [playing]]
        )
        let player = PlayerViewModel(provider: provider, itemID: playing.id, episodeItem: playing)
        let browser = try XCTUnwrap(player.episodeBrowser)
        let gate = PreCommitYieldGate()
        await provider.setChildGate(gate, for: "series")
        let opening = Task { await browser.loadIfNeeded() }
        await waitForGate(gate, entries: 1)
        await player.stop()
        gate.releaseNext()
        await opening.value
        await browser.loadIfNeeded()
        XCTAssertFalse(browser.hasLoaded)
        XCTAssertFalse(browser.isLoading)
        XCTAssertNil(browser.loadError)
        XCTAssertTrue(browser.episodes.isEmpty)
        let requests = await provider.requestedChildIDs()
        XCTAssertEqual(requests, ["series"])
    }

    func testReopenedEpisodeEdgesResumeCancelledLoadsWithoutAnotherScroll() async {
        let playing = MediaItem(
            id: "middle", title: "Playing", kind: .episode, seriesID: "series", seasonID: "season-2"
        )
        let seasons = (1...3).map { MediaItem(id: "season-\($0)", title: "Season", kind: .season) }
        let provider = RecordingPlaybackProvider(
            request: PlaybackRequest(item: playing, streamURL: URL(string: "https://example.test/episode.m3u8")!),
            childrenByParent: [
                "series": seasons, "season-1": [MediaItem(id: "earlier", title: "Earlier", kind: .episode)],
                "season-2": [playing], "season-3": [MediaItem(id: "later", title: "Later", kind: .episode)]
            ]
        )
        let browser = PlayerEpisodeBrowser(item: playing, provider: provider)
        await browser.loadIfNeeded()
        let previous = PreCommitYieldGate()
        let next = PreCommitYieldGate()
        await provider.setChildGate(previous, for: "season-1")
        await provider.setChildGate(next, for: "season-3")
        let oldPrevious = Task { await browser.loadPrevious() }
        let oldNext = Task { await browser.loadNext() }
        await waitForGate(previous, entries: 1)
        await waitForGate(next, entries: 1)
        oldPrevious.cancel()
        oldNext.cancel()
        let newPrevious = Task { await browser.loadPrevious() }
        let newNext = Task { await browser.loadNext() }
        for _ in 0..<20 { await Task.yield() }
        await provider.setChildGate(nil, for: "season-1")
        await provider.setChildGate(nil, for: "season-3")
        previous.releaseNext()
        next.releaseNext()
        await oldPrevious.value
        await oldNext.value
        await newPrevious.value
        await newNext.value
        XCTAssertEqual(browser.episodes.map(\.item.id), ["earlier", "middle", "later"])
        XCTAssertNil(browser.previousLoadError)
        XCTAssertNil(browser.nextLoadError)
    }

    func testOneSeasonBrowserShowsEpisodesWithoutLoadingOtherSeasons() async {
        let season = MediaItem(
            id: "only-season", title: "Book One: A Very Long Season Name",
            kind: .season, seasonNumber: 1
        )
        let episode = MediaItem(
            id: "first", title: "Opening", kind: .episode,
            episodeNumber: 1, seriesID: "series", seasonID: season.id
        )
        let provider = RecordingPlaybackProvider(
            request: PlaybackRequest(
                item: episode, streamURL: URL(string: "https://example.test/episode.m3u8")!
            ),
            childrenByParent: ["series": [season], season.id: [episode]]
        )
        let browser = PlayerEpisodeBrowser(item: episode, provider: provider)
        await browser.loadIfNeeded()
        await browser.loadPrevious()
        await browser.loadNext()
        XCTAssertEqual(browser.episodes.map(\.badge), ["S1 · E1"])
        XCTAssertNil(browser.previousSeasonIndex)
        XCTAssertNil(browser.nextSeasonIndex)
        let requests = await provider.requestedChildIDs()
        XCTAssertEqual(requests, ["series", "only-season"])
    }

    func testLoadingEarlierSeasonKeepsRenderedEpisodeValuesAndFocusStable() async {
        let seasonOne = MediaItem(id: "season-one", title: "Season 1", kind: .season)
        let seasonTwo = MediaItem(id: "season-two", title: "Season 2", kind: .season)
        let episode = MediaItem(
            id: "two-1", title: "First", kind: .episode,
            seriesID: "series", seasonID: seasonTwo.id
        )
        let provider = RecordingPlaybackProvider(
            request: PlaybackRequest(
                item: episode, streamURL: URL(string: "https://example.test/episode.m3u8")!
            ),
            childrenByParent: [
                "series": [seasonOne, seasonTwo],
                seasonOne.id: [MediaItem(id: "one-1", title: "Pilot", kind: .episode)],
                seasonTwo.id: (1...3).map {
                    MediaItem(id: "two-\($0)", title: "Episode \($0)", kind: .episode)
                }
            ]
        )
        let browser = PlayerEpisodeBrowser(item: episode, provider: provider)
        await browser.loadIfNeeded()
        let visibleEntries = browser.episodes
        let initialID = browser.initialEntryID
        XCTAssertEqual(visibleEntries.map(\.item.id), ["two-1", "two-2", "two-3"])

        await browser.loadPrevious()
        XCTAssertEqual(browser.episodes.map(\.item.id), ["one-1", "two-1", "two-2", "two-3"])
        XCTAssertEqual(visibleEntries[2].item.id, "two-3",
                       "An in-flight SwiftUI row must keep captured values after prepending")
        XCTAssertEqual(browser.initialEntryID, initialID)
        XCTAssertEqual(browser.previousSeasonIndex, nil)
        XCTAssertEqual(browser.nextSeasonIndex, nil)
    }

    func testLongRunningShowLoadsOnlyAdjacentSeasonsAndKeepsNumberedCardsDistinct() async {
        let seasons = (1...30).map { (number: Int) in
            MediaItem(
                id: "season-\(number)", title: "Book \(number): A Very Long Season Name",
                kind: .season, seasonNumber: number
            )
        }
        let playing = MediaItem(
            id: "shared-episode", title: "Chapter", kind: .episode,
            episodeNumber: 1, seriesID: "series", seasonID: seasons[14].id
        )
        var children: [String: [MediaItem]] = ["series": seasons]
        for season in seasons {
            children[season.id] = [
                MediaItem(
                    id: "shared-episode", title: "Chapter", kind: .episode,
                    episodeNumber: 1, seriesID: "series", seasonID: season.id
                )
            ]
        }
        let provider = RecordingPlaybackProvider(
            request: PlaybackRequest(
                item: playing, streamURL: URL(string: "https://example.test/episode.m3u8")!
            ),
            childrenByParent: children
        )
        let browser = PlayerEpisodeBrowser(item: playing, provider: provider)
        await browser.loadIfNeeded()
        XCTAssertEqual(browser.episodes.map(\.badge), ["S15 · E1"])
        let initialRequests = await provider.requestedChildIDs()
        XCTAssertEqual(initialRequests, ["series", "season-15"])

        let initialID = browser.initialEntryID
        await browser.loadPrevious()
        await browser.loadNext()
        XCTAssertEqual(browser.episodes.map(\.badge), ["S14 · E1", "S15 · E1", "S16 · E1"])
        XCTAssertEqual(Set(browser.episodes.map(\.id)).count, 3)
        XCTAssertEqual(browser.initialEntryID, initialID)
        let requests = await provider.requestedChildIDs()
        XCTAssertEqual(
            requests,
            ["series", "season-15", "season-14", "season-16"]
        )

        for _ in 17...30 { await browser.loadNext() }
        for _ in 1...13 { await browser.loadPrevious() }
        XCTAssertEqual(browser.episodes.map(\.badge),
                       (1...30).map { "S\($0) · E1" })
        XCTAssertNil(browser.previousSeasonIndex)
        XCTAssertNil(browser.nextSeasonIndex)
        let allRequests = await provider.requestedChildIDs()
        XCTAssertEqual(allRequests.count, 31)
    }

    func testEpisodeBrowserSkipsEmptySeasonsAndRetriesFailedNeighbor() async {
        let seasons = (1...4).map {
            MediaItem(id: "season-\($0)", title: "Season \($0)", kind: .season)
        }
        let episode = MediaItem(
            id: "first", title: "First", kind: .episode,
            seriesID: "series", seasonID: seasons[0].id
        )
        let provider = RecordingPlaybackProvider(
            request: PlaybackRequest(
                item: episode, streamURL: URL(string: "https://example.test/episode.m3u8")!
            ),
            childrenByParent: [
                "series": seasons,
                seasons[1].id: [episode],
                seasons[3].id: [MediaItem(id: "last", title: "Last", kind: .episode)]
            ]
        )
        let browser = PlayerEpisodeBrowser(item: episode, provider: provider)
        await browser.loadIfNeeded()
        XCTAssertEqual(browser.episodes.map(\.item.id), ["first"])
        XCTAssertEqual(browser.nextSeasonIndex, 2)

        await provider.setChildError(AppError.serverUnreachable, for: seasons[2].id)
        await browser.loadNext()
        XCTAssertEqual(browser.nextLoadError, .serverUnreachable)
        XCTAssertEqual(browser.nextSeasonIndex, 2)
        await provider.setChildError(nil, for: seasons[2].id)
        await browser.retryNext()
        XCTAssertNil(browser.nextLoadError)
        XCTAssertEqual(browser.episodes.map(\.item.id), ["first", "last"])
        XCTAssertNil(browser.nextSeasonIndex)
        let requests = await provider.requestedChildIDs()
        XCTAssertEqual(
            requests,
            ["series", "season-1", "season-2", "season-3", "season-3", "season-4"]
        )
    }

    func testProviderCancellationOnAnActiveEpisodePanelOffersRetry() async {
        let seasons = (1...3).map {
            MediaItem(id: "season-\($0)", title: "Season", kind: .season)
        }
        let playing = MediaItem(
            id: "middle", title: "Middle", kind: .episode,
            seriesID: "series", seasonID: seasons[1].id
        )
        let cancellations: [any Error] = [
            CancellationError(), AppError.cancelled, URLError(.cancelled)
        ]
        for cancellation in cancellations {
            let provider = RecordingPlaybackProvider(
                request: PlaybackRequest(
                    item: playing, streamURL: URL(string: "https://example.test/episode.m3u8")!
                ),
                childrenByParent: [
                    "series": seasons,
                    seasons[0].id: [MediaItem(id: "earlier", title: "Earlier", kind: .episode)],
                    seasons[1].id: [playing],
                    seasons[2].id: [MediaItem(id: "later", title: "Later", kind: .episode)]
                ]
            )
            let browser = PlayerEpisodeBrowser(item: playing, provider: provider)
            XCTAssertFalse(browser.hasLoaded)
            await provider.setChildError(cancellation, for: "series")
            await browser.loadIfNeeded()
            XCTAssertEqual(browser.loadError, .cancelled)
            XCTAssertFalse(browser.isLoading)
            XCTAssertFalse(browser.hasLoaded)
            await provider.setChildError(nil, for: "series")
            await browser.loadIfNeeded()
            XCTAssertTrue(browser.hasLoaded)
            XCTAssertEqual(browser.episodes.map(\.item.id), ["middle"])

            await provider.setChildError(cancellation, for: seasons[0].id)
            await provider.setChildError(cancellation, for: seasons[2].id)
            await browser.loadPrevious()
            await browser.loadNext()
            XCTAssertEqual(browser.previousLoadError, .cancelled)
            XCTAssertEqual(browser.nextLoadError, .cancelled)
            XCTAssertFalse(browser.isLoadingPrevious)
            XCTAssertFalse(browser.isLoadingNext)
            XCTAssertEqual(browser.previousSeasonIndex, 0)
            XCTAssertEqual(browser.nextSeasonIndex, 2)
            XCTAssertEqual(browser.episodes.map(\.item.id), ["middle"])

            await provider.setChildError(nil, for: seasons[0].id)
            await provider.setChildError(nil, for: seasons[2].id)
            await browser.retryPrevious()
            await browser.retryNext()
            XCTAssertEqual(browser.episodes.map(\.item.id), ["earlier", "middle", "later"])
        }
    }

    func testCancelledEdgeTaskPreservesProgressPastEmptySeasonsAndCanResume() async {
        let seasons = (1...5).map {
            MediaItem(id: "season-\($0)", title: "Season", kind: .season)
        }
        let playing = MediaItem(
            id: "middle", title: "Middle", kind: .episode,
            seriesID: "series", seasonID: seasons[2].id
        )
        let provider = RecordingPlaybackProvider(
            request: PlaybackRequest(
                item: playing, streamURL: URL(string: "https://example.test/episode.m3u8")!
            ),
            childrenByParent: [
                "series": seasons,
                seasons[0].id: [MediaItem(id: "earlier", title: "Earlier", kind: .episode)],
                seasons[2].id: [playing],
                seasons[4].id: [MediaItem(id: "later", title: "Later", kind: .episode)]
            ]
        )
        let browser = PlayerEpisodeBrowser(item: playing, provider: provider)
        await browser.loadIfNeeded()
        let previous = PreCommitYieldGate()
        let next = PreCommitYieldGate()
        await provider.setChildGate(previous, for: seasons[0].id)
        await provider.setChildGate(next, for: seasons[4].id)
        let previousTask = Task { await browser.loadPrevious() }
        let nextTask = Task { await browser.loadNext() }
        await waitForGate(previous, entries: 1)
        await waitForGate(next, entries: 1)
        XCTAssertEqual(browser.previousSeasonIndex, 0)
        XCTAssertEqual(browser.nextSeasonIndex, 4)
        previousTask.cancel()
        nextTask.cancel()
        previous.releaseNext()
        next.releaseNext()
        await previousTask.value
        await nextTask.value
        XCTAssertNil(browser.previousLoadError)
        XCTAssertNil(browser.nextLoadError)
        XCTAssertFalse(browser.isLoadingPrevious)
        XCTAssertFalse(browser.isLoadingNext)
        XCTAssertEqual(browser.episodes.map(\.item.id), ["middle"])
        XCTAssertEqual(browser.previousSeasonIndex, 0)
        XCTAssertEqual(browser.nextSeasonIndex, 4)

        await provider.setChildGate(nil, for: seasons[0].id)
        await provider.setChildGate(nil, for: seasons[4].id)
        await browser.loadPrevious()
        await browser.loadNext()
        XCTAssertEqual(browser.episodes.map(\.item.id), ["earlier", "middle", "later"])
        let requests = await provider.requestedChildIDs()
        XCTAssertEqual(requests.filter { $0 == seasons[1].id }.count, 1)
        XCTAssertEqual(requests.filter { $0 == seasons[3].id }.count, 1)
    }

    func testPlaylistPageFailureCanRetryWithoutLosingSeededSelection() async throws {
        let first = MediaItem(id: "first", title: "First", kind: .movie)
        let second = MediaItem(id: "second", title: "Second", kind: .movie)
        let provider = RecordingPlaybackProvider(
            request: PlaybackRequest(
                item: first, streamURL: URL(string: "https://example.test/first.m3u8")!
            ),
            playlistMembers: [first, second]
        )
        let context = VideoPlaylistPlaybackContext(
            origin: .init(
                playlistID: "playlist", accountID: "account", index: 0,
                totalCount: 2, item: first.taggingSource("account")
            ),
            provider: provider
        )
        await provider.setPlaylistMemberError(.serverUnreachable)
        do {
            _ = try await context.item(at: 1)
            XCTFail("A failed page must not look like the end of the playlist")
        } catch {
            XCTAssertEqual(error as? AppError, .serverUnreachable)
        }
        XCTAssertEqual(context.loadError, .serverUnreachable)
        XCTAssertEqual(context.items[0]?.id, "first")
        await provider.setPlaylistMemberError(nil)
        context.retry()
        let recovered = try await context.item(at: 1)
        let requestCount = await provider.playlistMemberRequests
        XCTAssertEqual(recovered?.id, second.id)
        XCTAssertNil(context.loadError)
        XCTAssertEqual(requestCount, 2)
    }

    func testPlaylistAutoplayFailureDismissesEndedPlayerInsteadOfFreezing() async {
        let first = MediaItem(id: "first", title: "First", kind: .movie)
        let request = PlaybackRequest(
            item: first, streamURL: URL(string: "https://example.test/first.m3u8")!
        )
        let provider = RecordingPlaybackProvider(request: request)
        await provider.setPlaylistMemberError(.serverUnreachable)
        let context = VideoPlaylistPlaybackContext(
            origin: .init(
                playlistID: "playlist", accountID: "account", index: 0,
                totalCount: 2, item: first.taggingSource("account")
            ),
            provider: provider
        )
        let engine = SpyVideoEngine()
        let viewModel = PlayerViewModel(
            provider: provider, itemID: first.id,
            playbackSettings: .init(autoPlayNextPlaylistItem: true),
            engineFactory: EngineFactory(makeNative: { _ in engine }),
            playlistContext: context
        )
        await viewModel.load()
        engine.onEnded?()
        for _ in 0..<100 where !viewModel.shouldDismiss {
            await Task.yield()
        }
        XCTAssertTrue(viewModel.shouldDismiss)
        XCTAssertEqual(context.loadError, .serverUnreachable)
        XCTAssertNil(viewModel.pendingNextEpisode)
        await viewModel.stop()
    }

    func testBackgroundAudioPreferenceReachesEngineAndPreservesPlatformDefault() async {
        let publisher = VideoNowPlayingPublisherSpy()
        let (viewModel, engine, _) = makeViewModel(
            playbackSettings: .init(backgroundAudio: true), nowPlayingPublisher: publisher
        )
        await viewModel.load()
        XCTAssertTrue(engine.backgroundAudioEnabled)
        viewModel.didEnterBackground()
        #if os(iOS)
        XCTAssertFalse(engine.isPaused)
        XCTAssertTrue(publisher.transport.canPlay)
        #else
        XCTAssertTrue(engine.isPaused, "tvOS never opts into audio-only background video")
        XCTAssertFalse(publisher.transport.canPlay)
        #endif
        await viewModel.stop()
    }

    func testDefaultBackgroundPauseCannotBeUndoneBySystemPlay() async {
        let publisher = VideoNowPlayingPublisherSpy()
        let (viewModel, engine, _) = makeViewModel(nowPlayingPublisher: publisher)
        await viewModel.load()
        XCTAssertFalse(engine.backgroundAudioEnabled)
        viewModel.didEnterBackground()
        publisher.command?(.play)
        XCTAssertTrue(engine.isPaused)
        XCTAssertFalse(publisher.transport.canPlay)
        await viewModel.resumeAfterBackground()
        publisher.command?(.play)
        XCTAssertFalse(engine.isPaused)
        await viewModel.stop()
    }

    func testSystemPlayPauseRevealsTransportWithTheIntentAlreadyApplied() async {
        // tvOS delivers the Siri Remote's Play/Pause here while video plays. The
        // transport reacts synchronously, so its countdown must already read the
        // new intent rather than wait for the engine mirror's next tick.
        let publisher = VideoNowPlayingPublisherSpy()
        let (viewModel, engine, _) = makeViewModel(nowPlayingPublisher: publisher)
        await viewModel.load()
        let controls = viewModel.controls
        var pausedAtReveal: [Bool] = []
        controls.remotePlayPause.onSystemCommand = { [unowned controls] in
            pausedAtReveal.append(controls.isPaused && controls.intendsPause)
        }
        publisher.command?(.togglePlayPause)
        XCTAssertTrue(engine.isPaused)
        publisher.command?(.play)
        XCTAssertFalse(engine.isPaused)
        XCTAssertEqual(pausedAtReveal, [true, false], "Each command reveals once, after it is applied")
        await viewModel.stop()
    }

    func testSystemCommandEchoingARemotePressDoesNotToggleBack() async {
        let publisher = VideoNowPlayingPublisherSpy()
        let (viewModel, engine, _) = makeViewModel(nowPlayingPublisher: publisher)
        await viewModel.load()
        var reveals = 0
        viewModel.controls.remotePlayPause.onSystemCommand = { reveals += 1 }
        // The input surface applies the press...
        XCTAssertTrue(viewModel.controls.remotePlayPause.admit(.press))
        viewModel.togglePlayPause()
        XCTAssertTrue(engine.isPaused)
        // ...and the same press then arrives as a Now Playing toggle.
        publisher.command?(.togglePlayPause)
        XCTAssertTrue(engine.isPaused, "One press must not pause and then resume")
        XCTAssertEqual(reveals, 0, "The press already revealed the transport")
        await viewModel.stop()
    }

    func testLosingNowPlayingPausesWithoutCountingAsRemoteInput() async {
        let publisher = VideoNowPlayingPublisherSpy()
        let (viewModel, engine, _) = makeViewModel(nowPlayingPublisher: publisher)
        await viewModel.load()
        var reveals = 0
        viewModel.controls.remotePlayPause.onSystemCommand = { reveals += 1 }
        publisher.resign()
        XCTAssertTrue(engine.isPaused)
        XCTAssertEqual(reveals, 0)
        XCTAssertTrue(viewModel.controls.remotePlayPause.admit(.press),
                      "A press right after losing Now Playing is the viewer's, not an echo")
        await viewModel.stop()
    }

    func testSystemCommandAfterStopDoesNotRevealTheTransport() async {
        let publisher = VideoNowPlayingPublisherSpy()
        let (viewModel, _, _) = makeViewModel(nowPlayingPublisher: publisher)
        await viewModel.load()
        var reveals = 0
        viewModel.controls.remotePlayPause.onSystemCommand = { reveals += 1 }
        await viewModel.stop()
        viewModel.nowPlayingSetPaused(true)
        XCTAssertEqual(reveals, 0)
    }

    #if os(iOS)
    func testSystemResumeRebuildsThePausedBackgroundPipelineWhenEnabled() async {
        let publisher = VideoNowPlayingPublisherSpy()
        let (viewModel, engine, _) = makeViewModel(
            playbackSettings: .init(backgroundAudio: true), nowPlayingPublisher: publisher
        )
        await viewModel.load()
        viewModel.didEnterBackground()
        publisher.command?(.pause)
        XCTAssertTrue(engine.isPaused)
        XCTAssertFalse(publisher.transport.canSeek, "A torn-down pipeline cannot accept a seek")
        publisher.command?(.play)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(engine.reloadAfterForegroundCount, 1)
        XCTAssertFalse(engine.isPaused)
        await viewModel.stop()
    }
    #endif

    func testStopAfterNaturalEndStillWritesFinalFurthestPosition() async {
        let item = MediaItem(id: "movie", title: "Movie", kind: .movie, runtime: 120)
        let request = PlaybackRequest(
            item: item,
            streamURL: URL(string: "https://example.test/movie.m3u8")!
        )
        let provider = RecordingPlaybackProvider(request: request)
        let engine = SpyVideoEngine()
        let stopped = PlaybackStoppedRecorder()
        let viewModel = PlayerViewModel(
            provider: provider,
            itemID: item.id,
            engineFactory: EngineFactory(makeNative: { _ in engine }),
            onPlaybackStopped: { position, percent in
                stopped.record(position: position, percent: percent)
            }
        )

        await viewModel.load()
        engine.duration = 120
        engine.furthestObservedPosition = 120
        engine.currentTime = 0
        engine.onEnded?()

        await viewModel.stop()

        let reports = await provider.reports
        XCTAssertEqual(reports.map(\.event.rawValue), ["start", "stop"])
        XCTAssertEqual(reports.last?.progress.positionSeconds, 120)
        XCTAssertEqual(reports.last?.progress.durationSeconds, 120)
        XCTAssertEqual(stopped.onlyCall?.position, 120)
        XCTAssertEqual(stopped.onlyCall?.percent, 100)
    }

    func testForcedCheckpointCapturesPausedPosition() async {
        let item = MediaItem(id: "movie", title: "Movie", kind: .movie, runtime: 120)
        let request = PlaybackRequest(
            item: item,
            streamURL: URL(string: "https://example.test/movie.m3u8")!
        )
        let provider = RecordingPlaybackProvider(request: request)
        let engine = SpyVideoEngine()
        let checkpoints = PlaybackStoppedRecorder()
        let viewModel = PlayerViewModel(
            provider: provider,
            itemID: item.id,
            engineFactory: EngineFactory(makeNative: { _ in engine }),
            onPlaybackCheckpoint: { position, percent in
                checkpoints.record(position: position, percent: percent)
            }
        )
        await viewModel.load()
        engine.duration = 120
        engine.currentTime = 30
        engine.furthestObservedPosition = 30
        engine.isPaused = true

        viewModel.checkpointNow()

        XCTAssertEqual(checkpoints.onlyCall?.position, 30)
        XCTAssertEqual(checkpoints.onlyCall?.percent, 25)
    }

    func testInactiveOnlyPauseDoesNotReloadEngine() async {
        let (viewModel, engine, _) = makeViewModel()
        await viewModel.load()

        viewModel.suspendForBackground()
        await viewModel.resumeAfterBackground()

        XCTAssertEqual(engine.reloadAfterForegroundCount, 0)
        XCTAssertTrue(engine.isPaused)
    }

    func testForegroundReturnReloadsOnceAndRemainsPaused() async {
        let (viewModel, engine, provider) = makeViewModel()
        await viewModel.load()
        engine.currentTime = 30

        viewModel.didEnterBackground()
        await viewModel.resumeAfterBackground()
        await viewModel.resumeAfterBackground()
        for _ in 0..<10 { await Task.yield() }

        XCTAssertEqual(engine.reloadAfterForegroundCount, 1)
        XCTAssertEqual(engine.currentTime, 30)
        XCTAssertTrue(engine.isPaused)
        XCTAssertTrue(viewModel.controls.isPaused)
        let reports = await provider.reports
        XCTAssertEqual(reports.map(\.event.rawValue), ["start", "pause"])
    }

    func testBackgroundDuringBringUpReportsPausedStartBeforeRecovery() async {
        let (viewModel, engine, provider) = makeViewModel()

        XCTAssertTrue(viewModel.wantsForegroundDisplayAwake)
        viewModel.didEnterBackground()
        XCTAssertFalse(viewModel.wantsForegroundDisplayAwake)
        await viewModel.load()
        await viewModel.resumeAfterBackground()
        for _ in 0..<10 { await Task.yield() }

        XCTAssertEqual(engine.reloadAfterForegroundCount, 1)
        XCTAssertTrue(engine.isPaused)
        let reports = await provider.reports
        XCTAssertEqual(reports.map(\.event.rawValue), ["start"])
        XCTAssertEqual(reports.first?.progress.isPaused, true)
        XCTAssertFalse(viewModel.wantsForegroundDisplayAwake,
                       "Foreground recovery must not invent an explicit resume")
        viewModel.setPaused(false)
        XCTAssertFalse(engine.isPaused)
        XCTAssertTrue(viewModel.wantsForegroundDisplayAwake)
        await viewModel.stop()
    }

    func testStopAfterRewindUsesCurrentPositionInsteadOfFurthest() async {
        let item = MediaItem(id: "movie", title: "Movie", kind: .movie, runtime: 600)
        let request = PlaybackRequest(
            item: item,
            streamURL: URL(string: "https://example.test/movie.m3u8")!
        )
        let provider = RecordingPlaybackProvider(request: request)
        let engine = SpyVideoEngine()
        let stopped = PlaybackStoppedRecorder()
        let viewModel = PlayerViewModel(
            provider: provider,
            itemID: item.id,
            engineFactory: EngineFactory(makeNative: { _ in engine }),
            onPlaybackStopped: { position, percent in
                stopped.record(position: position, percent: percent)
            }
        )
        await viewModel.load()
        engine.duration = 600
        engine.furthestObservedPosition = 427
        engine.currentTime = 120

        await viewModel.stop()

        let reports = await provider.reports
        XCTAssertEqual(stopped.onlyCall?.position, 120)
        XCTAssertEqual(stopped.onlyCall?.percent, 20)
        XCTAssertEqual(reports.last?.progress.positionSeconds, 120)
    }

    func testStopAwaitsNetworkTransportDrainBeforeFinalReport() async throws {
        let request = try makeNetworkFileRequest()
        let provider = RecordingPlaybackProvider(request: request, kind: .mediaShare)
        let engine = SpyVideoEngine()
        let drainGate = PreCommitYieldGate()
        engine.drainGate = drainGate
        let viewModel = PlayerViewModel(
            provider: provider,
            itemID: request.item.id,
            engineFactory: EngineFactory(
                makeNative: { _ in SpyVideoEngine() },
                makePlozzigen: { engine }
            )
        )
        await viewModel.load()

        let stopTask = Task { await viewModel.stop() }
        await waitForGate(drainGate, entries: 1)

        XCTAssertEqual(engine.stopCount, 1)
        XCTAssertEqual(engine.drainTransportCount, 1)
        let reportsWhileDraining = await provider.reports
        XCTAssertEqual(reportsWhileDraining.map(\.event.rawValue), ["start"])

        drainGate.releaseNext()
        await stopTask.value

        let completedReports = await provider.reports
        XCTAssertEqual(completedReports.map(\.event.rawValue), ["start", "stop"])
    }

    func testNetworkFileFailureReplacesPlozzigenOnceAndIgnoresOldCallback() async throws {
        let item = MediaItem(id: "movie", title: "Movie", kind: .movie, runtime: 120)
        let identity = try RemoteFileIdentity(
            kind: .strongETag,
            value: "\"movie-v1\""
        )
        let representation = try RemoteFileRepresentation(
            size: 1_024,
            identity: identity,
            consistency: .stronglyBound
        )
        let locator = try NetworkFileLocator(
            accountID: "account",
            sourceID: "source",
            credentialRevision: CredentialRevision(),
            relativePath: "Movies/Movie.mkv",
            representation: representation,
            formatHint: MediaFormatHint(
                container: "mkv",
                mimeType: "video/x-matroska"
            )
        )
        let request = PlaybackRequest(
            item: item,
            playbackSource: .networkFile(locator)
        )
        let provider = RecordingPlaybackProvider(request: request)
        let native = SpyVideoEngine()
        var plozzigenEngines: [SpyVideoEngine] = []
        let factory = EngineFactory(
            makeNative: { _ in native },
            makePlozzigen: {
                let engine = SpyVideoEngine()
                plozzigenEngines.append(engine)
                return engine
            }
        )
        let viewModel = PlayerViewModel(
            provider: provider,
            itemID: item.id,
            engineFactory: factory
        )

        await viewModel.load()
        XCTAssertEqual(plozzigenEngines.count, 1)
        let staleFailure = try XCTUnwrap(plozzigenEngines[0].onFailure)
        let staleFacts = try XCTUnwrap(plozzigenEngines[0].onProbedSourceFactsChanged)
        staleFacts(EngineProbedSourceFacts(range: .dolbyVision))
        let firstTransitionToken = viewModel.dynamicRangeTransitionToken

        staleFailure(.invalidResponse)
        for _ in 0..<50
        where plozzigenEngines.count < 2 || plozzigenEngines[1].loadCount < 1 {
            await Task.yield()
        }

        XCTAssertEqual(plozzigenEngines.count, 2)
        XCTAssertEqual(plozzigenEngines[0].stopCount, 1)
        XCTAssertEqual(plozzigenEngines[1].loadCount, 1)
        XCTAssertNotEqual(viewModel.dynamicRangeTransitionToken, firstTransitionToken)
        XCTAssertEqual(viewModel.inheritedPreservedDynamicRange, .dolbyVision)

        staleFacts(EngineProbedSourceFacts(range: .dolbyVision))
        XCTAssertEqual(
            viewModel.effectiveDynamicRange,
            .awaitingEngineProbe(hint: nil)
        )
        plozzigenEngines[1].onProbedSourceFactsChanged?(
            EngineProbedSourceFacts(range: .hlg)
        )
        XCTAssertEqual(
            viewModel.effectiveDynamicRange,
            .resolved(.hlg, authority: .engineProbe)
        )

        staleFailure(.unknown("late old-engine failure"))
        await Task.yield()
        XCTAssertEqual(plozzigenEngines.count, 2)

        plozzigenEngines[1].onFailure?(.invalidResponse)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(plozzigenEngines.count, 2)

        await viewModel.stop()
    }

    func testDirectFileWaitsForProbeAndAcceptsEveryHDRRange() async throws {
        for range in [
            SourceDynamicRange.dolbyVision,
            .hdr10,
            .hdr10Plus,
            .hlg,
        ] {
            let request = try makeNetworkFileRequest()
            let provider = RecordingPlaybackProvider(request: request)
            let plozzigen = SpyVideoEngine()
            let viewModel = PlayerViewModel(
                provider: provider,
                itemID: request.item.id,
                engineFactory: EngineFactory(
                    makeNative: { _ in SpyVideoEngine() },
                    makePlozzigen: { plozzigen }
                )
            )

            await viewModel.load()
            XCTAssertEqual(
                viewModel.effectiveDynamicRange,
                .awaitingEngineProbe(hint: nil)
            )
            XCTAssertEqual(viewModel.exitVeilKind, .dynamicRange)

            plozzigen.onProbedSourceFactsChanged?(
                EngineProbedSourceFacts(range: range)
            )

            XCTAssertEqual(
                viewModel.effectiveDynamicRange,
                .resolved(range, authority: .engineProbe)
            )
            XCTAssertEqual(viewModel.exitVeilKind, .dynamicRange)
            XCTAssertTrue(viewModel.controls.subtitlesRenderHDR)
            let playbackInfoCalls = await provider.playbackInfoCallCount
            let itemCalls = await provider.itemCallCount
            XCTAssertEqual(playbackInfoCalls, 1)
            XCTAssertEqual(itemCalls, 0)
            await viewModel.stop()
        }
    }

    func testEngineProbeCorrectsProviderHDRHintToSDR() async throws {
        let request = try makeNetworkFileRequest(
            metadata: MediaSourceMetadata(video: .init(videoRangeType: "HDR10"))
        )
        let provider = RecordingPlaybackProvider(request: request)
        let plozzigen = SpyVideoEngine()
        let viewModel = PlayerViewModel(
            provider: provider,
            itemID: request.item.id,
            engineFactory: EngineFactory(
                makeNative: { _ in SpyVideoEngine() },
                makePlozzigen: { plozzigen }
            )
        )

        await viewModel.load()
        XCTAssertEqual(
            viewModel.effectiveDynamicRange,
            .awaitingEngineProbe(hint: .hdr10)
        )

        plozzigen.onProbedSourceFactsChanged?(
            EngineProbedSourceFacts(range: .sdr)
        )

        XCTAssertEqual(
            viewModel.effectiveDynamicRange,
            .resolved(.sdr, authority: .engineProbe)
        )
        // SDR now takes the frame-rate exit veil (Match Frame Rate hands the
        // display back on the way out); it is no longer a bare dismiss.
        XCTAssertEqual(viewModel.exitVeilKind, .frameRate)
        XCTAssertFalse(viewModel.controls.subtitlesRenderHDR)
        await viewModel.stop()
    }

    func testExitVeilKindFollowsTheProfilesFadeToggles() async throws {
        // Both fades off: leaving any title dismisses immediately, no black.
        let request = try makeNetworkFileRequest(
            metadata: MediaSourceMetadata(video: .init(videoRangeType: "HDR10"))
        )
        func makeViewModel(_ settings: PlaybackSettings) -> PlayerViewModel {
            PlayerViewModel(
                provider: RecordingPlaybackProvider(request: request),
                itemID: request.item.id,
                playbackSettings: settings,
                engineFactory: EngineFactory(
                    makeNative: { _ in SpyVideoEngine() },
                    makePlozzigen: { SpyVideoEngine() }
                )
            )
        }

        let bothOff = makeViewModel(PlaybackSettings(
            fadeOnDynamicRangeChange: false,
            fadeOnFrameRateChange: false
        ))
        await bothOff.load()
        XCTAssertNil(bothOff.exitVeilKind)
        await bothOff.stop()

        // Dynamic-range fade off but frame-rate fade on: HDR content still gets a
        // veil, just the cheaper frame-rate one.
        let frameRateOnly = makeViewModel(PlaybackSettings(
            fadeOnDynamicRangeChange: false,
            fadeOnFrameRateChange: true
        ))
        await frameRateOnly.load()
        XCTAssertEqual(frameRateOnly.exitVeilKind, .frameRate)
        XCTAssertFalse(frameRateOnly.fadesOnDynamicRangeChange)
        await frameRateOnly.stop()
    }

    func testUnavailablePlozzigenFallsBackToNativeRangeTruth() async throws {
        let request = try makeNetworkFileRequest()
        let provider = RecordingPlaybackProvider(request: request)
        let native = SpyVideoEngine()
        let viewModel = PlayerViewModel(
            provider: provider,
            itemID: request.item.id,
            engineFactory: EngineFactory(
                makeNative: { _ in native },
                makePlozzigen: { nil }
            )
        )

        await viewModel.load()

        XCTAssertEqual(
            viewModel.effectiveDynamicRange,
            .resolved(.sdr, authority: .nativeFallback)
        )
        XCTAssertFalse(viewModel.effectiveDynamicRange.isAwaitingEngineProbe)
        await viewModel.stop()
    }

    func testStopDuringPreCommitYieldDoesNotCreateReplacementEngine() async throws {
        let request = try makeNetworkFileRequest()
        let provider = RecordingPlaybackProvider(request: request)
        let native = SpyVideoEngine()
        var plozzigenEngines: [SpyVideoEngine] = []
        let gate = PreCommitYieldGate()
        let viewModel = PlayerViewModel(
            provider: provider,
            itemID: request.item.id,
            engineFactory: EngineFactory(
                makeNative: { _ in native },
                makePlozzigen: {
                    let engine = SpyVideoEngine()
                    plozzigenEngines.append(engine)
                    return engine
                }
            )
        )
        viewModel.preEngineCommitYield = { await gate.suspend() }

        let loadTask = Task { await viewModel.load() }
        await waitForGate(gate, entries: 1)
        await viewModel.stop()
        gate.releaseNext()
        await loadTask.value

        XCTAssertTrue(plozzigenEngines.isEmpty)
        XCTAssertEqual(native.loadCount, 0)
        XCTAssertEqual(native.stopCount, 1)
        XCTAssertEqual(native.status, .idle)
        XCTAssertNil(native.onProbedSourceFactsChanged)
    }

    func testNewGenerationSupersedesLoadDuringPreCommitYield() async throws {
        let request = try makeNetworkFileRequest()
        let provider = RecordingPlaybackProvider(request: request)
        let native = SpyVideoEngine()
        var plozzigenEngines: [SpyVideoEngine] = []
        let gate = PreCommitYieldGate()
        let viewModel = PlayerViewModel(
            provider: provider,
            itemID: request.item.id,
            engineFactory: EngineFactory(
                makeNative: { _ in native },
                makePlozzigen: {
                    let engine = SpyVideoEngine()
                    plozzigenEngines.append(engine)
                    return engine
                }
            )
        )
        viewModel.preEngineCommitYield = { await gate.suspend() }

        let staleLoad = Task { await viewModel.load() }
        await waitForGate(gate, entries: 1)
        let currentLoad = Task { await viewModel.load() }
        await waitForGate(gate, entries: 2)

        gate.releaseNext()
        await staleLoad.value
        XCTAssertTrue(plozzigenEngines.isEmpty)
        XCTAssertEqual(native.stopCount, 0)

        gate.releaseNext()
        await currentLoad.value
        XCTAssertEqual(plozzigenEngines.count, 1)
        XCTAssertEqual(plozzigenEngines[0].loadCount, 1)
        XCTAssertNotNil(plozzigenEngines[0].onProbedSourceFactsChanged)
        XCTAssertEqual(native.stopCount, 1)
        await viewModel.stop()
    }

    func testSameRangeHandoffUsesAuthoritativePrefetchProbeAndFallsBackToKnownHint() async throws {
        let request = try makeNetworkFileRequest()
        let provider = RecordingPlaybackProvider(request: request)
        let plozzigen = SpyVideoEngine()
        let viewModel = PlayerViewModel(
            provider: provider,
            itemID: request.item.id,
            engineFactory: EngineFactory(
                makeNative: { _ in SpyVideoEngine() },
                makePlozzigen: { plozzigen }
            )
        )
        await viewModel.load()
        plozzigen.onProbedSourceFactsChanged?(
            EngineProbedSourceFacts(range: .dolbyVision)
        )

        let knownNext = PlayerViewModel.PrefetchedPlayback(
            itemID: "next",
            request: PlaybackRequest(
                item: MediaItem(id: "next", title: "Next", kind: .episode),
                streamURL: URL(string: "https://example.test/next.mkv")!,
                sourceMetadata: MediaSourceMetadata(
                    video: .init(videoRangeType: "DOVI")
                )
            ),
            engineKind: .plozzigen
        )
        let unknownNext = PlayerViewModel.PrefetchedPlayback(
            itemID: "unknown",
            request: PlaybackRequest(
                item: MediaItem(id: "unknown", title: "Unknown", kind: .episode),
                streamURL: URL(string: "https://example.test/unknown.mkv")!
            ),
            engineKind: .plozzigen
        )

        XCTAssertTrue(viewModel.shouldPreserveDisplayMode(forNext: knownNext))
        XCTAssertFalse(viewModel.shouldPreserveDisplayMode(forNext: unknownNext))

        let probedNext = PlayerViewModel.PrefetchedPlayback(
            itemID: "probed",
            request: unknownNext.request,
            engineKind: .plozzigen,
            prefetchedDynamicRange: .dolbyVision
        )
        let mismatchedNext = PlayerViewModel.PrefetchedPlayback(
            itemID: "mismatched",
            request: unknownNext.request,
            engineKind: .plozzigen,
            prefetchedDynamicRange: .hdr10
        )
        let authoritativeSDRNext = PlayerViewModel.PrefetchedPlayback(
            itemID: "sdr",
            request: unknownNext.request,
            engineKind: .plozzigen,
            prefetchedDynamicRange: .sdr
        )
        XCTAssertTrue(viewModel.shouldPreserveDisplayMode(forNext: probedNext))
        XCTAssertFalse(viewModel.shouldPreserveDisplayMode(forNext: mismatchedNext))
        XCTAssertFalse(viewModel.shouldPreserveDisplayMode(forNext: authoritativeSDRNext))

        for range in [
            SourceDynamicRange.hdr10,
            .hdr10Plus,
            .hlg
        ] {
            plozzigen.onProbedSourceFactsChanged?(
                EngineProbedSourceFacts(range: range)
            )
            let sameDisplayClassNext = PlayerViewModel.PrefetchedPlayback(
                itemID: "probed-\(range.rawValue)",
                request: unknownNext.request,
                engineKind: .plozzigen,
                prefetchedDynamicRange: range
            )
            XCTAssertTrue(
                viewModel.shouldPreserveDisplayMode(forNext: sameDisplayClassNext),
                "Expected \(range.rawValue) handoff to preserve display criteria"
            )
        }
        await viewModel.stop()

        let inherited = probedNext.inheritingPreservedDisplayMode(true)
        let incomingEngine = SpyVideoEngine()
        let incoming = PlayerViewModel(
            provider: RecordingPlaybackProvider(request: probedNext.request),
            itemID: probedNext.itemID,
            engineFactory: EngineFactory(
                makeNative: { _ in SpyVideoEngine() },
                makePlozzigen: { incomingEngine }
            ),
            adoptedResolved: inherited
        )
        await incoming.load()
        XCTAssertTrue(incoming.inheritsPreservedDisplayMode)
        XCTAssertEqual(
            incoming.effectiveDynamicRange,
            .awaitingEngineProbe(hint: nil)
        )
        XCTAssertEqual(incoming.inheritedPreservedDynamicRange, .dolbyVision)
        await incoming.stop()
    }

    func testDirectFilePrefetchHeaderProbesRangeWithoutMetadataEnrichment() async throws {
        let current = try makeNetworkFileRequest(
            itemID: "current",
            title: "Episode 1",
            kind: .episode,
            relativePath: "Shows/Show/S01E01.mkv"
        )
        let next = try makeNetworkFileRequest(
            itemID: "next",
            title: "Episode 2",
            kind: .episode,
            relativePath: "Shows/Show/S01E02.mkv"
        )
        let provider = RecordingPlaybackProvider(
            request: current,
            kind: .mediaShare,
            requestsByItemID: ["next": next]
        )
        let rangeProbe = RangeProbeRecorder(result: .dolbyVision)
        let viewModel = PlayerViewModel(
            provider: provider,
            itemID: current.item.id,
            engineFactory: EngineFactory(
                makeNative: { _ in SpyVideoEngine() },
                makePlozzigen: { SpyVideoEngine() },
                probeSourceDynamicRange: { request in
                    await rangeProbe.probe(request)
                }
            ),
            neighborResolver: { (nil, next.item) }
        )

        await waitForPrefetchedNext(viewModel)

        XCTAssertEqual(viewModel.prefetchedNext?.itemID, next.item.id)
        XCTAssertEqual(
            viewModel.prefetchedNext?.prefetchedDynamicRange,
            .dolbyVision
        )
        let rangeProbeCallCount = await rangeProbe.callCount()
        let rangeProbeLastItemID = await rangeProbe.lastItemID()
        let providerItemCallCount = await provider.itemCallCountValue()
        XCTAssertEqual(rangeProbeCallCount, 1)
        XCTAssertEqual(rangeProbeLastItemID, next.item.id)
        XCTAssertEqual(providerItemCallCount, 0)
        await viewModel.stop()
    }

    func testPreviousEpisodeHandoffKeepsHDRUntilSelectedEpisodeIsProbed() async throws {
        let current = try makeNetworkFileRequest(itemID: "episode-2", kind: .episode)
        let previous = try makeNetworkFileRequest(itemID: "episode-1", kind: .episode)
        let provider = RecordingPlaybackProvider(
            request: current, kind: .mediaShare, requestsByItemID: ["episode-1": previous]
        )
        let engine = SpyVideoEngine()
        let gate = RangeProbeGate(result: .dolbyVision)
        let viewModel = PlayerViewModel(
            provider: provider, itemID: current.item.id,
            engineFactory: EngineFactory(
                makeNative: { _ in SpyVideoEngine() },
                makePlozzigen: { engine },
                probeSourceDynamicRange: { await gate.probe($0) }
            ),
            neighborResolver: { (previous.item, nil) }
        )
        await viewModel.load()
        engine.onProbedSourceFactsChanged?(EngineProbedSourceFacts(range: .dolbyVision))
        viewModel.playEpisode(previous.item)
        XCTAssertTrue(viewModel.showBringUpSpinner)
        let handoff = Task { await viewModel.prepareEpisodeHandoff(to: previous.item) }
        await gate.waitUntilEntered()
        XCTAssertEqual(engine.stopCount, 0)
        engine.onEnded?()
        viewModel.playEpisode(MediaItem(id: "ignored", title: "Ignored", kind: .episode))
        XCTAssertEqual(viewModel.pendingNextEpisode?.id, previous.item.id,
                       "EOF and repeated input cannot replace the user's in-flight selection.")
        await gate.release()
        let resolved = await handoff.value
        let prepared = try XCTUnwrap(resolved)
        let preserve = viewModel.shouldPreserveDisplayMode(forNext: prepared)
        XCTAssertTrue(preserve)
        await viewModel.stop(preserveDisplayMode: preserve)
        XCTAssertEqual(engine.preservedDisplayStops, [true])

        let incomingEngine = SpyVideoEngine()
        let incoming = PlayerViewModel(
            provider: provider, itemID: previous.item.id,
            engineFactory: EngineFactory(
                makeNative: { _ in SpyVideoEngine() }, makePlozzigen: { incomingEngine }
            ),
            adoptedResolved: prepared.inheritingPreservedDisplayMode(preserve)
        )
        await incoming.load()
        let resolutions = await provider.playbackInfoCallCountValue()
        XCTAssertEqual(resolutions, 2, "Current and selected episodes each resolve only once.")
        XCTAssertEqual(incoming.inheritedPreservedDynamicRange, .dolbyVision)
        await incoming.stop()
    }

    func testDismissalWhilePreparingEpisodeReleasesSessionWithoutPublishing() async throws {
        let current = try makeNetworkFileRequest(itemID: "current", kind: .episode)
        let previous = try makeNetworkFileRequest(
            itemID: "previous", kind: .episode, playSessionID: "prepared-session"
        )
        let provider = RecordingPlaybackProvider(
            request: current, requestsByItemID: ["previous": previous]
        )
        let engine = SpyVideoEngine()
        let gate = RangeProbeGate(result: .dolbyVision)
        let viewModel = PlayerViewModel(
            provider: provider, itemID: current.item.id,
            engineFactory: EngineFactory(
                makeNative: { _ in SpyVideoEngine() }, makePlozzigen: { engine },
                probeSourceDynamicRange: { await gate.probe($0) }
            )
        )
        await viewModel.load()
        engine.onProbedSourceFactsChanged?(EngineProbedSourceFacts(range: .dolbyVision))
        let handoff = Task { await viewModel.prepareEpisodeHandoff(to: previous.item) }
        await gate.waitUntilEntered()
        await viewModel.stop()
        await gate.release()
        let prepared = await handoff.value
        XCTAssertNil(prepared)
        let reports = await provider.reports
        XCTAssertEqual(reports.filter { $0.progress.playSessionID == "prepared-session" && $0.event == .stop }.count, 1)
        XCTAssertEqual(engine.preservedDisplayStops, [false])
    }

    func testAbandonedPreparedHandoffClearsRetainedDisplayAndSession() async throws {
        let current = try makeNetworkFileRequest(itemID: "current", kind: .episode)
        let previous = try makeNetworkFileRequest(
            itemID: "previous", kind: .episode, playSessionID: "prepared-session"
        )
        let provider = RecordingPlaybackProvider(
            request: current, requestsByItemID: ["previous": previous]
        )
        let engine = SpyVideoEngine()
        let viewModel = PlayerViewModel(
            provider: provider, itemID: current.item.id,
            engineFactory: EngineFactory(
                makeNative: { _ in SpyVideoEngine() }, makePlozzigen: { engine },
                probeSourceDynamicRange: { _ in .dolbyVision }
            )
        )
        await viewModel.load()
        engine.onProbedSourceFactsChanged?(EngineProbedSourceFacts(range: .dolbyVision))
        let prepared = await viewModel.prepareEpisodeHandoff(to: previous.item)
        XCTAssertNotNil(prepared)
        await viewModel.stop(preserveDisplayMode: true)
        await viewModel.discardEpisodeHandoff(prepared)
        XCTAssertEqual(engine.preservedDisplayStops, [true, false])
        let reports = await provider.reports
        XCTAssertEqual(reports.filter { $0.progress.playSessionID == "prepared-session" && $0.event == .stop }.count, 1)
    }

    func testCancellationDuringEpisodeResolutionReleasesLegacyProviderSession() async throws {
        let current = try makeNetworkFileRequest(itemID: "current", kind: .episode)
        let previous = try makeNetworkFileRequest(
            itemID: "previous", kind: .episode, playSessionID: "prepared-session"
        )
        let provider = RecordingPlaybackProvider(
            request: current, requestsByItemID: ["previous": previous]
        )
        let engine = SpyVideoEngine()
        let viewModel = PlayerViewModel(
            provider: provider, itemID: current.item.id,
            engineFactory: EngineFactory(
                makeNative: { _ in SpyVideoEngine() }, makePlozzigen: { engine }
            )
        )
        await viewModel.load()
        engine.onProbedSourceFactsChanged?(EngineProbedSourceFacts(range: .dolbyVision))
        let gate = PreCommitYieldGate()
        await provider.setPlaybackInfoGate(gate)
        let handoff = Task { await viewModel.prepareEpisodeHandoff(to: previous.item) }
        await waitForGate(gate, entries: 1)
        handoff.cancel()
        gate.releaseNext()
        let prepared = await handoff.value
        XCTAssertNil(prepared)
        let reports = await provider.reports
        XCTAssertEqual(reports.filter { $0.progress.playSessionID == "prepared-session" && $0.event == .stop }.count, 1)
        XCTAssertEqual(engine.stopCount, 0)
        await viewModel.stop()
    }

    func testCancelledDirectFilePrefetchProbeCannotPublishRange() async throws {
        let current = try makeNetworkFileRequest(
            itemID: "current",
            title: "Episode 1",
            kind: .episode,
            relativePath: "Shows/Show/S01E01.mkv"
        )
        let next = try makeNetworkFileRequest(
            itemID: "next",
            title: "Episode 2",
            kind: .episode,
            relativePath: "Shows/Show/S01E02.mkv"
        )
        let provider = RecordingPlaybackProvider(
            request: current,
            kind: .mediaShare,
            requestsByItemID: ["next": next]
        )
        let gate = RangeProbeGate(result: .dolbyVision)
        let viewModel = PlayerViewModel(
            provider: provider,
            itemID: current.item.id,
            engineFactory: EngineFactory(
                makeNative: { _ in SpyVideoEngine() },
                makePlozzigen: { SpyVideoEngine() },
                probeSourceDynamicRange: { request in
                    await gate.probe(request)
                }
            ),
            neighborResolver: { (nil, next.item) }
        )
        await gate.waitUntilEntered()

        await viewModel.stop()
        await gate.release()
        for _ in 0..<100 {
            await Task.yield()
        }

        XCTAssertNil(viewModel.prefetchedNext)
    }

    func testCancelledPrefetchProbeReleasesResolvedNonIdempotentSession() async throws {
        let current = try makeNetworkFileRequest(
            itemID: "current",
            title: "Episode 1",
            kind: .episode,
            relativePath: "Shows/Show/S01E01.mkv",
            playSessionID: "current-session"
        )
        let next = try makeNetworkFileRequest(
            itemID: "next",
            title: "Episode 2",
            kind: .episode,
            relativePath: "Shows/Show/S01E02.mkv",
            playSessionID: "next-session"
        )
        let provider = RecordingPlaybackProvider(
            request: current,
            kind: .jellyfin,
            requestsByItemID: ["next": next]
        )
        let gate = RangeProbeGate(result: .dolbyVision)
        let engine = SpyVideoEngine()
        let viewModel = PlayerViewModel(
            provider: provider,
            itemID: current.item.id,
            engineFactory: EngineFactory(
                makeNative: { _ in SpyVideoEngine() },
                makePlozzigen: { engine },
                probeSourceDynamicRange: { request in
                    await gate.probe(request)
                }
            ),
            neighborResolver: { (nil, next.item) }
        )
        await viewModel.load()
        await waitForNextEpisode(viewModel)
        engine.duration = 120
        engine.currentTime = 60
        engine.onProgress?()
        await gate.waitUntilEntered()

        await viewModel.stop()
        await gate.release()
        let released = await waitForReport(
            provider,
            itemID: next.item.id,
            event: .stop
        )

        XCTAssertTrue(released)
        XCTAssertNil(viewModel.prefetchedNext)
    }

    func testLateNeighborResolutionStartsNonIdempotentPrefetchInsideWindow() async throws {
        let current = try makeNetworkFileRequest(
            itemID: "current",
            title: "Episode 1",
            kind: .episode,
            relativePath: "Shows/Show/S01E01.mkv",
            playSessionID: "current-session"
        )
        let next = try makeNetworkFileRequest(
            metadata: MediaSourceMetadata(
                video: .init(videoRangeType: "DOVIWithHDR10")
            ),
            itemID: "next",
            title: "Episode 2",
            kind: .episode,
            relativePath: "Shows/Show/S01E02.mkv",
            playSessionID: "next-session"
        )
        let provider = RecordingPlaybackProvider(
            request: current,
            kind: .emby,
            requestsByItemID: ["next": next]
        )
        let neighbors = NeighborResolverGate(next: next.item)
        let engine = SpyVideoEngine()
        let viewModel = PlayerViewModel(
            provider: provider,
            itemID: current.item.id,
            engineFactory: EngineFactory(
                makeNative: { _ in SpyVideoEngine() },
                makePlozzigen: { engine }
            ),
            neighborResolver: { await neighbors.resolve() }
        )
        await viewModel.load()
        await neighbors.waitUntilEntered()

        engine.duration = 120
        engine.currentTime = 60
        engine.onProgress?()
        let callsBeforeNeighbors = await provider.playbackInfoCallCountValue()
        XCTAssertEqual(callsBeforeNeighbors, 1)

        await neighbors.release()
        await waitForPrefetchedNext(viewModel)

        XCTAssertEqual(viewModel.prefetchedNext?.itemID, next.item.id)
        let callsAfterNeighbors = await provider.playbackInfoCallCountValue()
        XCTAssertEqual(callsAfterNeighbors, 2)
        await viewModel.stop()
    }

    func testNeighborResolutionAfterStopCannotStartNonIdempotentPrefetch() async throws {
        let current = try makeNetworkFileRequest(
            itemID: "current",
            title: "Episode 1",
            kind: .episode,
            relativePath: "Shows/Show/S01E01.mkv",
            playSessionID: "current-session"
        )
        let next = try makeNetworkFileRequest(
            itemID: "next",
            title: "Episode 2",
            kind: .episode,
            relativePath: "Shows/Show/S01E02.mkv",
            playSessionID: "next-session"
        )
        let provider = RecordingPlaybackProvider(
            request: current,
            kind: .jellyfin,
            requestsByItemID: ["next": next]
        )
        let neighbors = NeighborResolverGate(next: next.item)
        let engine = SpyVideoEngine()
        let viewModel = PlayerViewModel(
            provider: provider,
            itemID: current.item.id,
            engineFactory: EngineFactory(
                makeNative: { _ in SpyVideoEngine() },
                makePlozzigen: { engine }
            ),
            neighborResolver: { await neighbors.resolve() }
        )
        await viewModel.load()
        await neighbors.waitUntilEntered()
        engine.duration = 120
        engine.currentTime = 60

        await viewModel.stop()
        await neighbors.release()
        for _ in 0..<100 {
            await Task.yield()
        }

        let playbackInfoCalls = await provider.playbackInfoCallCountValue()
        XCTAssertEqual(playbackInfoCalls, 1)
        XCTAssertNil(viewModel.nextEpisode)
        XCTAssertNil(viewModel.prefetchedNext)
    }

    func testForegroundReloadRetainsAuthoritativeProbeTruth() async throws {
        let request = try makeNetworkFileRequest()
        let provider = RecordingPlaybackProvider(request: request)
        let plozzigen = SpyVideoEngine()
        let viewModel = PlayerViewModel(
            provider: provider,
            itemID: request.item.id,
            engineFactory: EngineFactory(
                makeNative: { _ in SpyVideoEngine() },
                makePlozzigen: { plozzigen }
            )
        )
        await viewModel.load()
        plozzigen.onProbedSourceFactsChanged?(
            EngineProbedSourceFacts(range: .hdr10)
        )

        viewModel.didEnterBackground()
        await viewModel.resumeAfterBackground()

        XCTAssertEqual(
            viewModel.effectiveDynamicRange,
            .resolved(.hdr10, authority: .engineProbe)
        )
        await viewModel.stop()
    }

    private func waitForGate(
        _ gate: PreCommitYieldGate,
        entries: Int
    ) async {
        for _ in 0..<1_000 where gate.entryCount < entries {
            await Task.yield()
        }
        XCTAssertEqual(gate.entryCount, entries)
    }

    private func makeNetworkFileRequest(
        metadata: MediaSourceMetadata? = nil,
        itemID: String = "movie",
        title: String = "Movie",
        kind: MediaItemKind = .movie,
        relativePath: String = "Movies/Movie.mkv",
        playSessionID: String? = nil
    ) throws -> PlaybackRequest {
        let identity = try RemoteFileIdentity(
            kind: .strongETag,
            value: "\"movie-v1\""
        )
        let representation = try RemoteFileRepresentation(
            size: 1_024,
            identity: identity,
            consistency: .stronglyBound
        )
        let locator = try NetworkFileLocator(
            accountID: "account",
            sourceID: "source",
            credentialRevision: CredentialRevision(),
            relativePath: relativePath,
            representation: representation,
            formatHint: MediaFormatHint(
                container: "mkv",
                mimeType: "video/x-matroska"
            )
        )
        return PlaybackRequest(
            item: MediaItem(id: itemID, title: title, kind: kind, runtime: 120),
            playbackSource: .networkFile(locator),
            playSessionID: playSessionID,
            sourceMetadata: metadata
        )
    }

    private func waitForPrefetchedNext(_ viewModel: PlayerViewModel) async {
        for _ in 0..<1_000 where viewModel.prefetchedNext == nil {
            await Task.yield()
        }
        XCTAssertNotNil(viewModel.prefetchedNext)
    }

    private func waitForNextEpisode(_ viewModel: PlayerViewModel) async {
        for _ in 0..<1_000 where viewModel.nextEpisode == nil {
            await Task.yield()
        }
        XCTAssertNotNil(viewModel.nextEpisode)
    }

    private func waitForReport(
        _ provider: RecordingPlaybackProvider,
        itemID: String,
        event: PlaybackEvent
    ) async -> Bool {
        for _ in 0..<1_000 {
            if await provider.hasReport(itemID: itemID, event: event) {
                return true
            }
            await Task.yield()
        }
        return false
    }

    private func makeViewModel(
        playbackSettings: PlaybackSettings = .default,
        nowPlayingPublisher: (any NowPlayingPublishing)? = nil
    ) -> (
        PlayerViewModel,
        SpyVideoEngine,
        RecordingPlaybackProvider
    ) {
        let item = MediaItem(id: "movie", title: "Movie", kind: .movie, runtime: 120)
        let request = PlaybackRequest(
            item: item,
            streamURL: URL(string: "https://example.test/movie.m3u8")!
        )
        let provider = RecordingPlaybackProvider(request: request)
        let engine = SpyVideoEngine()
        let viewModel = PlayerViewModel(
            provider: provider,
            itemID: item.id,
            playbackSettings: playbackSettings,
            engineFactory: EngineFactory(makeNative: { _ in engine }),
            nowPlayingPublisher: nowPlayingPublisher
        )
        return (viewModel, engine, provider)
    }
}

@MainActor
private final class PreCommitYieldGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private(set) var entryCount = 0

    func suspend() async {
        entryCount += 1
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func releaseNext() {
        guard !continuations.isEmpty else { return }
        continuations.removeFirst().resume()
    }
}

private actor RecordingPlaybackProvider: MediaProvider {
    struct Report: Sendable {
        let event: PlaybackEvent
        let progress: PlaybackProgress
    }

    nonisolated let kind: ProviderKind
    nonisolated let session = UserSession(
        server: MediaServer(
            id: "server",
            name: "Server",
            baseURL: URL(string: "https://example.test")!,
            provider: .jellyfin
        ),
        userID: "user",
        userName: "User",
        deviceID: "device",
        accessToken: "token"
    )

    private let request: PlaybackRequest
    private let requestsByItemID: [String: PlaybackRequest]
    private let playlistMembers: [MediaItem]
    private let playlistPageLimit: Int?
    private let childrenByParent: [String: [MediaItem]]
    private var childErrors: [String: any Error] = [:]
    private var itemError: (any Error)?
    private var playbackInfoGate: PreCommitYieldGate?
    private var childGates: [String: PreCommitYieldGate] = [:]
    private var childIDs: [String] = []
    private var playlistMemberError: AppError?
    private(set) var playlistMemberRequests = 0
    private(set) var childRequests = 0
    private(set) var reports: [Report] = []
    private(set) var playbackInfoCallCount = 0
    private(set) var itemCallCount = 0

    init(
        request: PlaybackRequest,
        kind: ProviderKind = .jellyfin,
        requestsByItemID: [String: PlaybackRequest] = [:],
        playlistMembers: [MediaItem] = [],
        playlistPageLimit: Int? = nil,
        childrenByParent: [String: [MediaItem]] = [:]
    ) {
        self.request = request
        self.kind = kind
        self.requestsByItemID = requestsByItemID
        self.playlistMembers = playlistMembers
        self.playlistPageLimit = playlistPageLimit
        self.childrenByParent = childrenByParent
    }

    func libraries() async throws -> [MediaLibrary] { [] }
    func continueWatching(limit: Int) async throws -> [MediaItem] { [] }
    func latest(limit: Int) async throws -> [MediaItem] { [] }
    func item(id: String) async throws -> MediaItem {
        itemCallCount += 1
        if let itemError { throw itemError }
        return requestsByItemID[id]?.item ?? request.item
    }
    func setItemError(_ error: (any Error)?) { itemError = error }
    func children(of itemID: String) async throws -> [MediaItem] {
        childRequests += 1
        childIDs.append(itemID)
        if let gate = childGates[itemID] { await gate.suspend() }
        if let error = childErrors[itemID] { throw error }
        return childrenByParent[itemID] ?? []
    }
    func requestedChildIDs() -> [String] { childIDs }
    func setChildGate(_ gate: PreCommitYieldGate?, for id: String) { childGates[id] = gate }
    func setChildError(_ error: (any Error)?, for id: String) { childErrors[id] = error }
    func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        MediaPage(items: [], startIndex: page.startIndex, totalCount: 0)
    }
    func videoPlaylistMembers(of playlistID: String, page: PageRequest) async throws -> MediaPage {
        playlistMemberRequests += 1
        if let playlistMemberError { throw playlistMemberError }
        return MediaPage(
            items: Array(
                playlistMembers.dropFirst(page.startIndex)
                    .prefix(min(page.limit, playlistPageLimit ?? page.limit))
            ),
            startIndex: page.startIndex, totalCount: playlistMembers.count
        )
    }
    func setPlaylistMemberError(_ error: AppError?) { playlistMemberError = error }
    func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
    func playbackInfo(for itemID: String) async throws -> PlaybackRequest {
        playbackInfoCallCount += 1
        return requestsByItemID[itemID] ?? request
    }
    func playbackInfo(for itemID: String, mediaSourceID: String?, forceTranscode: Bool) async throws -> PlaybackRequest {
        playbackInfoCallCount += 1
        await playbackInfoGate?.suspend()
        return requestsByItemID[itemID] ?? request
    }

    func setPlaybackInfoGate(_ gate: PreCommitYieldGate) { playbackInfoGate = gate }
    func itemCallCountValue() -> Int { itemCallCount }
    func playbackInfoCallCountValue() -> Int { playbackInfoCallCount }
    func hasReport(itemID: String, event: PlaybackEvent) -> Bool {
        reports.contains {
            $0.progress.itemID == itemID && $0.event == event
        }
    }
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {
        reports.append(Report(event: event, progress: progress))
    }
    nonisolated func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
}

private actor RangeProbeRecorder {
    private let result: SourceDynamicRange?
    private var requests: [PlaybackRequest] = []

    init(result: SourceDynamicRange?) {
        self.result = result
    }

    func probe(_ request: PlaybackRequest) -> SourceDynamicRange? {
        requests.append(request)
        return result
    }

    func callCount() -> Int { requests.count }
    func lastItemID() -> String? { requests.last?.item.id }
}

private actor RangeProbeGate {
    private let result: SourceDynamicRange?
    private var didEnter = false
    private var continuation: CheckedContinuation<Void, Never>?

    init(result: SourceDynamicRange?) {
        self.result = result
    }

    func probe(_ request: PlaybackRequest) async -> SourceDynamicRange? {
        _ = request
        didEnter = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
        return result
    }

    func waitUntilEntered() async {
        while !didEnter {
            await Task.yield()
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private actor NeighborResolverGate {
    private let next: MediaItem
    private var didEnter = false
    private var continuation:
        CheckedContinuation<(previous: MediaItem?, next: MediaItem?), Never>?

    init(next: MediaItem) {
        self.next = next
    }

    func resolve() async -> (previous: MediaItem?, next: MediaItem?) {
        didEnter = true
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilEntered() async {
        while !didEnter {
            await Task.yield()
        }
    }

    func release() {
        continuation?.resume(returning: (nil, next))
        continuation = nil
    }
}

@MainActor
private final class SpyVideoEngine: VideoEngine {
    var maximumPlaybackSpeed = 4.0
    var backgroundAudioEnabled = false
    func setBackgroundAudioEnabled(_ enabled: Bool) { backgroundAudioEnabled = enabled }
    let displayName = "spy"
    var status: VideoEngineStatus = .idle
    var isPaused = false
    var preventsDisplaySleep = false
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 0
    var furthestObservedPosition: TimeInterval = 0
    var audioTracks: [MediaTrack] = []
    var subtitleTracks: [MediaTrack] = []
    var onProgress: (@MainActor () -> Void)?
    var onFailure: (@MainActor (AppError) -> Void)?
    var onEnded: (@MainActor () -> Void)?
    var onTracksChanged: (@MainActor () -> Void)?
    var onProbedSourceFactsChanged: (@MainActor (EngineProbedSourceFacts) -> Void)?
    var onSubtitleCues: (@MainActor ([SubtitleCue]) -> Void)?
    var onSecondarySubtitleCues: (@MainActor ([SubtitleCue]) -> Void)?
    var loadCount = 0
    var stopCount = 0
    var preservedDisplayStops: [Bool] = []
    var drainTransportCount = 0
    var reloadAfterForegroundCount = 0
    var drainGate: PreCommitYieldGate?
    var failureDuringLoad: AppError?
    var cancelDuringLoad = false

    func load(request: PlaybackRequest, startPosition: TimeInterval) async {
        loadCount += 1
        if let failureDuringLoad { status = .failed(failureDuringLoad) }
        else { status = .ready }
        currentTime = startPosition
        furthestObservedPosition = max(furthestObservedPosition, startPosition)
        if cancelDuringLoad { withUnsafeCurrentTask { $0?.cancel() } }
    }

    func play() { isPaused = false }
    func pause() { isPaused = true }
    func reloadAfterForeground() async throws {
        reloadAfterForegroundCount += 1
    }
    func seek(to seconds: TimeInterval) async {
        currentTime = seconds
        furthestObservedPosition = max(furthestObservedPosition, seconds)
    }
    func stop() {
        stop(preserveDisplayMode: false)
    }
    func stop(preserveDisplayMode: Bool) {
        stopCount += 1
        preservedDisplayStops.append(preserveDisplayMode)
        status = .idle
        duration = 0
    }
    func drainTransport() async {
        drainTransportCount += 1
        await drainGate?.suspend()
    }
    func selectAudioTrack(_ track: MediaTrack?) {}
    func selectSubtitleTrack(_ track: MediaTrack?) {}

    #if canImport(UIKit)
    func makeVideoOutputView() -> UIView { UIView() }
    #endif
}

private final class PlaybackStoppedRecorder: @unchecked Sendable {
    struct Call {
        let position: TimeInterval
        let percent: Double
    }

    private let lock = NSLock()
    private var calls: [Call] = []

    var onlyCall: Call? {
        lock.lock()
        defer { lock.unlock() }
        XCTAssertEqual(calls.count, 1)
        return calls.first
    }

    func record(position: TimeInterval, percent: Double) {
        lock.lock()
        calls.append(Call(position: position, percent: percent))
        lock.unlock()
    }
}
#endif
