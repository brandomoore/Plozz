import CoreModels
@testable import CoreUI
import FeatureAuth
import FeatureHomeCore
import MetadataKit
import Observation
import SwiftUI
import UIKit
import Vision
import XCTest
@testable import AppShelliOS

@MainActor
final class HeroLogoContinuityTests: XCTestCase {
    func testPlayPlaceholderCrossfadeRendersAndRespectsReducedMotion() async throws {
        XCTAssertFalse(UIAccessibility.isReduceMotionEnabled)
        for reduced in [false, true] {
            let fixture = try Fixture()
            defer { fixture.close() }
            let state = PlayState()
            fixture.host.rootView = AnyView(
                PlayFixture(state: state).environment(\._accessibilityReduceMotion, reduced)
            )
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertLessThan(try fixture.playTextIntensity(), 10)
            state.isPlaceholder = false
            let start = ContinuousClock.now
            var samples: [(Duration, Double)] = []
            repeat {
                samples.append((start.duration(to: .now), try fixture.playTextIntensity()))
                try await Task.sleep(for: .milliseconds(8))
            } while start.duration(to: .now) < .milliseconds(300)
            let final = try fixture.playTextIntensity()
            XCTAssertGreaterThan(final, 180)
            let measurements = XCTAttachment(string: samples.map { "\($0.0): \($0.1)" }.joined(separator: "\n"))
            measurements.name = "play-placeholder-opacity-reduced-\(reduced)"
            measurements.lifetime = .keepAlways
            add(measurements)
            let partial = samples.first { $0.1 > final * 0.1 && $0.1 < final * 0.9 }
            if reduced {
                XCTAssertNil(partial)
            } else {
                XCTAssertNotNil(partial, "The ready label must crossfade, not pop into place.")
                let complete = try XCTUnwrap(samples.first { $0.1 > final * 0.98 })
                XCTAssertLessThan(complete.0, .milliseconds(200))
            }
        }
    }

    func testHomeOnlyFadesTheFirstContentAfterAVisibleEmptyPage() async throws {
        for (warm, reduced) in [(true, false), (false, true), (false, false)] {
            let fixture = try Fixture(size: CGSize(width: 390, height: 844))
            defer { fixture.close() }
            let state = PlayState()
            state.isPlaceholder = !warm
            fixture.host.rootView = AnyView(
                HomeEntranceFixture(state: state).environment(\._accessibilityReduceMotion, reduced)
            )
            if !warm {
                try await Task.sleep(for: .milliseconds(100))
                state.isPlaceholder = false
            }
            var partial = false
            try await waitUntil {
                let (hero, row) = try fixture.homeMediaSample()
                XCTAssertEqual(hero, row, accuracy: 3)
                partial = partial || (hero > 10 && hero < 240)
                return hero > 250
            }
            XCTAssertEqual(partial, !warm && !reduced)
            state.isPlaceholder = true
            try await Task.sleep(for: .milliseconds(50))
            state.isPlaceholder = false
            try await waitUntil { try fixture.homeMediaSample().0 > 0 }
            XCTAssertGreaterThan(try fixture.homeMediaSample().0, 250, "A refresh must not re-arm Home.")
        }
    }

    func testMissingOpeningArtworkWaitsForNavigationToFinish() async throws {
        XCTAssertFalse(UIAccessibility.isReduceMotionEnabled)
        for gated in [true, false] {
            let fixture = try Fixture(navigates: true, size: CGSize(width: 390, height: 844))
            defer { fixture.close() }
            let navigation = try XCTUnwrap(fixture.navigation)
            let root = try XCTUnwrap(navigation.viewControllers.first as? AppearanceHost)
            try await waitUntil { root.hasAppeared }
            let url = try fixture.seedArtwork()
            if gated {
                let cached = await ArtworkImageCache.shared.image(for: url, variant: .heroBackdrop)
                XCTAssertNotNil(cached)
            }
            let state = ArtworkState(url: gated ? url : nil, sourceReady: !gated)
            fixture.host.rootView = AnyView(ArtworkFixture(state: state))
            navigation.pushViewController(fixture.host, animated: true)
            try await Task.sleep(for: .milliseconds(40))
            XCTAssertLessThan(try fixture.artworkSample().values[1], 10, "Before resolution (gated: \(gated))")

            state.item.posterURL = url
            state.item.backdropURL = url
            state.sourceReady = true
            XCTAssertFalse(fixture.host.hasAppeared)
            var sawIntermediate = false
            try await waitUntil {
                let green = try fixture.artworkSample().values[1]
                if fixture.host.hasAppeared {
                    sawIntermediate = sawIntermediate || (green > 10 && green < 230)
                } else {
                    XCTAssertLessThan(green, 10, "Before landing (gated: \(gated))")
                }
                return green > 250
            }
            XCTAssertTrue(sawIntermediate, "Missing fade after landing (gated: \(gated))")
        }
    }

    func testLateArtworkAndReflectionsShareTheSameReveal() async throws {
        XCTAssertFalse(UIAccessibility.isReduceMotionEnabled)
        for gated in [true, false] {
            let fixture = try Fixture(navigates: true, size: CGSize(width: 390, height: 844))
            defer { fixture.close() }
            let navigation = try XCTUnwrap(fixture.navigation)
            let root = try XCTUnwrap(navigation.viewControllers.first as? AppearanceHost)
            try await waitUntil { root.hasAppeared }
            let url = try fixture.seedArtwork()
            if gated {
                let cached = await ArtworkImageCache.shared.image(for: url, variant: .heroBackdrop)
                XCTAssertNotNil(cached)
            }
            let state = ArtworkState(url: gated ? url : nil, sourceReady: !gated)
            fixture.host.rootView = AnyView(ArtworkFixture(state: state))
            navigation.pushViewController(fixture.host, animated: false)
            try await waitUntil { fixture.host.hasAppeared }
            try await Task.sleep(for: .milliseconds(100))
            let baseline = try fixture.artworkSample().values
            state.item.posterURL = url
            state.item.backdropURL = url
            state.sourceReady = true
            let start = ContinuousClock.now
            var frames: [(Duration, [Double], UIImage)] = []
            repeat {
                let sample = try fixture.artworkSample()
                frames.append((start.duration(to: .now), sample.values, sample.image))
                try await Task.sleep(for: .milliseconds(8))
            } while start.duration(to: .now) < .milliseconds(650)
            let final = try fixture.artworkSample().values
            XCTAssertGreaterThan(final[1], 230)
            let normalized = frames.map { frame in
                zip(zip(frame.1, baseline), final).map { pair, end in
                    (pair.0 - pair.1) / max(end - pair.1, 1)
                }
            }
            let measurements = XCTAttachment(string:
                "baseline: \(baseline)\nfinal: \(final)\n" +
                frames.map { "\($0.0): \($0.1)" }.joined(separator: "\n")
            )
            measurements.name = "artwork-opacity-samples-gated-\(gated)"
            measurements.lifetime = .keepAlways
            add(measurements)
            let intermediate = try XCTUnwrap(normalized.firstIndex { $0[1] > 0.1 && $0[1] < 0.9 },
                                             "Late artwork needs a rendered intermediate frame (gated: \(gated)).")
            for (index, frame) in normalized.enumerated() where frame[1] > 0.1 && frame[1] < 0.9 {
                for position in final.indices {
                    let expected = baseline[position] + (final[position] - baseline[position]) * frame[1]
                    XCTAssertEqual(frames[index].1[position], expected, accuracy: 2,
                                   "Original, top, bottom and seams must share the same reveal.")
                }
            }
            let completed = try XCTUnwrap(normalized.firstIndex { $0[1] > 0.98 })
            let visibleTail = frames[completed].0 - frames[intermediate].0
            XCTAssertGreaterThan(visibleTail, .milliseconds(150))
            XCTAssertLessThan(visibleTail, .milliseconds(400))
            let attachment = XCTAttachment(image: frames[intermediate].2)
            attachment.name = "synchronized-artwork-reveal-gated-\(gated)"
            attachment.lifetime = .keepAlways
            add(attachment)

            navigation.pushViewController(UIViewController(), animated: false)
            navigation.popViewController(animated: false)
            try await waitUntil { fixture.host.hasAppeared }
            XCTAssertEqual(try fixture.artworkSample().values[1], final[1], accuracy: 2)
        }
    }

    func testReopenedRowMoviePaintsPreviousDetailArtworkBeforeSourceVerification() async throws {
        let fixture = try Fixture(size: CGSize(width: 390, height: 844))
        defer { fixture.close() }
        let url = try fixture.seedArtwork()
        let state = ArtworkState(url: url, sourceReady: true)
        let replay = ArtworkBitmapReplay()
        fixture.host.rootView = AnyView(ArtworkFixture(state: state).environment(\.plozziOSDetailArtworkReplay, replay))
        try await waitUntil { try fixture.artworkSample().values[1] > 230 }
        fixture.host.rootView = AnyView(Color.black)
        try await waitUntil { try fixture.artworkSample().values[1] < 10 }

        // A new destination from an ordinary row has no displayed Home-hero handoff.
        state.sourceReady = false
        state.item.backdropURL = nil
        fixture.host.rootView = AnyView(ArtworkFixture(state: state).environment(\.plozziOSDetailArtworkReplay, replay))
        XCTAssertGreaterThan(try fixture.artworkSample(afterScreenUpdates: true).values[1], 230,
                             "Reopening must paint the last detail hero without waiting for live hydration.")
        fixture.host.rootView = AnyView(ArtworkFixture(state: state)
            .environment(\.plozziOSDetailArtworkReplay, ArtworkBitmapReplay()))
        XCTAssertLessThan(try fixture.artworkSample(afterScreenUpdates: true).values[1], 10,
                          "Another profile cannot borrow this image.")
    }

    func testArtworkArrivingWhileCoveredIsImmediatelyOpaqueOnReturn() async throws {
        let fixture = try Fixture(defersAppearance: true, size: CGSize(width: 390, height: 844))
        defer { fixture.close() }
        let url = try fixture.seedArtwork()
        let cached = await ArtworkImageCache.shared.image(for: url, variant: .heroBackdrop)
        XCTAssertNotNil(cached)
        let state = ArtworkState(url: url, sourceReady: false)
        fixture.host.rootView = AnyView(ArtworkFixture(state: state))
        fixture.host.view.layoutIfNeeded()
        fixture.host.beginAppearanceTransition(true, animated: false)
        fixture.host.endAppearanceTransition()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertLessThan(try fixture.artworkSample().values[1], 10)

        fixture.host.beginAppearanceTransition(false, animated: true)
        fixture.host.endAppearanceTransition()
        try await Task.sleep(for: .milliseconds(50))
        state.sourceReady = true
        try await waitUntil { try fixture.artworkSample().values[1] > 0 }
        XCTAssertGreaterThan(try fixture.artworkSample().values[1], 230,
                             "Hidden arrivals must not animate or wait for the page to return.")
        fixture.host.beginAppearanceTransition(true, animated: true)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertGreaterThan(try fixture.artworkSample().values[1], 230)
        fixture.host.endAppearanceTransition()
    }

    func testCachedPreviewAndReducedMotionArtworkAreImmediatelyOpaque() async throws {
        for reduced in [false, true] {
            let fixture = try Fixture(size: CGSize(width: 390, height: 844))
            defer { fixture.close() }
            let url = try fixture.seedArtwork()
            let cached = await ArtworkImageCache.shared.image(for: url, variant: .heroPreview)
            XCTAssertNotNil(cached)
            let state = ArtworkState(url: url, sourceReady: !reduced)
            fixture.host.rootView = AnyView(
                ArtworkFixture(state: state).environment(\._accessibilityReduceMotion, reduced)
            )
            if reduced {
                try await Task.sleep(for: .milliseconds(100))
                state.sourceReady = true
            }
            try await waitUntil { try fixture.artworkSample().values[1] > 0 }
            for _ in 0..<8 {
                XCTAssertGreaterThan(try fixture.artworkSample().values[1], 230,
                                     "Initial cached artwork and its quality upgrade must remain opaque.")
                try await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    func testSeededSynopsisIsReadableOnFirstDetailFrameAndReturn() async throws {
        let fixture = try Fixture(
            defersAppearance: true, size: CGSize(width: 390, height: 1100)
        )
        defer { fixture.close() }
        let app = PlozziOSAppModel(accountStore: AccountStore(secureStore: InMemorySecureStore()))
        let original = app.profiles.activeProfileID
        let profile = app.profiles.add(name: "Immediate detail fixture", isAwaitingSetup: false)
        app.selectProfile(profile.id)
        defer {
            app.selectProfile(original)
            app.profiles.remove(profile.id)
        }
        let provider = SeriesHeaderMobileProvider()
        let account = Account(id: "header-fixture", server: provider.session.server,
                              userID: "fixture", userName: "Fixture", deviceID: "fixture")
        app.accountsProviders.registry.register(.jellyfin) { _ in provider }
        try app.accountsProviders.accountStore.add(account, token: "fixture")
        app.accountsProviders.reloadAccounts()
        app.settings.heroBackground.settings.detailMode = .off
        fixture.host.rootView = AnyView(
            PlozziOSItemDetailView(appModel: app, provider: provider, item: provider.show)
            .environment(app)
            .environment(HeroTrailerController())
            .environment(PlozziOSSidebarGeometryModel())
            .environment(\.horizontalSizeClass, .compact)
            .environment(\.plozziOSHeroContainerHeight, 844)
            .environment(\.themePalette, .dark)
            .environment(\.plozzArtworkSettings, ArtworkSettings(preference: .library))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(.black)
        )
        for appearance in ["opening", "return"] {
            fixture.host.beginAppearanceTransition(true, animated: true)
            let frame = try fixture.redSample(afterScreenUpdates: true).image
            let attachment = XCTAttachment(image: frame)
            attachment.name = "first-detail-frame-\(appearance)"
            attachment.lifetime = .keepAlways
            add(attachment)
            let request = VNRecognizeTextRequest()
            try VNImageRequestHandler(cgImage: XCTUnwrap(frame.cgImage)).perform([request])
            let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
            XCTAssertTrue(text.contains("quiet village"), "\(appearance): \(text)")
            fixture.host.endAppearanceTransition()
            fixture.host.beginAppearanceTransition(false, animated: false)
            fixture.host.endAppearanceTransition()
        }
    }

    func testOpeningArtworkPaintsWhileDiscoveryOwnershipIsPending() async throws {
        let fixture = try Fixture(size: CGSize(width: 390, height: 1100))
        defer { fixture.close() }
        let app = PlozziOSAppModel(accountStore: AccountStore(secureStore: InMemorySecureStore()))
        let item = MediaItem(id: "pending-discovery", title: "Movie", kind: .movie,
                             locallyValidatedPlayableSource: false)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 320, height: 480)).image {
            UIColor.green.setFill()
            $0.fill(CGRect(x: 0, y: 0, width: 320, height: 480))
        }
        fixture.host.rootView = AnyView(
            PlozziOSHeroStage(
                item: item, presentation: HeroPresentation(item: item, artworkStyle: .compactPortrait, surface: .detail),
                style: .compactPortrait, surfaceRole: .detail, seedArtwork: image, isActive: false,
                trailerController: HeroTrailerController(), backgroundSettings: app.settings.heroBackground,
                trailerResolver: app.heroTrailerResolver()
            ) { EmptyView() }
            .environment(\.plozzArtworkSourceReady, false)
            .environment(\.themePalette, .dark)
            .environment(PlozziOSSidebarGeometryModel())
            .frame(width: 390, height: 844)
            .background(.black)
        )
        fixture.host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(try fixture.hasGreenArtwork(), "Home's ready bitmap must not wait for ownership or a fetch.")
    }

    func testOpeningArtworkRequiresTheSameSubjectProfilePolicyAndUsableShape() throws {
        let item = MediaItem(id: "movie", title: "Movie", kind: .movie, sourceAccountID: "account")
        let home = HeroPresentation(item: item, artworkStyle: .compactPortrait, surface: .home)
        let detail = HeroPresentation(item: item, artworkStyle: .compactPortrait, surface: .detail)
        let policy = ArtworkPresentationPolicy(area: .home, placement: home.artworkPlacement, logoLanguage: "en")
        let detailPolicy = policy.forArea(.details).forPlacement(detail.artworkPlacement)
        let reference = ArtworkReference.remote(try XCTUnwrap(URL(string: "https://art.invalid/hero.jpg")))
        for size in [CGSize(width: 320, height: 180), CGSize(width: 180, height: 320)] {
            let image = UIGraphicsImageRenderer(size: size).image { _ in }
            let artwork = FirstPaintArtwork(image: image, reference: reference, variant: .heroBackdrop)
            let displayed = DisplayedHeroArtwork(itemID: item.id, artwork: artwork)
            let seed = try XCTUnwrap(PlozziOSHeroArtworkSeed(
                item: item, displayed: displayed, profileID: "profile", policy: policy
            ))
            XCTAssertTrue(seed.image(
                for: item, profileID: "profile", policy: detailPolicy, style: .compactPortrait
            ) === image)
            XCTAssertEqual(seed.image(
                for: item, profileID: "profile", policy: detailPolicy, style: .landscape
            ) != nil, size.width > size.height)
            XCTAssertNil(seed.image(for: item, profileID: "other", policy: policy, style: .compactPortrait))
            var other = item
            other.sourceAccountID = "another-account"
            XCTAssertNil(seed.image(for: other, profileID: "profile", policy: policy, style: .compactPortrait))
            XCTAssertNil(seed.image(
                for: item, profileID: "profile",
                policy: ArtworkPresentationPolicy(placement: .detailBackdrop, logoLanguage: "fr"),
                style: .compactPortrait
            ))
            XCTAssertNil(seed.image(
                for: item, profileID: "profile",
                policy: ArtworkPresentationPolicy(
                    area: .details, settings: ArtworkSettings(preference: .library),
                    placement: detail.artworkPlacement, logoLanguage: "en"
                ),
                style: .compactPortrait
            ))
            XCTAssertNil(PlozziOSHeroArtworkSeed(
                item: item, displayed: DisplayedHeroArtwork(itemID: "other", artwork: artwork),
                profileID: "profile", policy: policy
            ))
        }
    }

    func testHomeLogoRemainsVisibleWhileDiscoveryOwnershipIsPending() async throws {
        for style: HeroArtworkStyle in [.landscape, .compactPortrait] {
            let fixture = try Fixture()
            defer { fixture.close() }
            let item = MediaItem(
                id: UUID().uuidString, title: "Discovery show", kind: .series,
                providerIDs: ["Tmdb": "123"], locallyValidatedPlayableSource: false
            )
            let seed = try await openingLogo(for: item, style: style, fixture: fixture)
            let lookup = LookupGate()
            defer { lookup.release(nil) }
            var enriched = item
            enriched.productionYear = 2026
            enriched.providerIDs["Imdb"] = "tt123"
            for ready in [false, true] {
                fixture.host.rootView = AnyView(
                    DetailMetadataFixture(
                        state: SubjectState(item: enriched), root: enriched, style: style,
                        fallback: HeroLogoFallback(for: enriched) { await lookup.resolve() },
                        artworkSettings: .default
                    )
                    .environment(\.locale, Locale(identifier: "en"))
                    .environment(\.plozzArtworkArea, .details)
                    .environment(\.plozzArtworkSourceReady, ready)
                    .environment(\.openingHeroLogo, seed.logo(for: enriched, profileID: "profile"))
                )
                fixture.host.view.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(50))
                let frame = XCTAttachment(image: try fixture.redSample().image)
                frame.name = "discovery-opening-logo-\(style)-source-ready-\(ready)"
                frame.lifetime = .keepAlways
                add(frame)
                XCTAssertTrue(try fixture.hasRedLogo(), "The displayed Home logo must survive the detail source gate.")
                XCTAssertFalse(try fixture.hasTitleText())
                XCTAssertEqual(lookup.calls, 0, "A handed-off logo must not repeat metadata lookup after hydration.")
            }
        }
    }

    func testHandedOffHomeLogoIsOpaqueOnTheFirstDetailFrame() async throws {
        let home = try Fixture()
        defer { home.close() }
        let item = MediaItem(id: UUID().uuidString, title: "Discovery show", kind: .series,
                             providerIDs: ["Tmdb": "123"], locallyValidatedPlayableSource: false)
        let seed = try await openingLogo(for: item, style: .compactPortrait, fixture: home)
        let detail = try Fixture(defersAppearance: true)
        defer { detail.close() }
        detail.host.rootView = AnyView(
            DetailMetadataFixture(
                state: SubjectState(item: item), root: item, style: .compactPortrait,
                fallback: HeroLogoFallback(for: item) { XCTFail("Handoff should not fetch"); return nil },
                artworkSettings: .default
            )
            .environment(\.locale, Locale(identifier: "en"))
            .environment(\.plozzArtworkArea, .details)
            .environment(\.plozzArtworkSourceReady, false)
            .environment(\.openingHeroLogo, seed.logo(for: item, profileID: "profile"))
        )
        detail.host.beginAppearanceTransition(true, animated: true)
        detail.host.view.layoutIfNeeded()
        XCTAssertGreaterThan(try detail.redSample(afterScreenUpdates: true).intensity, 245)
        detail.host.endAppearanceTransition()
    }

    func testOpeningLogoRejectsChangedSubjectProfilePolicyAndIdentity() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let item = MediaItem(
            id: UUID().uuidString, title: "Discovery show", kind: .series,
            providerIDs: ["Tmdb": "123"], sourceAccountID: "server"
        )
        let seed = try await openingLogo(for: item, style: .landscape, fixture: fixture)
        let lookup = LookupGate()
        defer { lookup.release(nil) }
        for change in ["profile", "subject", "account", "identity", "language", "policy"] {
            var changed = item
            switch change {
            case "subject": changed.id = "different"
            case "account": changed.sourceAccountID = "another-server"
            case "identity": changed.providerIDs["Tmdb"] = "456"
            default: break
            }
            fixture.host.rootView = AnyView(
                HeroLogoArtwork(
                    references: [],
                    asyncFallbackURL: HeroLogoFallback(for: changed) { await lookup.resolve() },
                    displayedArtworkID: changed.id,
                    presentationPolicy: .whenResolved
                ) { Text("Text fallback").foregroundStyle(.white) }
                .environment(\.locale, Locale(identifier: change == "language" ? "fr" : "en"))
                .environment(\.plozzArtworkSettings, ArtworkSettings(
                    preference: change == "policy" ? .library : .recommended
                ))
                .environment(\.plozzArtworkArea, .details)
                .environment(\.plozzArtworkSourceReady, false)
                .environment(\.openingHeroLogo, seed.logo(
                    for: changed, profileID: change == "profile" ? "another-profile" : "profile"
                ))
                .frame(width: 400, height: 250)
                .background(.black)
            )
            try await Task.sleep(for: .milliseconds(50))
            XCTAssertFalse(try fixture.hasRedLogo(), change)
            XCTAssertFalse(try fixture.hasTitleText(), change)
            XCTAssertEqual(lookup.calls, 0, "A rejected seed must not bypass source readiness.")
        }
    }

    func testInactiveAndReleasedHeroesCannotReplaceTheOpeningLogo() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let item = MediaItem(id: UUID().uuidString, title: "Current show", kind: .series)
        let seed = try await openingLogo(for: item, style: .landscape, fixture: fixture)
        let logo = try XCTUnwrap(seed.logo(for: item, profileID: "profile"))
        let state = HeroArtworkDisplayState()
        let old = UUID(), current = UUID()
        let oldReporter = HeroArtworkDisplayReporter(state: state, owner: old, itemID: "old", isActive: true)
        let reporter = HeroArtworkDisplayReporter(state: state, owner: current, itemID: item.id, isActive: true)
        let inactive = HeroArtworkDisplayReporter(state: state, owner: current, itemID: item.id, isActive: false)
        let oldLogo = DisplayedHeroLogo(itemID: "old", key: logo.key, logo: logo.logo)
        state.activate(owner: old, itemID: "old")
        oldReporter.publishLogo(oldLogo, itemID: "old")
        state.activate(owner: current, itemID: item.id)
        reporter.publishLogo(logo, itemID: item.id)
        oldReporter.publishLogo(oldLogo, itemID: "old")
        inactive.publishLogo(nil, itemID: item.id)
        try await waitUntil { state.displayedLogo?.itemID == item.id }
        XCTAssertTrue(state.displayedLogo?.logo.image === logo.logo.image)
        state.release(owner: old)
        XCTAssertEqual(state.displayedLogo?.itemID, item.id)
        reporter.publishLogo(logo, itemID: item.id)
        state.release(owner: current)
        state.activate(owner: current, itemID: item.id)
        let republished = expectation(description: "A released logo report must not publish")
        republished.isInverted = true
        withObservationTracking {
            _ = state.displayedLogo
        } onChange: {
            republished.fulfill()
        }
        await fulfillment(of: [republished], timeout: 0.1)
        XCTAssertNil(state.displayedLogo)
    }

    private func openingLogo(
        for item: MediaItem, style: HeroArtworkStyle, fixture: Fixture
    ) async throws -> PlozziOSHeroArtworkSeed {
        let url = try fixture.seedLogo()
        let displayed = HeroArtworkDisplayState()
        fixture.host.rootView = AnyView(
            PlozziOSHeroMetadata(
                presentation: HeroPresentation(item: item, artworkStyle: style, surface: .home),
                style: style, mode: .home,
                logoFallback: HeroLogoFallback(for: item) { url },
                content: .identity
            )
            .heroArtworkSource(id: item.id)
            .environment(\.heroArtworkDisplayState, displayed)
            .environment(\.themePalette, .dark)
            .environment(\.locale, Locale(identifier: "en"))
            .environment(\.plozzArtworkArea, .home)
            .frame(width: 400, height: 250)
            .background(.black)
        )
        try await waitUntil { try displayed.displayedLogo != nil && fixture.hasRedLogo() }
        return try XCTUnwrap(PlozziOSHeroArtworkSeed(
            item: item, displayed: nil, displayedLogo: displayed.displayedLogo,
            profileID: "profile",
            policy: ArtworkPresentationPolicy(area: .home, logoLanguage: "en")
        ))
    }

    func testDetailNeverShowsTextWhileItsFirstLogoIsLoading() async throws {
        for style: HeroArtworkStyle in [.landscape, .compactPortrait] {
            for findsLogo in [true, false] {
                let fixture = try Fixture()
                defer { fixture.close() }
                let url = try fixture.seedLogo()
                let item = MediaItem(id: UUID().uuidString, title: "Movie title", kind: .movie)
                let lookup = LookupGate()
                defer { lookup.release(nil) }
                fixture.host.rootView = AnyView(DetailMetadataFixture(
                    state: SubjectState(item: item), root: item, style: style,
                    fallback: HeroLogoFallback(for: item) { await lookup.resolve() }
                ))
                try await waitUntil { lookup.calls == 1 }
                XCTAssertFalse(try fixture.hasTitleText(), "Text is a failed-lookup fallback, not a loading placeholder.")
                XCTAssertFalse(try fixture.hasRedLogo())
                lookup.release(findsLogo ? url : nil)
                if findsLogo {
                    try await waitUntil { try fixture.hasRedLogo() }
                    XCTAssertFalse(try fixture.hasTitleText())
                } else {
                    try await waitUntil { try fixture.hasTitleText() }
                    XCTAssertFalse(try fixture.hasRedLogo())
                }
            }
        }
    }

    func testReopenedRowShowsLogoAndScheduleOnTheFirstFrame() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let url = try fixture.seedLogo()
        let item = MediaItem(id: UUID().uuidString, title: "Series title", kind: .series)
        func mount(verified: Bool, scope: String) {
            fixture.host.rootView = AnyView(DetailMetadataFixture(
                state: SubjectState(item: item), root: item, style: .compactPortrait,
                fallback: HeroLogoFallback(for: item) { url }, schedule: "New episode every Friday"
            )
            .environment(\.plozzArtworkSourceReady, verified)
            .detailHeroLogoVisit(scope: scope, subject: item.stablePresentationID))
        }
        mount(verified: true, scope: "original")
        try await waitUntil { try fixture.redSample().intensity > 245 && fixture.hasTitleText() }
        fixture.host.rootView = AnyView(Color.black)
        try await waitUntil { try !fixture.hasRedLogo() }
        mount(verified: false, scope: "original")
        let frame = try fixture.titleSample(afterScreenUpdates: true)
        XCTAssertGreaterThan(frame.red, 245)
        XCTAssertTrue(frame.hasWhite, "The ready schedule and reused logo belong on the same first frame.")
        mount(verified: false, scope: "another profile")
        let isolated = try fixture.titleSample(afterScreenUpdates: true)
        XCTAssertLessThan(isolated.red, 10)
        XCTAssertFalse(isolated.hasWhite)
    }

    func testContinueWatchingLogoIsOpaqueWhenMovieOrParentShowOpens() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let app = PlozziOSAppModel(accountStore: AccountStore(secureStore: InMemorySecureStore()))
        for kind in [MediaItemKind.movie, .episode] {
            let logo = try fixture.seedLogo()
            let item = MediaItem(
                id: UUID().uuidString, title: "Watching", kind: kind,
                parentTitle: kind == .episode ? "The show" : nil,
                seriesID: kind == .episode ? UUID().uuidString : nil, logoURL: logo,
                providerIDs: kind == .episode ? ["SeriesTmdb": "123", "Tmdb": "456"] : [:],
                sourceAccountID: "server"
            )
            fixture.host.rootView = AnyView(PlozziOSHomeMediaRail(
                title: Text("Continue Watching"), items: [item], style: .landscape, appModel: app,
                showsResumeChip: true, prefetchesArtwork: true, showsSeriesArtwork: true
            )
            .environment(app)
            .environment(\.plozzArtworkArea, .continueWatching)
            .environment(\.horizontalSizeClass, .compact)
            .environment(\.plozzMetrics, .touch(density: .standard, dynamicTypeSize: .large)))
            try await waitUntil { try fixture.hasRedLogo() }
            let target = PlozziOSHomeMediaCard.resolvedItem(item, appModel: app, playsDirectly: false)
            let root = target.seriesID.map {
                SeriesEpisodeEntry.seriesSeed(from: target, seriesID: $0, sourceAccountID: target.sourceAccountID)
            } ?? target
            if kind == .episode {
                XCTAssertEqual(root.providerID(.tmdb), "123", "The series seed must never adopt the episode's own ID.")
            }
            func mount(_ item: MediaItem, scope: String, verified: Bool = false) {
                fixture.host.rootView = AnyView(DetailMetadataFixture(
                    state: SubjectState(item: item), root: item, style: .compactPortrait,
                    fallback: PlozziOSHeroMetadata.tmdbLogoFallback(for: item),
                    artworkSettings: app.settings.cardStyle.artwork, schedule: "New episode every Friday"
                )
                .environment(\.plozzArtworkArea, .details)
                .environment(\.plozzArtworkProviders, app.metadataProviderSettingsModel.settings)
                .environment(\.plozzArtworkSourceReady, verified)
                .detailHeroLogoVisit(scope: scope, subject: item.stablePresentationID))
            }
            mount(root, scope: app.detailArtworkScopeID)
            let first = try fixture.titleSample(afterScreenUpdates: true)
            XCTAssertGreaterThan(first.red, 245, "\(kind): a warm logo must not wait for live detail")
            XCTAssertTrue(first.hasWhite, "\(kind): a known schedule belongs on the same frame")
            mount(root, scope: "different profile")
            XCTAssertLessThan(try fixture.titleSample(afterScreenUpdates: true).red, 10)
            if kind == .episode {
                var confirmed = root
                confirmed.providerIDs = ["Tmdb": "123"]
                confirmed.productionYear = 2022
                mount(confirmed, scope: app.detailArtworkScopeID, verified: true)
                XCTAssertGreaterThan(try fixture.titleSample(afterScreenUpdates: true).red, 245,
                                     "Verifying the same series must not replay the entrance.")
                var sparse = root
                sparse.providerIDs = [:]
                mount(sparse, scope: app.detailArtworkScopeID)
                XCTAssertGreaterThan(try fixture.titleSample(afterScreenUpdates: true).red, 245,
                                     "An opening episode may know the server's show ID but no external IDs.")
                var different = confirmed
                different.providerIDs = ["Tmdb": "789"]
                mount(different, scope: app.detailArtworkScopeID)
                XCTAssertLessThan(try fixture.titleSample(afterScreenUpdates: true).red, 10,
                                  "A corrected series identity must not replay a conflicting card's logo.")
            }
        }
    }

    func testLateDetailWordmarkFadesUnlessMotionIsReduced() async throws {
        for reduced in [false, true] {
            let fixture = try Fixture()
            defer { fixture.close() }
            let url = try fixture.seedLogo()
            let item = MediaItem(id: UUID().uuidString, title: "Movie title", kind: .movie)
            let lookup = LookupGate()
            defer { lookup.release(nil) }
            fixture.host.rootView = AnyView(
                DetailMetadataFixture(
                    state: SubjectState(item: item), root: item, style: .compactPortrait,
                    fallback: HeroLogoFallback(for: item) { await lookup.resolve() },
                    schedule: "New episode every Friday"
                )
                .environment(\._accessibilityReduceMotion, reduced)
            )
            try await waitUntil { lookup.calls == 1 }
            XCTAssertFalse(try fixture.hasTitleText())
            XCTAssertEqual(try fixture.redSample().intensity, 0)
            lookup.release(url)
            var intensities: [UInt8] = []
            try await waitUntil {
                let frame = try fixture.titleSample()
                intensities.append(frame.red)
                if frame.red < 245 { XCTAssertFalse(frame.hasWhite, "The badge must not precede the logo.") }
                return frame.red > 245 && frame.hasWhite
            }
            XCTAssertEqual(intensities.contains { (10...235).contains($0) }, !reduced,
                           "A late wordmark should fade only with motion enabled: \(intensities)")
        }
    }

    func testDetailWithoutLogoSourcesShowsItsTitle() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let item = MediaItem(id: UUID().uuidString, title: "Movie title", kind: .movie)
        fixture.host.rootView = AnyView(DetailMetadataFixture(state: SubjectState(item: item), root: item))
        try await waitUntil { try fixture.hasTitleText() }
        XCTAssertFalse(try fixture.hasRedLogo())
    }

    func testArtworkPolicyChangesAndRemovedIdentityCannotRetainALogo() {
        let original = MediaItem(
            id: "movie", title: "Movie", kind: .movie, productionYear: 2020,
            providerIDs: ["Tmdb": "123"], sourceAccountID: "server"
        )
        func key(
            _ item: MediaItem, prefersOnlineArtwork: Bool = false,
            providerPolicyIdentity: String = "default"
        ) -> HeroLogoMemo.Key {
            HeroLogoMemo.key(
                for: [], fallback: HeroLogoFallback(for: item) { nil },
                prefersOnlineArtwork: prefersOnlineArtwork,
                providerPolicyIdentity: providerPolicyIdentity
            )
        }
        let baseline = key(original)
        XCTAssertTrue(baseline.canRetainImage(from: baseline))
        XCTAssertFalse(key(original, prefersOnlineArtwork: true).canRetainImage(from: baseline))
        XCTAssertFalse(key(original, providerPolicyIdentity: "changed").canRetainImage(from: baseline))
        var changed = original
        changed.productionYear = 2021
        XCTAssertFalse(key(changed).canRetainImage(from: baseline))
        changed = original
        changed.productionYear = nil
        XCTAssertFalse(key(changed).canRetainImage(from: baseline))
        changed = original
        changed.providerIDs = [:]
        XCTAssertFalse(key(changed).canRetainImage(from: baseline))
        changed = original
        changed.kind = .series
        XCTAssertFalse(key(changed).canRetainImage(from: baseline))
    }

    func testAddedAnimeIdentityCanRetainLogoButCorrectionsCannot() {
        let show = MediaItem(
            id: "show", title: "Show", kind: .series,
            providerIDs: ["Tmdb": "123"], sourceAccountID: "server"
        )
        func key(_ item: MediaItem) -> HeroLogoMemo.Key {
            HeroLogoMemo.key(for: [], fallback: HeroLogoFallback(for: item) { nil })
        }
        var enriched = show
        enriched.providerIDs["AniList"] = "456"
        XCTAssertNotEqual(key(enriched), key(show), "A fresh presentation may use the richer request.")
        XCTAssertTrue(key(enriched).canRetainImage(from: key(show)))
        XCTAssertFalse(key(show).canRetainImage(from: key(enriched)), "Removing an established ID is not enrichment.")
        var corrected = enriched
        corrected.providerIDs["AniList"] = "789"
        XCTAssertFalse(key(corrected).canRetainImage(from: key(enriched)))
        corrected = enriched
        corrected.providerIDs["Tmdb"] = "321"
        XCTAssertFalse(key(corrected).canRetainImage(from: key(show)))
    }

    func testTabletDetailKeepsShowLogoWhenItsPlayEpisodeArrives() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let url = try fixture.seedLogo()
        let show = MediaItem(
            id: "show", title: "Show", kind: .series, logoURL: url,
            allowsTitleBasedMetadataMatching: false, sourceAccountID: "server"
        )
        let state = SubjectState(item: show)
        fixture.host.rootView = AnyView(DetailMetadataFixture(state: state, root: show))
        try await waitUntil { try fixture.hasRedLogo() }
        let episode = MediaItem(
            id: "episode", title: "Episode", kind: .episode,
            parentTitle: show.title, seriesID: show.id,
            allowsTitleBasedMetadataMatching: false, sourceAccountID: "server"
        )
        for item in [episode, show, episode] {
            state.item = item
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertTrue(try fixture.hasRedLogo(), "The show identity must not follow the Play episode.")
        }
    }

    func testVisibleLogoDoesNotResolveAReplacementForAdditiveMetadata() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let url = try fixture.seedLogo()
        let original = MediaItem(id: UUID().uuidString, title: "Movie", kind: .movie, sourceAccountID: "server")
        let state = LookupState(fallback: HeroLogoFallback(for: original) { url })
        fixture.host.rootView = AnyView(LookupFixture(state: state))
        try await waitUntil { try state.resolutions == 1 && fixture.hasRedLogo() }

        var enriched = original
        enriched.productionYear = 2026
        enriched.providerIDs["Tmdb"] = "123"
        let lookup = LookupGate()
        defer { lookup.release(url) }
        state.fallback = HeroLogoFallback(for: enriched) { await lookup.resolve() }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(lookup.calls, 0)
        XCTAssertTrue(try fixture.hasRedLogo(), "Adding identity metadata must not flash the text fallback.")
        XCTAssertEqual(state.resolutions, 1)
    }

    func testEpisodeContextKeepsShowLogoWhenGenresArrive() async throws {
        for style: HeroArtworkStyle in [.landscape, .compactPortrait] {
            let fixture = try Fixture()
            defer { fixture.close() }
            let url = try fixture.seedLogo()
            let show = MediaItem(
                id: UUID().uuidString, title: "Animated show", kind: .series,
                providerIDs: ["Tmdb": "123"], sourceAccountID: "server"
            )
            let episode = MediaItem(
                id: UUID().uuidString, title: "New episode", kind: .episode,
                parentTitle: show.title, seriesID: show.id, sourceAccountID: "server"
            )
            let state = SubjectState(item: episode)
            fixture.host.rootView = AnyView(DetailMetadataFixture(
                state: state, root: show, style: style,
                fallback: HeroLogoFallback(for: show) { url }
            ))
            try await waitUntil { try fixture.hasRedLogo() }

            let enriched = DetailMetadataResolver.applying(
                MetadataEnrichment(genres: .init(value: ["Anime"], source: .tmdb)),
                to: show
            )
            XCTAssertEqual(ContentClassifier.classify(show), .tvShow)
            XCTAssertEqual(ContentClassifier.classify(enriched), .anime)
            let lookup = LookupGate()
            defer { lookup.release(url) }
            fixture.host.rootView = AnyView(DetailMetadataFixture(
                state: state, root: enriched, style: style,
                fallback: HeroLogoFallback(for: enriched) { await lookup.resolve() }
            ))
            try await Task.sleep(for: .milliseconds(150))
            XCTAssertEqual(lookup.calls, 0)
            XCTAssertTrue(try fixture.hasRedLogo(), "Genre enrichment must not remove the same show's visible logo.")
            XCTAssertFalse(try fixture.hasTitleText())
        }
    }

    func testChangedSubjectOrCorrectedIdentityCannotKeepThePreviousLogo() async throws {
        for change in ["item", "account", "provider", "language", "title"] {
            let fixture = try Fixture()
            defer { fixture.close() }
            let url = try fixture.seedLogo()
            let original = MediaItem(
                id: UUID().uuidString, title: "Movie", kind: .movie,
                providerIDs: ["Tmdb": "123"], sourceAccountID: "server"
            )
            let state = LookupState(fallback: HeroLogoFallback(for: original) { url })
            fixture.host.rootView = AnyView(LookupFixture(state: state))
            try await waitUntil { try state.resolutions == 1 && fixture.hasRedLogo() }
            var changed = original
            switch change {
            case "item": changed.id = "different"
            case "account": changed.sourceAccountID = "another-server"
            case "provider": changed.providerIDs["Tmdb"] = "456"
            case "title": changed.title = "Corrected movie"
            default: break
            }
            let lookup = LookupGate()
            defer { lookup.release(nil) }
            state.fallback = HeroLogoFallback(for: changed) { await lookup.resolve() }
            if change == "language" { state.language = "fr" }
            try await waitUntil { lookup.calls == 1 }
            XCTAssertFalse(try fixture.hasRedLogo(), change)
            lookup.release(nil)
        }
    }

    func testCorrectedSubjectWithoutLogoFallsBackToText() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let url = try fixture.seedLogo()
        let original = MediaItem(id: UUID().uuidString, title: "Movie", kind: .movie)
        let state = LookupState(fallback: HeroLogoFallback(for: original) { url })
        fixture.host.rootView = AnyView(LookupFixture(state: state))
        try await waitUntil { try state.resolutions == 1 && fixture.hasRedLogo() }
        var corrected = original
        corrected.id = UUID().uuidString
        let lookup = LookupGate()
        defer { lookup.release(nil) }
        state.fallback = HeroLogoFallback(for: corrected) { await lookup.resolve() }
        try await waitUntil { lookup.calls == 1 }
        lookup.release(nil)
        try await waitUntil { try !fixture.hasRedLogo() }
    }

    private func waitUntil(_ condition: () throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while try !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(try condition())
    }

    @Observable fileprivate final class SubjectState {
        var item: MediaItem
        init(item: MediaItem) { self.item = item }
    }

    @Observable fileprivate final class ArtworkState {
        var item: MediaItem
        var sourceReady: Bool
        init(url: URL?, sourceReady: Bool) {
            item = MediaItem(
                id: UUID().uuidString, title: "", kind: .movie,
                posterURL: url, backdropURL: url, allowsTitleBasedMetadataMatching: false
            )
            self.sourceReady = sourceReady
        }
    }

    @Observable fileprivate final class PlayState {
        var isPlaceholder = true
    }

    private struct HomeEntranceFixture: View {
        let state: PlayState
        @State private var entrance = PlozziOSHomeContentEntrance.initial

        var body: some View {
            PlozziOSHomeScrollView(heroActive: true, mediaOpacity: state.isPlaceholder ? 1 : entrance.opacity) {
                (state.isPlaceholder ? Color.black : Color(.sRGB, red: 1, green: 0, blue: 0)).frame(height: 180)
            } rows: {
                (state.isPlaceholder ? Color.black : Color(.sRGB, red: 0, green: 1, blue: 0)).frame(height: 180)
            }
            .modifier(PlozziOSObserveHomeContent(entrance: $entrance, visibleContent: !state.isPlaceholder))
            .background(.black)
        }
    }

    private struct PlayFixture: View {
        let state: PlayState
        var body: some View {
            Button {} label: {
                PlayResumeButtonLabel(
                    title: state.isPlaceholder ? "Play" : "Resume", progress: nil, remainingText: nil,
                    onLight: true, spacing: 10, capsuleWidth: 60,
                    isPlaceholder: state.isPlaceholder, crossfadesPlaceholder: true
                )
                .foregroundStyle(.red)
                .font(.system(size: 32, weight: .semibold))
                .frame(width: 250, alignment: .leading)
            }
            .buttonStyle(PlozziOSHeroActionButtonStyle(kind: .primary))
            .environment(\.plozzReduceTransparency, true)
            .environment(\.themePalette, .dark)
            .environment(\.colorScheme, .dark)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(.black)
        }
    }

    private struct ArtworkFixture: View {
        let state: ArtworkState
        @State private var app = PlozziOSAppModel(accountStore: AccountStore(secureStore: InMemorySecureStore()))
        @State private var trailers = HeroTrailerController()
        @State private var sidebar = PlozziOSSidebarGeometryModel()

        var body: some View {
            PlozziOSHeroStage(
                item: state.item,
                presentation: HeroPresentation(item: state.item, artworkStyle: .compactPortrait, surface: .detail),
                style: .compactPortrait, surfaceRole: .detail, isActive: false, showsScrim: false,
                trailerController: trailers, backgroundSettings: app.settings.heroBackground,
                trailerResolver: { _ in nil }
            ) { EmptyView() }
            .environment(sidebar)
            .environment(\.plozzArtworkSourceReady, state.sourceReady)
            .environment(\.plozzArtworkArea, .details)
            .environment(\.plozzArtworkSettings, ArtworkSettings(preference: .library))
            .environment(\.horizontalSizeClass, .compact)
            .environment(\.plozziOSHeroContainerHeight, 844)
            .environment(\.themePalette, .dark)
            .environment(\.colorScheme, .dark)
            .frame(width: 390, height: 844, alignment: .top)
            .background(.black)
        }
    }

    private struct DetailMetadataFixture: View {
        let state: SubjectState
        let root: MediaItem
        var style: HeroArtworkStyle = .landscape
        var fallback: HeroLogoFallback? = nil
        var artworkSettings = ArtworkSettings(preference: .library)
        var schedule: LocalizedStringResource? = nil
        var body: some View {
            PlozziOSHeroMetadata(
                presentation: HeroPresentation(item: state.item, artworkStyle: style, surface: .detail),
                style: style, mode: .detail,
                fallbackPresentation: HeroPresentation(item: root, artworkStyle: style, surface: .detail),
                scheduleLine: schedule, logoFallback: fallback,
                content: .identity
            )
            .environment(\.themePalette, .dark)
            .environment(\.plozzArtworkSettings, artworkSettings)
            .frame(width: 400, height: 250)
            .background(.black)
        }
    }

    @Observable fileprivate final class LookupState {
        var fallback: HeroLogoFallback
        var language = "en"
        var resolutions = 0
        init(fallback: HeroLogoFallback) { self.fallback = fallback }
    }

    private struct LookupFixture: View {
        let state: LookupState
        var body: some View {
            HeroLogoArtwork(
                references: [], asyncFallbackURL: state.fallback,
                maxWidth: 300, maxHeight: 100, constrainsToBounds: true,
                onResolve: { _ in state.resolutions += 1 }
            ) {
                Text("Text fallback").foregroundStyle(.white)
            }
            .environment(\.locale, Locale(identifier: state.language))
            .frame(width: 400, height: 250)
            .background(.black)
        }
    }

    @MainActor private final class LookupGate {
        var calls = 0
        private var continuation: CheckedContinuation<URL?, Never>?
        func resolve() async -> URL? {
            calls += 1
            return await withCheckedContinuation { continuation = $0 }
        }
        func release(_ url: URL?) {
            continuation?.resume(returning: url)
            continuation = nil
        }
    }

    private final class AppearanceHost: UIHostingController<AnyView> {
        var hasAppeared = false

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            hasAppeared = false
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            hasAppeared = true
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            hasAppeared = false
        }
    }

    private final class Fixture {
        let window: UIWindow
        let host = AppearanceHost(rootView: AnyView(EmptyView()))
        private(set) var navigation: UINavigationController?
        let previous: UIWindow?
        private var urls: [URL] = []

        init(
            defersAppearance: Bool = false,
            navigates: Bool = false,
            size: CGSize = CGSize(width: 400, height: 250)
        ) throws {
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            previous = scene.windows.first(where: \.isKeyWindow)
            window = UIWindow(windowScene: scene)
            window.frame = CGRect(origin: .zero, size: size)
            host.safeAreaRegions = []
            if navigates {
                let navigation = UINavigationController(rootViewController: AppearanceHost(rootView: AnyView(Color.black)))
                navigation.setNavigationBarHidden(true, animated: false)
                self.navigation = navigation
                window.rootViewController = navigation
            } else if defersAppearance {
                let container = AppearanceContainer()
                container.addChild(host)
                container.view.addSubview(host.view)
                host.view.frame = window.bounds
                host.didMove(toParent: container)
                window.rootViewController = container
            } else {
                window.rootViewController = host
            }
            window.makeKeyAndVisible()
        }

        func seedLogo() throws -> URL {
            let url = try XCTUnwrap(URL(string: "https://logo-continuity.invalid/\(UUID()).png"))
            let image = UIGraphicsImageRenderer(size: CGSize(width: 220, height: 80)).image {
                UIColor.red.setFill()
                $0.fill(CGRect(x: 10, y: 10, width: 200, height: 60))
            }
            let response = try XCTUnwrap(HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "image/png", "Cache-Control": "max-age=3600"]
            ))
            let cache = try XCTUnwrap(ArtworkSession.shared.configuration.urlCache)
            cache.storeCachedResponse(
                CachedURLResponse(response: response, data: try XCTUnwrap(image.pngData())),
                for: URLRequest(url: url)
            )
            urls.append(url)
            return url
        }

        func seedArtwork() throws -> URL {
            let url = try XCTUnwrap(URL(string: "https://artwork-continuity.invalid/\(UUID()).png"))
            let image = UIGraphicsImageRenderer(size: CGSize(width: 320, height: 480)).image {
                UIColor.green.setFill()
                $0.fill(CGRect(x: 0, y: 0, width: 320, height: 480))
            }
            let response = try XCTUnwrap(HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "image/png", "Cache-Control": "max-age=3600"]
            ))
            let cache = try XCTUnwrap(ArtworkSession.shared.configuration.urlCache)
            cache.storeCachedResponse(
                CachedURLResponse(response: response, data: try XCTUnwrap(image.pngData())),
                for: URLRequest(url: url)
            )
            urls.append(url)
            return url
        }

        func artworkSample(afterScreenUpdates: Bool = false) throws -> (image: UIImage, values: [Double]) {
            let sample = try pixels(afterScreenUpdates: afterScreenUpdates)
            let width = Int(window.bounds.width)
            let values = [18, 100, 22, 24, 26, 568, 570, 574, 620].map { y in
                Double(sample.bytes[(y * width + width / 2) * 4 + 1])
            }
            return (sample.image, values)
        }

        func homeMediaSample() throws -> (Double, Double) {
            let sample = try pixels()
            let width = Int(window.bounds.width)
            return (Double(sample.bytes[(90 * width + width / 2) * 4]),
                    Double(sample.bytes[(290 * width + width / 2) * 4 + 1]))
        }

        func playTextIntensity() throws -> Double {
            let sample = try pixels()
            let width = Int(window.bounds.width)
            return (12..<60).flatMap { y in
                (70..<120).map { x in
                    let index = (y * width + x) * 4
                    return Double(sample.bytes[index]) - Double(min(
                        sample.bytes[index + 1], sample.bytes[index + 2]
                    ))
                }
            }.max() ?? 0
        }

        func hasRedLogo() throws -> Bool {
            try hasVisiblePixels { $0 > 180 && $1 < 70 && $2 < 70 }
        }

        func hasGreenArtwork() throws -> Bool {
            try hasVisiblePixels { $0 < 70 && $1 > 180 && $2 < 70 }
        }

        func hasTitleText() throws -> Bool {
            try hasVisiblePixels { $0 > 180 && $1 > 180 && $2 > 180 }
        }

        func redSample(afterScreenUpdates: Bool = false) throws -> (image: UIImage, intensity: UInt8) {
            let sample = try pixels(afterScreenUpdates: afterScreenUpdates)
            let intensity = stride(from: 0, to: sample.bytes.count, by: 4)
                .filter { sample.bytes[$0 + 1] < 15 && sample.bytes[$0 + 2] < 15 }
                .map { sample.bytes[$0] }
                .max() ?? 0
            return (sample.image, intensity)
        }

        func titleSample(afterScreenUpdates: Bool = false) throws -> (red: UInt8, hasWhite: Bool) {
            let bytes = try pixels(afterScreenUpdates: afterScreenUpdates).bytes
            var red: UInt8 = 0
            var white = 0
            for i in stride(from: 0, to: bytes.count, by: 4) {
                if bytes[i + 1] < 15 && bytes[i + 2] < 15 { red = max(red, bytes[i]) }
                if min(bytes[i], bytes[i + 1], bytes[i + 2]) > 180 { white += 1 }
            }
            return (red, white > 100)
        }

        private func hasVisiblePixels(_ matches: (UInt8, UInt8, UInt8) -> Bool) throws -> Bool {
            let bytes = try pixels().bytes
            return stride(from: 0, to: bytes.count, by: 4).filter {
                matches(bytes[$0], bytes[$0 + 1], bytes[$0 + 2])
            }.count > 300
        }

        private func pixels(afterScreenUpdates: Bool = false) throws -> (image: UIImage, bytes: [UInt8]) {
            window.layoutIfNeeded()
            let surface: UIView = navigation == nil ? window : host.view
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let image = UIGraphicsImageRenderer(bounds: surface.bounds, format: format).image { _ in
                surface.drawHierarchy(in: surface.bounds, afterScreenUpdates: afterScreenUpdates)
            }
            let cgImage = try XCTUnwrap(image.cgImage)
            var bytes = [UInt8](repeating: 0, count: cgImage.width * cgImage.height * 4)
            try bytes.withUnsafeMutableBytes {
                let context = try XCTUnwrap(CGContext(
                    data: $0.baseAddress, width: cgImage.width, height: cgImage.height,
                    bitsPerComponent: 8, bytesPerRow: cgImage.width * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                ))
                context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
            }
            return (image, bytes)
        }

        func close() {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
            for url in urls {
                ArtworkSession.shared.configuration.urlCache?.removeCachedResponse(for: URLRequest(url: url))
            }
        }
    }

    private final class AppearanceContainer: UIViewController {
        override var shouldAutomaticallyForwardAppearanceMethods: Bool { false }
    }
}
