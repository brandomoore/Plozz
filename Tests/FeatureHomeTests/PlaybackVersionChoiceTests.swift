import CoreModels
import CoreNetworking
import XCTest
@testable import FeatureHomeCore

@MainActor
final class PlaybackVersionChoiceTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!
    private var settings: PlaybackSettingsModel!
    private var preferences: VersionPreferenceStore!
    private var model: PlaybackVersionChoiceModel!

    override func setUp() async throws {
        suite = "version-choice-\(UUID())"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        settings = PlaybackSettingsModel(store: PlaybackSettingsStore(defaults: defaults))
        preferences = VersionPreferenceStore(defaults: defaults)
        model = PlaybackVersionChoiceModel()
    }

    override func tearDown() async throws {
        model.cancel()
        defaults.removePersistentDomain(forName: suite)
    }

    private func item(_ id: String = "movie", series: String? = nil) -> MediaItem {
        MediaItem(
            id: id, title: "Example", kind: series == nil ? .movie : .episode,
            seriesID: series, sourceAccountID: "server",
            versions: [
                .init(id: "\(id)-1080", height: 1080, videoRange: "SDR"),
                .init(id: "\(id)-4k", height: 2160, videoRange: "HDR10")
            ]
        )
    }

    private func start(
        _ item: MediaItem, provider: FakeMediaProvider? = nil,
        isCurrent: @escaping () -> Bool = { true }
    ) -> Task<MediaItem, Error> {
        let model = self.model!
        let settings = self.settings!
        let preferences = self.preferences!
        return Task {
            try await model.prepare(
                item, provider: provider ?? FakeMediaProvider(allItems: [item]),
                settings: settings, preferences: preferences, capabilities: .default, isCurrent: isCurrent
            )
        }
    }

    private func pending() async throws -> PlaybackVersionChoiceModel.Prompt {
        let deadline = ContinuousClock.now + .seconds(2)
        while model.prompt == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        return try XCTUnwrap(model.prompt)
    }

    private func assertCancelled(_ task: Task<MediaItem, Error>) async {
        do {
            _ = try await task.value
            XCTFail("A cancelled choice must not start playback.")
        } catch is CancellationError {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testColdSingleVersionSeedWaitsForInventoryBeforeFirstAndEveryTimePicker() async throws {
        for mode: PlaybackVersionSelectionMode? in [nil, .askEveryTime, .automatic] {
            settings.settings.versionSelectionMode = mode
            let full = item()
            var seed = full
            seed.versions = [full.versions[0]]
            seed.selectedVersionID = full.versions[0].id
            let provider = FakeMediaProvider(allItems: [full])
            let gate = VersionInventoryGate()
            provider.itemGate = [full.id: { await gate.wait() }]
            let task = start(seed, provider: provider)
            defer { task.cancel() }
            let deadline = ContinuousClock.now + .seconds(2)
            while provider.itemCallCount(for: full.id) == 0, ContinuousClock.now < deadline {
                await Task.yield()
            }
            XCTAssertEqual(provider.itemCallCount(for: full.id), 1)
            XCTAssertTrue(model.isPreparing, "A seed's single version is not a complete inventory.")
            XCTAssertNil(model.prompt, "Do not show an incomplete picker either.")
            await gate.release()
            if mode == .automatic {
                let selected = try await task.value
                XCTAssertEqual(selected.selectedVersionID, full.versions[1].id)
            } else {
                let prompt = try await pending()
                XCTAssertEqual(prompt.versions.count, 2)
                XCTAssertEqual(prompt.needsIntroduction, mode == nil)
                model.cancel()
                await assertCancelled(task)
            }
        }
    }

    func testCachedVersionsCannotBypassInventoryFailureOrRevokedProfile() async throws {
        settings.settings.versionSelectionMode = .askEveryTime
        do {
            _ = try await start(item(), provider: FakeMediaProvider(allItems: [])).value
            XCTFail("Cached metadata must not turn a failed inventory into playback.")
        } catch let error as AppError {
            XCTAssertEqual(error, .notFound)
        }
        var current = true
        let full = item()
        let gate = VersionInventoryGate()
        let provider = FakeMediaProvider(allItems: [full])
        provider.itemGate = [full.id: { await gate.wait() }]
        let task = start(full, provider: provider, isCurrent: { current })
        let deadline = ContinuousClock.now + .seconds(2)
        while provider.itemCallCount(for: full.id) == 0, ContinuousClock.now < deadline {
            await Task.yield()
        }
        current = false
        await gate.release()
        await assertCancelled(task)
        XCTAssertNil(model.prompt)
    }

    func testVersionFailurePublishesPreparationEvidenceThroughSharedGate() async throws {
        let before = Set(PlozzLog.recentEntries(limit: 500).map(\.id))
        let full = item()
        let provider = FakeMediaProvider(allItems: [full])
        provider.playbackItemHandler = { _ in
            HTTPResponseDiagnostics.recordValidationFailure(
                .duplicateSourceID, route: .playbackInventory, sourceCount: 2
            )
            throw AppError.invalidResponse
        }
        do {
            _ = try await start(full, provider: provider).value
            XCTFail("The original preparation error must still reach the caller.")
        } catch {
            XCTAssertEqual(error as? AppError, .invalidResponse)
        }
        let text = try XCTUnwrap(PlozzLog.recentEntries(limit: 500).first {
            !before.contains($0.id) && $0.message.hasPrefix("format=plozz-preparation-1")
        }?.message)
        XCTAssertTrue(text.contains("operation=versions"))
        XCTAssertTrue(text.contains("validation_0.reason=duplicateSourceID"))
        XCTAssertTrue(text.contains("validation_0.sources=2"))
        XCTAssertNil(model.prompt)
        XCTAssertFalse(model.isPreparing)
    }

    func testPreparationFailoverLoadsHealthyInventoryInsteadOfUsingCachedFiles() async throws {
        settings.settings.versionSelectionMode = .automatic
        let unavailable = item()
        var healthy = item("healthy")
        healthy.sourceAccountID = "other-server"
        let providers = [
            "server": FakeMediaProvider(allItems: []),
            "other-server": FakeMediaProvider(allItems: [healthy])
        ]
        let result = try await PlaybackVersionChoiceModel.prepareWithFailover(
            unavailable, triedAccountIDs: [],
            prepare: { candidate in
                try await self.model.prepare(
                    candidate, provider: providers[candidate.sourceAccountID!]!,
                    settings: self.settings, preferences: self.preferences, capabilities: .default
                )
            },
            nextSource: { failed, tried in
                XCTAssertEqual(failed.id, unavailable.id)
                XCTAssertEqual(tried, ["server"])
                return healthy
            }, isCurrent: { true }
        )
        XCTAssertEqual(result.item.id, healthy.id)
        XCTAssertEqual(result.item.selectedVersionID, healthy.versions[1].id)
        XCTAssertEqual(result.triedAccountIDs, ["server"])
        XCTAssertEqual(providers["other-server"]?.itemCallCount(for: healthy.id), 1)
    }

    func testPreparationFailoverPreservesExplicitSelectionCancellationAndExhaustion() async throws {
        var explicit = item()
        explicit.explicitSourceSelection = true
        for (candidate, failure) in [
            (explicit, AppError.notFound), (item(), .cancelled), (item(), .serverUnreachable)
        ] {
            var attempts = 0
            var sourceRequests = 0
            do {
                _ = try await PlaybackVersionChoiceModel.prepareWithFailover(
                    candidate, triedAccountIDs: [],
                    prepare: { _ in attempts += 1; throw failure },
                    nextSource: { _, tried in
                        sourceRequests += 1
                        XCTAssertEqual(tried, ["server"])
                        return candidate
                    }, isCurrent: { true }
                )
                XCTFail("Failed preparation must not become playback.")
            } catch is CancellationError {
                XCTAssertEqual(failure, .cancelled)
            } catch let error as AppError {
                XCTAssertEqual(error, failure)
            }
            XCTAssertEqual(attempts, 1)
            XCTAssertEqual(sourceRequests, failure == .serverUnreachable ? 1 : 0)
        }
        var current = true
        do {
            _ = try await PlaybackVersionChoiceModel.prepareWithFailover(
                item(), triedAccountIDs: [],
                prepare: { _ in current = false; throw AppError.serverUnreachable },
                nextSource: { _, _ in XCTFail("Revoked scope must not select another source."); return nil },
                isCurrent: { current }
            )
            XCTFail("Revoked preparation must cancel.")
        } catch is CancellationError {}
    }

    func testUnavailableUnselectedEditionDoesNotBlockConfirmedPrimary() async throws {
        settings.settings.versionSelectionMode = .automatic
        for failure: any Error in [AppError.notFound, StreamingQualityError.noStreams, AppError.serverUnreachable] {
            var primary = item()
            primary.explicitSourceSelection = true
            primary.selectedVersionID = primary.versions[0].id
            primary.sources = [
                MediaSourceRef(accountID: "server", itemID: "stale", kind: .movie, versions: item("stale").versions)
            ]
            let provider = FakeMediaProvider(allItems: [primary])
            let confirmed = primary
            provider.playbackItemHandler = { id in
                if id == "stale" { throw failure }
                return confirmed
            }
            let selected = try await start(primary, provider: provider).value
            XCTAssertEqual(selected.id, primary.id)
            XCTAssertEqual(selected.selectedVersionID, primary.selectedVersionID)
            XCTAssertTrue(selected.explicitSourceSelection)
            XCTAssertFalse(selected.sources.contains { $0.itemID == "stale" })
        }
    }

    func testAlternateInventoryCancellationStillCancelsPreparation() async throws {
        settings.settings.versionSelectionMode = .automatic
        var primary = item()
        primary.sources = [MediaSourceRef(accountID: "server", itemID: "alternate", kind: .movie)]
        let confirmed = primary
        let provider = FakeMediaProvider(allItems: [primary])
        provider.playbackItemHandler = { id in
            if id == "alternate" { throw AppError.cancelled }
            return confirmed
        }
        await assertCancelled(start(primary, provider: provider))
    }

    func testFreshSingleVersionInventoryReplacesStaleMultipleVersions() async throws {
        var cached = item()
        cached.selectedVersionID = cached.versions[1].id
        var fresh = cached
        fresh.versions = []
        let selected = try await start(cached, provider: FakeMediaProvider(allItems: [fresh])).value
        XCTAssertTrue(selected.versions.isEmpty)
        XCTAssertNil(selected.selectedVersionID)
        XCTAssertNil(model.prompt)
    }

    func testFirstPlayAwaitsSourceDiscoveryAndLoadsDiscoveredEditionFiles() async throws {
        settings.settings.versionSelectionMode = .askEveryTime
        var primary = item()
        primary.versions.removeLast()
        let alternate = item("edition")
        let provider = FakeMediaProvider(allItems: [primary, alternate])
        let gate = VersionInventoryGate()
        let references = [primary, alternate].map {
            MediaSourceRef(accountID: "server", itemID: $0.id, kind: $0.kind)
        } + [MediaSourceRef(accountID: "foreign", itemID: "ignored", kind: .movie)]
        let choice = model!
        let settings = settings!
        let preferences = preferences!
        let task = Task {
            try await choice.prepare(
                primary, provider: provider, settings: settings, preferences: preferences,
                sourceResolver: { _ in
                    await gate.wait()
                    return CrossServerSourceResolution(sources: references)
                }
            )
        }
        defer { task.cancel() }
        let deadline = ContinuousClock.now + .seconds(2)
        while provider.itemCallCount(for: primary.id) == 0, ContinuousClock.now < deadline {
            await Task.yield()
        }
        XCTAssertTrue(model.isPreparing)
        XCTAssertNil(model.prompt)
        await gate.release()
        let prompt = try await pending()
        XCTAssertEqual(prompt.versions.count, 3)
        XCTAssertEqual(provider.itemCallCount(for: alternate.id), 1)
        XCTAssertEqual(provider.itemCallCount(for: "ignored"), 0)
        XCTAssertTrue(prompt.versions.allSatisfy { $0.sourceAccountID == "server" })
        model.cancel()
        await assertCancelled(task)
    }

    func testFirstUseAskOpensPickerAndAutomaticStartsWithoutPicking() async throws {
        for mode in PlaybackVersionSelectionMode.allCases {
            settings.settings.versionSelectionMode = nil
            let movie = item()
            let key = DetailPlaybackSelection.versionPreferenceKey(for: movie)
            preferences.setPreferredVersionID(nil, forTitle: key)
            preferences.setPreferredVersionDescriptor(nil, forTitle: key)
            let task = start(movie)
            defer { task.cancel() }
            let prompt = try await pending()
            XCTAssertTrue(prompt.needsIntroduction)
            model.chooseVersion(movie.versions[1].id, promptID: prompt.id)
            XCTAssertNotNil(model.prompt, "The introduction requires an explicit mode choice.")
            model.chooseMode(mode, promptID: prompt.id)
            XCTAssertEqual(settings.settings.versionSelectionMode, mode)
            if mode == .askEveryTime {
                XCTAssertFalse(try XCTUnwrap(model.prompt).needsIntroduction)
                model.chooseVersion(movie.versions[1].id, promptID: prompt.id)
            } else {
                XCTAssertNil(model.prompt, "Automatic must not require a second version choice.")
                XCTAssertNil(preferences.preferredVersionID(forTitle: key))
            }
            let selected = try await task.value
            XCTAssertEqual(selected.selectedVersionID, movie.versions[1].id)
            XCTAssertEqual(selected.sourceAccountID, "server")
            XCTAssertEqual(selected.explicitSourceSelection, mode == .askEveryTime)
            XCTAssertNil(model.prompt)
        }
    }

    func testDiscoveredPrimaryCannotMaskOrCollapseAuthoritativeVersionsAfterSelection() async throws {
        for staleVersions: [MediaVersion] in [[], [.init(id: "stale")]] {
            settings.settings.versionSelectionMode = .askEveryTime
            let full = item()
            let reference = MediaSourceRef(
                accountID: "server", itemID: full.id, kind: full.kind, versions: staleVersions
            )
            let choice = model!
            let settings = settings!
            let preferences = preferences!
            let task = Task {
                try await choice.prepare(
                    full, provider: FakeMediaProvider(allItems: [full]),
                    settings: settings, preferences: preferences,
                    sourceResolver: { _ in CrossServerSourceResolution(sources: [reference]) }
                )
            }
            defer { task.cancel() }
            let prompt = try await pending()
            XCTAssertEqual(Set(prompt.versions.compactMap(\.playbackMediaSourceID)), Set(full.versions.map(\.id)))
            model.chooseVersion(prompt.versions[1].id, promptID: prompt.id)
            let selected = try await task.value
            XCTAssertEqual(PlayerVersionSelection.versions(for: selected).count, 2)
            XCTAssertEqual(selected.versions.map(\.id), full.versions.map(\.id))
        }
    }

    func testVersionFailurePreservesTypedCopyWithoutDisplayingUnknownDetails() {
        XCTAssertEqual(
            String(localized: PlaybackVersionChoiceModel.reportFailure(StreamingQualityError.sourceUnavailable)),
            String(localized: StreamingQualityError.sourceUnavailable.userMessage)
        )
        XCTAssertEqual(
            String(localized: PlaybackVersionChoiceModel.reportFailure(AppError.serverUnreachable)),
            String(localized: AppError.serverUnreachable.userMessage)
        )
        struct UnknownFailure: Error {}
        XCTAssertEqual(
            String(localized: PlaybackVersionChoiceModel.reportFailure(UnknownFailure())),
            String(localized: StreamingQualityError.negotiationFailed.userMessage)
        )
    }

    func testAskEveryTimeStillAsksAfterRememberingIncludingNextEpisode() async throws {
        settings.settings.versionSelectionMode = .askEveryTime
        for id in ["episode-1", "episode-1", "episode-2"] {
            let episode = item(id, series: "series")
            let task = start(episode)
            defer { task.cancel() }
            let prompt = try await pending()
            XCTAssertFalse(prompt.needsIntroduction)
            model.chooseVersion(episode.versions[1].id, promptID: prompt.id)
            let selected = try await task.value
            XCTAssertEqual(selected.selectedVersionID, episode.versions[1].id)
        }
    }

    func testAutomaticSeriesMatchesDifferentFileIDsAndNeverPromptsForMissingPreference() async throws {
        settings.settings.versionSelectionMode = .automatic
        let first = item("episode-1", series: "series")
        preferences.rememberVersion(first.versions[1], forTitle: DetailPlaybackSelection.versionPreferenceKey(for: first))
        let next = item("episode-2", series: "series")
        let selected = try await start(next).value
        XCTAssertEqual(selected.selectedVersionID, "episode-2-4k")
        XCTAssertNil(model.prompt)
        var missing = item("episode-3", series: "series")
        missing.versions.removeLast()
        let sole = try await start(missing).value
        XCTAssertEqual(sole, missing)
        XCTAssertNil(model.prompt)
        missing.versions.append(.init(id: "episode-3-720", height: 720, videoRange: "SDR"))
        let fallback = try await start(missing).value
        XCTAssertEqual(fallback.selectedVersionID, "episode-3-1080")
        XCTAssertNil(model.prompt)
        XCTAssertEqual(preferences.preferredVersionDescriptor(forTitle: DetailPlaybackSelection.versionPreferenceKey(for: first))?.height, 2160)
    }

    func testAutomaticMovieKeepsExactFileAndNewTitlesNeverAsk() async throws {
        settings.settings.versionSelectionMode = .automatic
        let movie = item()
        preferences.rememberVersion(movie.versions[0], forTitle: DetailPlaybackSelection.versionPreferenceKey(for: movie))
        let selected = try await start(movie).value
        XCTAssertEqual(selected.selectedVersionID, "movie-1080")
        let other = try await start(item("other")).value
        XCTAssertEqual(other.selectedVersionID, "other-4k")
        XCTAssertNil(model.prompt)
        XCTAssertNil(preferences.preferredVersionID(forTitle: DetailPlaybackSelection.versionPreferenceKey(for: other)))
    }

    func testSingleVersionAndNonVideoDoNotConsumeIntroduction() async throws {
        var movie = item()
        movie.versions.removeLast()
        let selected = try await start(movie).value
        XCTAssertEqual(selected, movie)
        var container = item()
        container.kind = .series
        let bypassed = try await start(container).value
        XCTAssertEqual(bypassed, container)
        XCTAssertNil(settings.settings.versionSelectionMode)
        XCTAssertNil(model.prompt)
    }

    func testCancellationBeforeChoicePersistsNothingAndCanBeAskedAgain() async throws {
        let task = start(item())
        _ = try await pending()
        task.cancel()
        await assertCancelled(task)
        XCTAssertNil(settings.settings.versionSelectionMode)
        XCTAssertNil(model.prompt)
        let second = start(item())
        defer { second.cancel() }
        let prompt = try await pending()
        XCTAssertTrue(prompt.needsIntroduction)
        model.cancel()
        await assertCancelled(second)
    }

    func testCancelAfterModeKeepsModeButDoesNotInventFilePreference() async throws {
        let task = start(item())
        let prompt = try await pending()
        model.chooseMode(.askEveryTime, promptID: prompt.id)
        model.cancel()
        await assertCancelled(task)
        XCTAssertEqual(settings.settings.versionSelectionMode, .askEveryTime)
        XCTAssertNil(preferences.preferredVersionID(forTitle: DetailPlaybackSelection.versionPreferenceKey(for: item())))
    }

    func testStaleProfileAndStalePromptCannotSaveOrStart() async throws {
        var current = true
        let task = start(item(), isCurrent: { current })
        let prompt = try await pending()
        model.chooseMode(.askEveryTime, promptID: UUID())
        XCTAssertNil(settings.settings.versionSelectionMode)
        current = false
        model.chooseMode(.automatic, promptID: prompt.id)
        await assertCancelled(task)
        XCTAssertNil(settings.settings.versionSelectionMode)
    }

    func testSettingsChoiceSkipsIntroductionAndCanChangeBetweenPlays() async throws {
        let movie = item()
        preferences.rememberVersion(movie.versions[1], forTitle: DetailPlaybackSelection.versionPreferenceKey(for: movie))
        settings.settings.versionSelectionMode = .automatic
        let remembered = try await start(movie).value
        XCTAssertEqual(remembered.selectedVersionID, "movie-4k")
        settings.settings.versionSelectionMode = .askEveryTime
        let task = start(movie)
        defer { task.cancel() }
        let prompt = try await pending()
        XCTAssertFalse(prompt.needsIntroduction)
        model.cancel()
        await assertCancelled(task)
    }

    func testProfileInvalidationDuringFileChoiceCannotSavePreference() async throws {
        var current = true
        settings.settings.versionSelectionMode = .askEveryTime
        let movie = item()
        let task = start(movie, isCurrent: { current })
        let prompt = try await pending()
        current = false
        model.chooseVersion("movie-4k", promptID: prompt.id)
        await assertCancelled(task)
        XCTAssertNil(preferences.preferredVersionID(forTitle: DetailPlaybackSelection.versionPreferenceKey(for: movie)))
    }

    func testOfflineLightweightItemNeverRequiresServerDetails() async throws {
        struct Local: OfflinePlaybackResolving {
            func localPlaybackURL(for item: MediaItem, versionID: String?) async -> URL? {
                URL(fileURLWithPath: "/fixture/download.mkv")
            }

        }
        var movie = item()
        movie.versions = []
        let provider = FakeMediaProvider(allItems: [])
        let selected = try await model.prepare(
            movie, provider: provider, settings: settings, preferences: preferences,
            offlineResolver: Local()
        )
        XCTAssertEqual(selected, movie)
        XCTAssertEqual(provider.itemCallCount(for: movie.id), 0)
        XCTAssertNil(settings.settings.versionSelectionMode)
    }

    func testDownloadedMultiVersionItemBypassesEveryVersionSelectionMode() async throws {
        struct Local: OfflinePlaybackResolving {
            func localPlaybackURL(for item: MediaItem, versionID: String?) async -> URL? {
                URL(fileURLWithPath: "/fixture/download.mkv")
            }
        }
        for mode: PlaybackVersionSelectionMode? in [nil, .askEveryTime, .automatic] {
            settings.settings.versionSelectionMode = mode
            var movie = item()
            movie.selectedVersionID = movie.versions[1].id
            let provider = FakeMediaProvider(allItems: [])
            let finished = expectation(description: "Local playback bypasses \(String(describing: mode))")
            let task = Task {
                let selected = try await model.prepare(
                    movie, provider: provider, settings: settings, preferences: preferences,
                    offlineResolver: Local(),
                    sourceResolver: { _ in
                        XCTFail("Local playback must not discover server alternatives")
                        return .init(sources: [])
                    }
                )
                finished.fulfill()
                return selected
            }
            await fulfillment(of: [finished], timeout: 2)
            model.cancel()
            task.cancel()
            let selected = try await task.value
            XCTAssertEqual(selected, movie)
            XCTAssertNil(model.prompt)
            XCTAssertEqual(provider.itemCallCount(for: movie.id), 0)
            XCTAssertEqual(settings.settings.versionSelectionMode, mode)
        }
    }

    func testSeriesMemoryToggleAppliesImmediatelyToGateAndExistingRequestResolver() async throws {
        settings.settings.versionSelectionMode = .automatic
        let first = item("episode-1", series: "series")
        let key = DetailPlaybackSelection.versionPreferenceKey(for: first)
        preferences.rememberVersion(first.versions[0], forTitle: key)
        let next = item("episode-2", series: "series")
        let remembered = try await start(next).value
        XCTAssertEqual(remembered.selectedVersionID, "episode-2-1080")
        settings.settings.rememberVersionPerSeries = false
        let automatic = try await start(next).value
        XCTAssertEqual(automatic.selectedVersionID, "episode-2-4k")
        XCTAssertEqual(
            DetailPlaybackSelection.playbackReady(next, preferences: preferences, capabilities: .default).selectedVersionID,
            "episode-2-4k"
        )
        XCTAssertEqual(preferences.preferredVersionDescriptor(forTitle: key)?.height, 1080)
        settings.settings.rememberVersionPerSeries = true
        let restored = try await start(next).value
        XCTAssertEqual(restored.selectedVersionID, "episode-2-1080")
    }

    func testAskHighlightsRememberedVersionButDisabledMemoryNeverReplacesIt() async throws {
        settings.settings.versionSelectionMode = .askEveryTime
        let first = item("episode-1", series: "series")
        let key = DetailPlaybackSelection.versionPreferenceKey(for: first)
        preferences.rememberVersion(first.versions[0], forTitle: key)
        let next = item("episode-2", series: "series")
        let task = start(next)
        defer { task.cancel() }
        let prompt = try await pending()
        XCTAssertEqual(prompt.selectedVersionID, "episode-2-1080")
        model.cancel()
        await assertCancelled(task)
        settings.settings.rememberVersionPerSeries = false
        let second = start(next)
        defer { second.cancel() }
        let unremembered = try await pending()
        XCTAssertEqual(unremembered.selectedVersionID, "episode-2-4k")
        model.chooseVersion("episode-2-4k", promptID: unremembered.id)
        let selected = try await second.value
        XCTAssertEqual(selected.selectedVersionID, "episode-2-4k")
        XCTAssertEqual(preferences.preferredVersionDescriptor(forTitle: key)?.height, 1080)
    }

    func testAutomaticUsesEngineSupportAndStillHonorsManualSelection() async throws {
        settings.settings.versionSelectionMode = .automatic
        var movie = item()
        movie.versions = [
            .init(id: "hdr", height: 2160, videoCodec: "hevc", videoRange: "HDR10", audioCodec: "dts"),
            .init(id: "sdr", height: 1080, videoCodec: "h264", videoRange: "SDR", audioCodec: "aac")
        ]
        let recommended = try await start(movie).value
        XCTAssertEqual(recommended.selectedVersionID, "hdr")
        XCTAssertFalse(recommended.explicitSourceSelection)
        let manual = try XCTUnwrap(PlayerVersionSelection.selecting("sdr", in: movie))
        let honored = try await start(manual).value
        XCTAssertEqual(honored.selectedVersionID, "sdr")
        XCTAssertTrue(honored.explicitSourceSelection)
    }

    func testUnknownVersionsAreLoadedBeforeTheGateForBothServerKinds() async throws {
        for kind in [ProviderKind.jellyfin, .plex, .emby, .silo] {
            let full = item()
            var lightweight = full
            lightweight.versions = []
            let provider = FakeMediaProvider(allItems: [full], kind: kind)
            let task = Task {
                try await model.prepare(lightweight, provider: provider, settings: settings, preferences: preferences)
            }
            defer { task.cancel() }
            let prompt = try await pending()
            XCTAssertTrue(prompt.needsIntroduction)
            XCTAssertEqual(provider.itemCallCount(for: full.id), 1)
            model.cancel()
            await assertCancelled(task)
        }
    }

    func testDetailFailureIsAnErrorNotDefaultPlayback() async throws {
        var lightweight = item()
        lightweight.versions = []
        do {
            _ = try await model.prepare(
                lightweight, provider: FakeMediaProvider(allItems: []),
                settings: settings, preferences: preferences
            )
            XCTFail("Missing version details must not silently select a default.")
        } catch let error as AppError {
            XCTAssertEqual(error, .notFound)
        }
        XCTAssertNil(model.prompt)
        XCTAssertNil(settings.settings.versionSelectionMode)
    }

    func testCombinedEditionsRetainRawProviderIDsAndRejectForeignAccounts() async throws {
        settings.settings.versionSelectionMode = .askEveryTime
        let first = item()
        var extended = item("extended")
        extended.edition = "Extended"
        var foreign = first
        foreign.sourceAccountID = "foreign"
        var combined = first
        combined.sources = [first, extended, foreign].map {
            MediaSourceRef(accountID: $0.sourceAccountID!, itemID: $0.id, kind: $0.kind, versions: $0.versions)
        }
        let provider = FakeMediaProvider(allItems: [first, extended])
        let task = start(combined, provider: provider)
        defer { task.cancel() }
        let prompt = try await pending()
        XCTAssertTrue(prompt.versions.allSatisfy { $0.sourceAccountID == "server" })
        let version = try XCTUnwrap(prompt.versions.first { $0.sourceItemID == "extended" })
        model.chooseVersion(version.id, promptID: prompt.id)
        let selected = try await task.value
        XCTAssertEqual(selected.id, "extended")
        XCTAssertEqual(selected.sourceAccountID, "server")
        XCTAssertEqual(selected.selectedVersionID, version.playbackMediaSourceID)
        XCTAssertNotEqual(selected.selectedVersionID, version.id)
        XCTAssertEqual(provider.itemCallCount(for: "extended"), 1)
    }
}

private actor VersionInventoryGate {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        released = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}
