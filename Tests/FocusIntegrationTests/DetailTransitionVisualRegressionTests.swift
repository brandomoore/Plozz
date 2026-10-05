import AVFoundation
import CoreModels
@testable import CoreUI
@testable import FeatureHome
import FeatureHomeCore
import MetadataKit
import Observation
import SwiftUI
import UIKit
import XCTest

@MainActor
final class DetailTransitionVisualRegressionTests: XCTestCase {
    func testProductionMovieAndSeriesTintTheirInformationBackgroundFromArtwork() async throws {
        func backgrounds(in view: UIView) -> [NativeGradientCardFill.View] {
            (view as? NativeGradientCardFill.View).map { [$0] } ?? view.subviews.flatMap { backgrounds(in: $0) }
        }
        let scene = try await activeScene()
        for kind in [MediaItemKind.movie, .series] {
            let artwork = try await seedArtwork(color: kind == .movie ? .red : .blue)
            var provider = TransitionShowProvider(artwork: artwork)
            var item = provider.show
            item.kind = kind
            item.genres = ["Drama"]
            item.productionYear = 2020
            provider.detailItem = item
            let model = TransitionShowModel(provider: provider)
            let host = TransitionShowController(rootView: TransitionShowRoot(model: model))
            let previous = scene.windows.first(where: \.isKeyWindow)
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
            window.backgroundColor = UIColor(ThemePalette.dark.backgroundBase)
            window.rootViewController = host
            window.makeKeyAndVisible()
            defer {
                model.trailer.stop()
                window.isHidden = true
                window.rootViewController = nil
                previous?.makeKeyAndVisible()
            }
            model.path.append(1)
            try await waitUntil { model.detail.state.value?.childrenLoaded == true }
            try await Task.sleep(for: .seconds(2))
            try await focusLowestDetailControl(in: window, host: host)
            for phase in ["initial", "disabled", "reenabled", "uncovered"] {
                if phase == "uncovered" {
                    model.stackDepth.pageAppeared(model.coveredPageID)
                    try await Task.sleep(for: .milliseconds(300))
                    model.stackDepth.pageDismissed(model.coveredPageID)
                }
                let enabled = phase != "disabled"
                model.gradientEnabled = enabled
                try await Task.sleep(for: .seconds(1))
                let image = DetailTransitionSnapshot.image(of: window)
                let sample = try XCTUnwrap(image.cgImage?.cropping(to:
                    CGRect(x: 1900, y: 1000, width: 1, height: 1)))
                var bytes = [UInt8](repeating: 0, count: 4)
                try bytes.withUnsafeMutableBytes {
                    let context = try XCTUnwrap(CGContext(
                        data: $0.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    ))
                    context.draw(sample, in: CGRect(x: 0, y: 0, width: 1, height: 1))
                }
                let attachment = XCTAttachment(image: image)
                attachment.name = "production-detail-gradient-\(kind)-\(phase)"
                attachment.lifetime = .keepAlways
                add(attachment)
                if enabled {
                    let fills = backgrounds(in: window).filter {
                        $0.convert($0.bounds, to: window).intersects(window.bounds) && !$0.bounds.isEmpty
                    }
                    XCTAssertFalse(fills.isEmpty)
                    XCTAssertTrue(fills.allSatisfy { !$0.isHidden && $0.layer.contents != nil },
                                  "Production detail cards must paint the shared gradient, not the flat fallback.")
                    let tintDifference = Int(bytes[0]) - Int(bytes[2])
                    XCTAssertGreaterThan(kind == .movie ? tintDifference : -tintDifference, 8,
                                         "\(kind) must tint the information-band gutter, not just its hero image: \(bytes)")
                } else {
                    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                    XCTAssertTrue(UIColor(ThemePalette.dark.informationSurface).getRed(&r, green: &g, blue: &b, alpha: &a))
                    for (actual, expected) in zip(bytes, [r, g, b, a]) {
                        XCTAssertLessThanOrEqual(abs(Int(actual) - Int((expected * 255).rounded())), 2)
                    }
                }
            }
        }
    }

    func testProductionDetailStopsTrailerAfterReturningToNonHeroRoot() async throws {
        try await withTrailerFixture { model, video in
            model.path.append(1)
            try await waitUntil { model.detail.state.value?.childrenLoaded == true }
            try await Task.sleep(for: .milliseconds(500))
            model.trailer.play(itemID: model.provider.show.id, resolvedURL: video, muted: false)
            try await waitUntil { model.trailer.isPlaying && model.trailer.player.rate == 1 }
            model.path.removeAll()
            try await Task.sleep(for: .seconds(1))
            XCTAssertNil(model.trailer.currentItemID, "A library/Watchlist root has no hero to receive the trailer.")
            XCTAssertNil(model.trailer.player.currentItem)
            XCTAssertEqual(model.trailer.player.rate, 0)
        }
    }

    func testProductionDetailPreservesSamePlayerOnlyForMatchingHomeReturn() async throws {
        try await withTrailerFixture { model, video in
            model.path.append(1)
            try await waitUntil { model.detail.state.value?.childrenLoaded == true }
            try await Task.sleep(for: .milliseconds(500))
            model.trailer.play(itemID: model.provider.show.id, resolvedURL: video, muted: false)
            try await waitUntil { model.trailer.isPlaying && model.trailer.player.rate == 1 }
            let original = try XCTUnwrap(model.trailer.player.currentItem)
            // Change eligibility after the detail was constructed.
            model.trailerReturnItemID = model.provider.show.id
            model.path.removeAll()
            try await Task.sleep(for: .seconds(1))
            XCTAssertTrue(model.trailer.player.currentItem === original)
            XCTAssertEqual(model.trailer.currentItemID, model.provider.show.id)
            XCTAssertEqual(model.trailer.player.rate, 1)
        }
    }

    func testProductionDetailRejectsLateTrailerAfterExitOrCover() async throws {
        for cover in [false, true] {
            try await withTrailerFixture { model, video in
                let pending = PendingDetailTrailer()
                defer { pending.complete(nil) }
                model.background.settings.detailMode = .trailer
                model.resolveTrailer = { _ in await pending.resolve() }
                model.path.append(1)
                try await waitUntil { pending.started }
                if cover {
                    model.path.append(2)
                    try await waitUntil { model.stackDepth.depth == 2 }
                } else {
                    model.path.removeAll()
                    try await waitUntil { model.stackDepth.depth == 0 }
                }
                pending.complete(HeroTrailerSource(
                    ownerItemID: model.provider.show.id, trailerItemID: "local-trailer",
                    url: video, duration: 30
                ))
                try await Task.sleep(for: .milliseconds(500))
                XCTAssertNil(model.trailer.currentItemID, "Late resolution must not play behind another page.")
                XCTAssertNil(model.trailer.player.currentItem)
            }
        }
    }

    func testProductionDetailCleanupDoesNotDiscardNewerPendingTrailer() async throws {
        try await withTrailerFixture { model, video in
            model.path.append(1)
            try await waitUntil { model.detail.state.value?.childrenLoaded == true }
            try await Task.sleep(for: .milliseconds(500))
            model.trailer.prepare(itemID: "new-title", resolvedURL: video, muted: false)
            let replacement = try XCTUnwrap(model.trailer.player.currentItem)
            XCTAssertEqual(model.trailer.currentItemID, "new-title")
            XCTAssertFalse(model.trailer.isPlaying)
            model.path.removeAll()
            try await Task.sleep(for: .seconds(1))
            XCTAssertTrue(model.trailer.player.currentItem === replacement)
            XCTAssertEqual(model.trailer.currentItemID, "new-title")
            XCTAssertFalse(model.trailer.isPlaying, "Departure must neither discard nor start the replacement.")
        }
    }

    func testHomeTrailerReturnEligibilityTracksActualHeroVisibility() async throws {
        let scene = try await activeScene()
        let model = TransitionShowModel(provider: TransitionShowProvider(artwork: try await seedArtwork()))
        model.background.settings.homeTrailerEnabled = true
        let host = UIHostingController(rootView: TrailerReturnHomeRoot(model: model))
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            model.trailer.stop()
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        try await waitUntil { model.trailerReturnItemID == model.provider.show.id }
        model.path.append(1)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(model.trailerReturnItemID, model.provider.show.id, "Covering Home retains the return receiver.")
        model.homeRecede.isReceded = true
        try await waitUntil { model.trailerReturnItemID == nil }
        model.homeRecede.isReceded = false
        try await waitUntil { model.trailerReturnItemID == model.provider.show.id }
        model.background.settings.homeTrailerEnabled = false
        try await waitUntil { model.trailerReturnItemID == nil }
        model.background.settings.homeTrailerEnabled = true
        try await waitUntil { model.trailerReturnItemID == model.provider.show.id }
        model.showsHomeHero = false
        try await waitUntil { model.trailerReturnItemID == nil }
    }

    private func withTrailerFixture(
        _ run: (TransitionShowModel, URL) async throws -> Void
    ) async throws {
        let scene = try await activeScene()
        let provider = TransitionShowProvider(artwork: try await seedArtwork())
        let model = TransitionShowModel(provider: provider)
        let host = UIHostingController(rootView: TransitionShowRoot(model: model))
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            model.trailer.stop()
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        let video = try await makeTrailerVideo()
        try await run(model, video)
    }

    func testThumbnailIsGoneBeforeLandingWhileDestinationArtworkExpands() async throws {
        let scene = try await activeScene()
        let fixture = FocusReturnFixture(scene: scene)
        defer { fixture.close() }
        let session = TVDetailEntranceSession()
        defer { session.finishImmediately() }
        fixture.source.prepare(for: fixture.item)
        fixture.controller.view.backgroundColor = .blue
        let backdrop = UIGraphicsImageRenderer(size: CGSize(width: 320, height: 180)).image {
            UIColor.blue.setFill()
            $0.fill(CGRect(x: 0, y: 0, width: 320, height: 180))
        }
        session.resolvedDestinationArtwork(backdrop)
        session.attach(to: fixture.window, enabled: true)
        let overlay = try XCTUnwrap(fixture.window.subviews.compactMap { $0 as? DetailTransitionOverlay }.first)
        try await Task.sleep(for: .milliseconds(250))
        let frame = try XCTUnwrap(overlay.cardContainer.layer.presentation()?.frame)
        XCTAssertGreaterThan(frame.width, 300)
        XCTAssertLessThan(frame.width, fixture.window.bounds.width - 20)
        XCTAssertLessThan(overlay.card.layer.presentation()?.opacity ?? 1, 0.05)
        XCTAssertGreaterThan(overlay.destination.layer.presentation()?.opacity ?? 0, 0.8)
        XCTAssertTrue(overlay.destination.image === backdrop)
        try await waitUntil { overlay.superview == nil }
        XCTAssertEqual(session.stage, .logo)
    }

    func testReturnMatchesFocusedArtworkFrameAndContinuousScaledCorners() async throws {
        let scene = try await activeScene()
        let fixture = FocusReturnFixture(scene: scene)
        defer { fixture.close() }
        let system = try XCTUnwrap(UIFocusSystem.focusSystem(for: fixture.window))
        fixture.controller.prefersCard = true
        system.requestFocusUpdate(to: fixture.controller)
        system.updateFocusIfNeeded()
        try await waitUntil { fixture.controller.card.isFocused }
        fixture.source.prepare(for: fixture.item)
        let session = TVDetailEntranceSession()
        defer { session.finishImmediately() }
        fixture.controller.prefersCard = false
        system.requestFocusUpdate(to: fixture.controller)
        system.updateFocusIfNeeded()
        try await waitUntil { !fixture.controller.card.isFocused }
        session.attach(to: fixture.window, enabled: true)
        try await waitUntil { session.stage == .complete }
        session.close { fixture.controller.prefersCard = true }
        let overlay = try XCTUnwrap(fixture.window.subviews.compactMap { $0 as? DetailTransitionOverlay }.first)
        try await waitUntil { overlay.cardContainer.frame.width < fixture.window.bounds.width - 20 }
        let target = overlay.cardContainer.frame
        let radius = overlay.cardContainer.layer.cornerRadius
        XCTAssertEqual(overlay.cardContainer.layer.cornerCurve, .continuous)
        try await waitUntil { overlay.superview == nil && fixture.controller.card.isFocused }
        let current = try XCTUnwrap(fixture.source.geometry(in: fixture.window))
        XCTAssertEqual(target.minX, current.frame.minX, accuracy: 0.5)
        XCTAssertEqual(target.minY, current.frame.minY, accuracy: 0.5)
        XCTAssertEqual(target.width, current.frame.width, accuracy: 0.5)
        XCTAssertEqual(target.height, current.frame.height, accuracy: 0.5)
        XCTAssertEqual(radius, current.cornerRadius, accuracy: 0.5)
        XCTAssertGreaterThan(radius, fixture.source.cornerRadius)
    }

    func testProductionShowDoesNotScrollIntoEpisodesWhileTheHeroEnters() async throws {
        let settingsStore = MetadataProviderSettingsStore()
        let originalSettings = settingsStore.load()
        var settings = originalSettings
        settings.preferOnlineArtwork = false
        settingsStore.save(settings)
        defer { settingsStore.save(originalSettings) }
        let scene = try await activeScene()
        let artwork = try await seedArtwork()
        let provider = TransitionShowProvider(artwork: artwork)
        let model = TransitionShowModel(provider: provider)
        let host = UIHostingController(rootView: TransitionShowRoot(model: model))
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        try await Task.sleep(for: .milliseconds(300))
        DetailTransitionNavigation.prepare(for: provider.show, in: window, source: nil)
        let cover = try XCTUnwrap(window.subviews.compactMap { $0 as? DetailTransitionOverlay }.first)
        model.path.append(1)
        try await waitUntil {
            model.detail.state.value?.childrenLoaded == true && self.verticalScroll(in: host.view) != nil
        }
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertNotNil(cover.destination.image, "Use the actual backdrop resolved by the production hero.")
        let scroll = try XCTUnwrap(verticalScroll(in: host.view))
        XCTAssertEqual(scroll.contentOffset.y + scroll.adjustedContentInset.top, 0, accuracy: 2,
                       "The artwork pause must not move into the episode browser.")
        try await Task.sleep(for: .milliseconds(1400))
        XCTAssertEqual(scroll.contentOffset.y + scroll.adjustedContentInset.top, 0, accuracy: 2,
                       "A whole-show open must stay on its hero when controls finish appearing.")
        let shot = XCTAttachment(image: DetailTransitionSnapshot.image(of: window))
        shot.name = "production-series-entrance"
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testProductionEpisodeBrowserKeepsItsPageAndLogoBelowTheTopEdge() async throws {
        let settingsStore = MetadataProviderSettingsStore()
        let original = settingsStore.load()
        var settings = original
        settings.preferOnlineArtwork = false
        settingsStore.save(settings)
        defer { settingsStore.save(original) }
        let scene = try await activeScene()
        let artwork = try await seedArtwork(color: .blue)
        let logo = try await seedArtwork(color: .red, size: CGSize(width: 500, height: 200), padding: 10)
        let configurations = CardFocusStyle.allCases.map {
            (style: $0, directEntry: false)
        } + [
            (style: .system, directEntry: true)
        ]
        for configuration in configurations {
            let style = configuration.style
            let scenario = "\(style)-direct-\(configuration.directEntry)"
            let provider = TransitionShowProvider(artwork: artwork, logo: logo, episodeCount: 12)
            let model = TransitionShowModel(provider: provider)
            let host = TransitionShowController(rootView: TransitionShowRoot(
                model: model, focusStyle: style, directEntry: configuration.directEntry
            ))
            let previous = scene.windows.first(where: \.isKeyWindow)
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
            window.rootViewController = host
            window.makeKeyAndVisible()
            defer {
                model.detail.suspendEnrichment()
                window.isHidden = true
                window.rootViewController = nil
                previous?.makeKeyAndVisible()
            }
            host.view.layoutIfNeeded()
            DetailTransitionNavigation.prepare(
                for: configuration.directEntry ? provider.episode : provider.show, in: window, source: nil
            )
            model.path.append(1)
            try await waitUntil {
                model.detail.seasonEpisodes["season"]?.count == 12
                    && self.episodeScroll(in: host.view) != nil
            }
            try await Task.sleep(for: .seconds(3))
            let page = try XCTUnwrap(verticalScroll(in: host.view))
            let episodeRail = try XCTUnwrap(episodeScroll(in: page))
            let system = try XCTUnwrap(UIFocusSystem.focusSystem(for: window))
            let entryTarget = try XCTUnwrap(episodeFocusTarget(in: page))
            host.target = entryTarget
            system.requestFocusUpdate(to: host)
            system.updateFocusIfNeeded()
            try await waitUntil {
                system.focusedItem.map(ObjectIdentifier.init) == ObjectIdentifier(entryTarget)
            }
            host.target = nil
            var offsets: [CGFloat] = []
            var measurements: [String] = []
            var browsedDuringReveal = false
            var nextEpisode: (any UIFocusItem)?
            var focusedNextEpisode = false
            var completedRailPositions: [CGFloat] = []
            let started = CACurrentMediaTime()
            let deadline = ContinuousClock.now + .seconds(3)
            while ContinuousClock.now < deadline {
                if !browsedDuringReveal, offsets.count >= 3,
                   let next = episodeFocusTargets(in: page).first(where: {
                       ObjectIdentifier($0) != system.focusedItem.map(ObjectIdentifier.init)
                   }) {
                    host.target = next
                    system.requestFocusUpdate(to: host)
                    system.updateFocusIfNeeded()
                    host.target = nil
                    nextEpisode = next
                    browsedDuringReveal = true
                }
                if let nextEpisode, let focused = system.focusedItem {
                    focusedNextEpisode = focusedNextEpisode
                        || ObjectIdentifier(nextEpisode) == ObjectIdentifier(focused)
                }
                let offset = page.contentOffset.y + page.adjustedContentInset.top
                offsets.append(offset)
                let railLayer = episodeRail.layer.presentation() ?? episodeRail.layer
                let presented = railLayer.convert(railLayer.bounds, to: window.layer.presentation() ?? window.layer)
                if page.isScrollEnabled { completedRailPositions.append(presented.minY) }
                measurements.append("t=\(CACurrentMediaTime() - started), offset=\(offset), railY=\(presented.minY), enabled=\(page.isScrollEnabled), height=\(page.contentSize.height)")
                try await Task.sleep(for: .milliseconds(25))
            }
            let shot = XCTAttachment(image: DetailTransitionSnapshot.image(of: window))
            shot.name = "production-episode-browser-\(scenario)"
            shot.lifetime = .keepAlways
            add(shot)
            let trace = XCTAttachment(string: measurements.joined(separator: "\n"))
            trace.name = "production-episode-browser-offsets-\(scenario)"
            trace.lifetime = .keepAlways
            add(trace)
            XCTAssertTrue(browsedDuringReveal)
            XCTAssertTrue(focusedNextEpisode, "Horizontal browsing must remain available during the reveal.")
            XCTAssertTrue(page.isScrollEnabled, "Lower detail sections must remain scrollable after the reveal.")
            let settledY = try XCTUnwrap(completedRailPositions.last)
            XCTAssertLessThanOrEqual(completedRailPositions.map { abs($0 - settledY) }.max() ?? .infinity, 1,
                                     "The browser must be visually settled when its animation completes, without a second upward drift.")
            XCTAssertLessThanOrEqual(offsets.map(abs).max() ?? .infinity, 1,
                                     "The page must not scroll when lower details mount after episode entry: \(style).")
            let bounds = try redArtworkBounds(in: window)
            XCTAssertGreaterThanOrEqual(bounds.minY, 71, "The compact logo must retain its 72pt top clearance.")
            XCTAssertLessThanOrEqual(bounds.maxY, 273, "The compact logo must remain above Seasons.")

            let seasonSnapshot = renderedKeylineSnapshot(in: window)
            let seasonAligned = XCTAttachment(image: seasonSnapshot)
            seasonAligned.name = "production-season-keylines-\(scenario)"
            seasonAligned.lifetime = .keepAlways
            add(seasonAligned)
            let seasonEdge = try leadingSurfacePixel(
                in: seasonSnapshot, region: CGRect(x: 60, y: 310, width: 240, height: 10)
            )
            let seasonAboutEdge = try leadingPixel(
                in: seasonSnapshot, region: CGRect(x: 0, y: 975, width: 300, height: 60)
            ) { r, g, b in r > 230 && g > 230 && b > 230 }
            let season = try XCTUnwrap(focusTargets(in: page).first {
                (100...250).contains($0.frame.width) && (40...90).contains($0.frame.height)
            })
            host.target = season
            system.requestFocusUpdate(to: host)
            system.updateFocusIfNeeded()
            try await waitUntil {
                system.focusedItem.map(ObjectIdentifier.init) == ObjectIdentifier(season)
                    && host.settledFocusItemID == ObjectIdentifier(season)
            }
            host.target = nil
            let rail = try XCTUnwrap(episodeScroll(in: page))
            rail.setContentOffset(CGPoint(x: -rail.adjustedContentInset.left, y: rail.contentOffset.y), animated: false)
            window.layoutIfNeeded()
            let restingSnapshot = try await restingEpisodeSnapshot(in: window)
            let episodeEdge = try episodeArtworkSpan(in: restingSnapshot).lowerBound
            let aboutEdge = try leadingPixel(
                in: restingSnapshot, region: CGRect(x: 0, y: 975, width: 300, height: 60)
            ) { r, g, b in r > 230 && g > 230 && b > 230 }
            XCTAssertEqual(episodeEdge, aboutEdge, accuracy: 1,
                           "\(scenario): resting episode artwork and About must share the same leading keyline.")
            XCTAssertEqual(seasonEdge, seasonAboutEdge, accuracy: 1,
                           "\(scenario): the season pill's outer edge, not its label, must align with About.")
            let aligned = XCTAttachment(image: restingSnapshot)
            aligned.name = "production-series-keylines-\(scenario)"
            aligned.lifetime = .keepAlways
            add(aligned)
        }
    }

    func testBrowserScrollGuardRestoresItsOwnerWithoutDisablingNestedRails() async throws {
        let scene = try await activeScene()
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let host = UIViewController()
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        let page = UIScrollView(frame: window.bounds)
        let rail = UIScrollView(frame: CGRect(x: 0, y: 0, width: 500, height: 300))
        let guardView = SeriesBrowserRevealScrollGuard.GuardView()
        host.view.addSubview(page)
        page.addSubview(rail)
        page.addSubview(guardView)
        guardView.isActive = true
        guardView.apply()
        XCTAssertFalse(page.isScrollEnabled)
        XCTAssertTrue(rail.isScrollEnabled)
        guardView.isActive = false
        guardView.apply()
        XCTAssertTrue(page.isScrollEnabled)
        guardView.isActive = true
        guardView.apply()
        guardView.removeFromSuperview()
        XCTAssertTrue(page.isScrollEnabled, "A page removed during the reveal must release its scroll guard.")
        page.isScrollEnabled = false
        page.addSubview(guardView)
        guardView.isActive = false
        guardView.apply()
        XCTAssertFalse(page.isScrollEnabled, "An existing entrance gate must not be enabled by the browser guard.")
    }

    private func episodeScroll(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView,
           scroll.contentSize.width > scroll.bounds.width + 1, scroll.bounds.height > 200 {
            return scroll
        }
        return view.subviews.lazy.compactMap { self.episodeScroll(in: $0) }.first
    }

    private func episodeFocusTarget(in view: UIView) -> (any UIFocusItem)? {
        episodeFocusTargets(in: view).first
    }

    private func episodeFocusTargets(in view: UIView) -> [any UIFocusItem] {
        focusTargets(in: view).filter {
            (300...700).contains($0.frame.width) && (200...600).contains($0.frame.height)
        }
    }

    private func focusTargets(in view: UIView) -> [any UIFocusItem] {
        var containers: [any UIFocusItemContainer] = [view]
        var seen = Set<ObjectIdentifier>()
        var result: [any UIFocusItem] = []
        while let container = containers.popLast() {
            guard seen.insert(ObjectIdentifier(container)).inserted else { continue }
            let frame = container.coordinateSpace.convert(view.bounds, from: view)
            for item in container.focusItems(in: frame) {
                if let children = item.focusItemContainer { containers.append(children) }
                if let child = item as? UIView { containers.append(child) }
                if item.canBecomeFocused, !(item is UIScrollView),
                   !String(describing: type(of: item)).contains("Filler") {
                    result.append(item)
                }
            }
        }
        return result
    }

    private func renderedKeylineSnapshot(in window: UIWindow) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
    }

    private func restingEpisodeSnapshot(in window: UIWindow) async throws -> UIImage {
        let deadline = ContinuousClock.now + .seconds(3)
        var previous: ClosedRange<CGFloat>?
        var stableSamples = 0
        while ContinuousClock.now < deadline {
            let snapshot = renderedKeylineSnapshot(in: window)
            let range = try episodeArtworkSpan(in: snapshot)
            let width = range.upperBound - range.lowerBound + 1
            // Native/custom focus paint outlives the focus callback. Check its
            // resting width, not its x-position, so a misaligned card still fails.
            let restingWidth = EpisodeColumnCard.artworkSize.width
            if (restingWidth - 2...restingWidth).contains(width), range == previous {
                stableSamples += 1
                if stableSamples == 2 { return snapshot }
            } else {
                stableSamples = 0
            }
            previous = range
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("Episode focus paint did not return to its resting width: \(String(describing: previous)).")
        throw AppError.notFound
    }

    private func leadingSurfacePixel(
        in snapshot: UIImage, region: CGRect,
        file: StaticString = #filePath, line: UInt = #line
    ) throws -> CGFloat {
        let reference = try XCTUnwrap(snapshot.cgImage?.cropping(to: CGRect(
            x: region.minX, y: region.midY, width: 1, height: 1
        )))
        var background = [UInt8](repeating: 0, count: 4)
        try background.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(
                data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(reference, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        // The native pill picks up the artwork gradient. Its painted edge is
        // lighter than the adjacent backdrop, but no longer necessarily gray.
        return try leadingPixel(in: snapshot, region: region, file: file, line: line) { r, g, b in
            Int(r) >= Int(background[0]) + 5
                && Int(g) >= Int(background[1]) + 5
                && Int(b) >= Int(background[2]) + 5
        }
    }

    func testSurfaceKeylineSamplingRetainsMisalignmentOnNeutralAndColoredBackdrops() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        for background in [[CGFloat(0), 0, 0], [14, 14, 16], [27, 27, 66]] {
            for offset in [CGFloat.zero, 4] {
                let snapshot = UIGraphicsImageRenderer(size: CGSize(width: 640, height: 1080), format: format).image { context in
                    UIColor(red: background[0] / 255, green: background[1] / 255, blue: background[2] / 255, alpha: 1).setFill()
                    context.fill(CGRect(x: 0, y: 0, width: 640, height: 1080))
                    UIColor(red: (background[0] + 10) / 255, green: (background[1] + 10) / 255,
                            blue: (background[2] + 10) / 255, alpha: 1).setFill()
                    context.fill(CGRect(x: 80 + offset, y: 300, width: 160, height: 40))
                }
                let edge = try leadingSurfacePixel(
                    in: snapshot, region: CGRect(x: 60, y: 310, width: 240, height: 10)
                )
                XCTAssertEqual(edge, 80 + offset, accuracy: 1)
            }
        }
    }

    private func leadingPixel(
        in snapshot: UIImage, region: CGRect,
        file: StaticString = #filePath, line: UInt = #line,
        matching: (UInt8, UInt8, UInt8) -> Bool
    ) throws -> CGFloat {
        try XCTUnwrap(
            horizontalPixelSpans(in: snapshot, region: region, matching: matching).first,
            "No matching rendered pixels in \(region).", file: file, line: line
        ).lowerBound
    }

    private func episodeArtworkSpan(in snapshot: UIImage) throws -> ClosedRange<CGFloat> {
        let spans = try horizontalPixelSpans(
            in: snapshot, region: CGRect(x: 60, y: 510, width: 540, height: 40)
        ) { r, g, b in b > 150 && r < 50 && g < 80 }
        return try XCTUnwrap(spans.max {
            $0.upperBound - $0.lowerBound < $1.upperBound - $1.lowerBound
        })
    }

    private func horizontalPixelSpans(
        in snapshot: UIImage, region: CGRect, matching: (UInt8, UInt8, UInt8) -> Bool
    ) throws -> [ClosedRange<CGFloat>] {
        let image = try XCTUnwrap(snapshot.cgImage?.cropping(to: region))
        let width = image.width
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        try bytes.withUnsafeMutableBytes {
            let context = try XCTUnwrap(CGContext(
                data: $0.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        var first: Int?
        var spans: [ClosedRange<CGFloat>] = []
        for x in 0..<width {
            let hasMatchingPixel = (0..<height).contains { y in
                let index = (y * width + x) * 4
                return matching(bytes[index], bytes[index + 1], bytes[index + 2])
            }
            if hasMatchingPixel {
                if first == nil { first = x }
            } else if let start = first {
                spans.append((region.minX + CGFloat(start))...(region.minX + CGFloat(x - 1)))
                first = nil
            }
        }
        if let first {
            spans.append((region.minX + CGFloat(first))...(region.minX + CGFloat(width - 1)))
        }
        return spans
    }

    func testKeylineSamplingRetainsRealMisalignmentAndIgnoresAPartialNeighbor() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        for offset in [CGFloat.zero, 4] {
            let snapshot = UIGraphicsImageRenderer(size: CGSize(width: 640, height: 1080), format: format).image { context in
                UIColor.black.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 640, height: 1080))
                UIColor.blue.setFill()
                context.fill(CGRect(x: 60, y: 510, width: 4, height: 40))
                context.fill(CGRect(x: 80 + offset, y: 510, width: 480, height: 40))
                UIColor.white.setFill()
                context.fill(CGRect(x: 81, y: 990, width: 20, height: 20))
            }
            let artwork = try episodeArtworkSpan(in: snapshot)
            let about = try leadingPixel(
                in: snapshot, region: CGRect(x: 0, y: 975, width: 300, height: 60)
            ) { r, g, b in r > 230 && g > 230 && b > 230 }
            XCTAssertEqual(artwork.upperBound - artwork.lowerBound + 1, 480)
            XCTAssertEqual(artwork.lowerBound, 80 + offset)
            XCTAssertEqual(abs(artwork.lowerBound - about) <= 1, offset == 0,
                           "A resting-width card must still fail alignment when shifted.")
        }
    }

    func testMissingDetailBackdropDoesNotReuseTheOutgoingPoster() async throws {
        let scene = try await activeScene()
        let fixture = FocusReturnFixture(scene: scene)
        defer { fixture.close() }
        fixture.source.prepare(for: fixture.item)
        let session = TVDetailEntranceSession()
        session.attach(to: fixture.window, enabled: true)
        session.finishImmediately()
        XCTAssertNotNil(session.returnArtwork, "The small snapshot is retained only for returning to the card.")
        let host = UIHostingController(rootView: HeroBackdropLayer(
            references: [], height: 1080, scrimTone: .black, ignoresOverscan: false
        ).environment(\.detailEntranceSession, session))
        host.view.backgroundColor = .black
        fixture.window.rootViewController = host
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        let screenshot = DetailTransitionSnapshot.image(of: fixture.window)
        let sample = try XCTUnwrap(screenshot.cgImage?.cropping(to: CGRect(x: 960, y: 100, width: 1, height: 1)))
        var bytes = [UInt8](repeating: 0, count: 4)
        try bytes.withUnsafeMutableBytes {
            let context = try XCTUnwrap(CGContext(
                data: $0.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(sample, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        XCTAssertLessThan(bytes[0], 30, "The red outgoing thumbnail must not become the page's backdrop.")
    }

    func testRealPosterReturnMatchesItsFocusedPaintedArtwork() async throws {
        let scene = try await activeScene()
        let artwork = try await seedArtwork(color: .red, size: CGSize(width: 200, height: 300))
        let layouts: [(CardStyle, PosterCardView.Style)] = [
            (.framed, .poster), (.borderless, .poster),
            (.framed, .landscape), (.borderless, .landscape)
        ]
        for (style, shape) in layouts {
            for focusStyle in CardFocusStyle.allCases {
                let model = RealPosterReturnModel(artwork: artwork)
                let host = UIHostingController(rootView: RealPosterReturnRoot(
                    model: model, style: style, focusStyle: focusStyle, shape: shape
                ))
                let previous = scene.windows.first(where: \.isKeyWindow)
                let window = UIWindow(windowScene: scene)
                window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
                window.rootViewController = host
                window.makeKeyAndVisible()
                host.view.layoutIfNeeded()
                defer {
                    model.session?.finishImmediately()
                    DetailTransitionNavigation.take(in: window)?.discard()
                    window.isHidden = true
                    window.rootViewController = nil
                    previous?.makeKeyAndVisible()
                }
                try await waitUntil { self.sourceView(in: host.view)?.reference?.isFocused == true }
                let source = try XCTUnwrap(sourceView(in: host.view)?.reference)
                try await Task.sleep(for: .milliseconds(600))
                let before = XCTAttachment(image: DetailTransitionSnapshot.image(of: window))
                before.name = "focused-source-\(style)-\(shape)-\(focusStyle)"
                before.lifetime = .keepAlways
                add(before)
                let initialPainted = try redArtworkBounds(in: window)
                let initialGeometry = try XCTUnwrap(source.geometry(in: window))
                if focusStyle == .system {
                    XCTAssertNotNil(source.nativeArtworkView, "System artwork must use native UIKit geometry.")
                }
                source.prepare(for: model.item)
                DetailTransitionNavigation.performNavigation { model.path.append(1) }
                try await waitUntil { model.session != nil }
                let session = try XCTUnwrap(model.session)
                try await waitUntil { session.stage == .complete }
                session.close { model.path.removeLast() }
                let cover = try XCTUnwrap(window.subviews.compactMap { $0 as? DetailTransitionOverlay }.first)
                try await waitUntil { cover.cardContainer.frame.width < 1000 }
                let target = cover.cardContainer.frame
                let radius = cover.cardContainer.layer.cornerRadius
                try await waitUntil { cover.superview == nil && source.isFocused == true }
                try await Task.sleep(for: .milliseconds(600))
                let painted = try redArtworkBounds(in: window)
                let after = XCTAttachment(image: DetailTransitionSnapshot.image(of: window))
                after.name = "focused-return-\(style)-\(shape)-\(focusStyle)"
                after.lifetime = .keepAlways
                add(after)
                let geometry = XCTAttachment(string: "Before: geometry \(initialGeometry), pixels \(initialPainted)\nAfter: geometry \(String(describing: source.geometry(in: window))), pixels \(painted)\n\(nativeProjectionDescription(source.nativeArtworkView, in: window))")
                geometry.name = "native-geometry-\(style)-\(shape)-\(focusStyle)"
                geometry.lifetime = .keepAlways
                add(geometry)
                XCTAssertEqual(target.minX, painted.minX, accuracy: 2, "\(style), \(focusStyle)")
                XCTAssertEqual(target.minY, painted.minY, accuracy: 2, "\(style), \(focusStyle)")
                XCTAssertEqual(target.width, painted.width, accuracy: 2, "\(style), \(focusStyle)")
                XCTAssertEqual(target.height, painted.height, accuracy: 2, "\(style), \(focusStyle)")
                XCTAssertEqual(radius, try XCTUnwrap(source.geometry(in: window)).cornerRadius, accuracy: 0.5)
            }
        }
    }

    func testNativeCircularTileHasNoSquareFocusPlate() async throws {
        let scene = try await activeScene()
        let artwork = try await seedArtwork(color: .red, size: CGSize(width: 200, height: 200))
        let previous = scene.windows.first(where: \.isKeyWindow)
        var focused = false
        let host = UIHostingController(rootView: CircularFocusTile(
            diameter: 200, focusPadding: 20, action: {},
            onFocusChange: { focused = $0 },
            avatar: { FallbackAsyncImage(urls: [artwork], variant: .personHeadshot) { Color.clear } },
            caption: { _ in Text("Circular portrait") }
        )
        .environment(\.plozzCardFocusStyle, .system)
        .environment(\.themePalette, .dark)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black))
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        try await waitUntil { focused }
        try await Task.sleep(for: .milliseconds(700))
        let image = DetailTransitionSnapshot.image(of: window)
        let attachment = XCTAttachment(image: image)
        attachment.name = "native-circular-focus"
        attachment.lifetime = .keepAlways
        add(attachment)
        let painted = try redArtworkBounds(in: window)
        XCTAssertEqual(painted.width, painted.height, accuracy: 2)
        XCTAssertNotNil(UIFocusSystem.focusSystem(for: window)?.focusedItem)
        let cgImage = try XCTUnwrap(image.cgImage)
        for corner in [
            CGPoint(x: painted.minX + 4, y: painted.minY + 4),
            CGPoint(x: painted.maxX - 4, y: painted.minY + 4)
        ] {
            let sample = try XCTUnwrap(cgImage.cropping(to: CGRect(origin: corner, size: CGSize(width: 1, height: 1))))
            var bytes = [UInt8](repeating: 0, count: 4)
            try bytes.withUnsafeMutableBytes {
                let context = try XCTUnwrap(CGContext(
                    data: $0.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                    bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                ))
                context.draw(sample, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            }
            XCTAssertLessThan(bytes.prefix(3).max() ?? 255, 20, "Native focus must not add a square plate behind the portrait.")
        }
    }

    func testSystemFocusSurvivesRapidHorizontalAndVerticalReversals() async throws {
        let scene = try await activeScene()
        let previous = scene.windows.first(where: \.isKeyWindow)
        let host = NativeFocusGridHost()
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        host.view.layoutIfNeeded()
        let system = try XCTUnwrap(UIFocusSystem.focusSystem(for: window))
        try await waitUntil { system.focusedItem != nil }
        let frames = host.cards.map { $0.view.frame }
        for index in [1, 0, 1, 3, 1, 0, 2, 0, 2, 3, 2, 0] {
            host.preferredIndex = index
            system.requestFocusUpdate(to: host)
            system.updateFocusIfNeeded()
            try await waitUntil {
                guard let item = system.focusedItem,
                      let owner = TVNavigationExitProtectionFocus.containingView(of: item) else { return false }
                return owner.isDescendant(of: host.cards[index].view)
            }
            try await Task.sleep(for: .milliseconds(30))
            XCTAssertEqual(host.cards.map { $0.view.frame }, frames, "Projection must not change the grid's layout.")
        }
        try await Task.sleep(for: .milliseconds(650))
        let attachment = XCTAttachment(image: DetailTransitionSnapshot.image(of: window))
        attachment.name = "native-focus-after-rapid-reversals"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testIndependentFocusSurfaceRemainsFocusableInSystemCardMode() async throws {
        let scene = try await activeScene()
        let previous = scene.windows.first(where: \.isKeyWindow)
        var focused = false
        let host = UIHostingController(rootView: IndependentFocusSurface { focused = $0 }
            .environment(\.plozzCardFocusStyle, .system))
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        try await waitUntil { focused }
        XCTAssertNotNil(UIFocusSystem.focusSystem(for: window)?.focusedItem)
    }

    private func sourceView(in view: UIView) -> DetailTransitionSourceView? {
        if let source = view as? DetailTransitionSourceView { return source }
        return view.subviews.lazy.compactMap { self.sourceView(in: $0) }.first
    }

    private func nativeProjectionDescription(_ view: UIView?, in window: UIWindow) -> String {
        var current = view
        var lines: [String] = []
        while let ancestor = current, ancestor !== window {
            lines.append("\(type(of: ancestor)): frame \(ancestor.frame), bounds \(ancestor.bounds), transform \(ancestor.layer.transform), sublayers \(ancestor.layer.sublayerTransform)")
            if let image = ancestor as? UIImageView {
                let guide = image.focusedFrameGuide
                lines.append("Focused guide \(guide.layoutFrame), window \(String(describing: guide.owningView?.convert(guide.layoutFrame, to: window)))")
            }
            current = ancestor.superview
        }
        return lines.joined(separator: "\n")
    }

    private func redArtworkBounds(in window: UIWindow) throws -> CGRect {
        let image = try XCTUnwrap(DetailTransitionSnapshot.image(of: window).cgImage)
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        try bytes.withUnsafeMutableBytes {
            let context = try XCTUnwrap(CGContext(
                data: $0.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        var minX = width, maxX = -1, minY = height, maxY = -1
        for y in 0..<height {
            for x in 0..<width {
                let index = (y * width + x) * 4
                if bytes[index] > 150,
                   Int(bytes[index]) > Int(bytes[index + 1]) + 60,
                   Int(bytes[index]) > Int(bytes[index + 2]) + 60 {
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
            }
        }
        XCTAssertGreaterThan(maxX, minX)
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    @MainActor
    private final class FocusReturnFixture {
        let window: UIWindow
        let previous: UIWindow?
        let source = DetailTransitionSourceReference()
        let item = MediaItem(id: "focused-return", title: "Focused return", kind: .movie)
        let controller = FocusReturnController()

        init(scene: UIWindowScene) {
            previous = scene.windows.first(where: \.isKeyWindow)
            window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
            window.rootViewController = controller
            controller.card.reference = source
            source.view = controller.card
            source.itemKey = item.stablePresentationID
            source.cornerRadius = 22
            source.focusRequester = controller
            window.makeKeyAndVisible()
            controller.view.layoutIfNeeded()
        }

        func close() {
            DetailTransitionNavigation.take(in: window)?.discard()
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
    }

    @MainActor
    private final class FocusReturnController: UIViewController, DetailTransitionFocusRequesting {
        let card = FocusScaledArtworkButton(type: .custom)
        let other = UIButton(type: .system)
        var prefersCard = true

        override var preferredFocusEnvironments: [any UIFocusEnvironment] {
            [prefersCard ? card : other]
        }

        func requestFocus() -> Bool {
            prefersCard = true
            setNeedsFocusUpdate()
            updateFocusIfNeeded()
            return true
        }

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            card.frame = CGRect(x: 160, y: 280, width: 240, height: 360)
            card.backgroundColor = .red
            card.layer.cornerRadius = 22
            card.layer.cornerCurve = .continuous
            card.clipsToBounds = true
            card.setTitle("Card", for: .normal)
            other.frame = CGRect(x: 600, y: 280, width: 200, height: 80)
            other.setTitle("Other", for: .normal)
            view.addSubview(card)
            view.addSubview(other)
        }
    }

    @MainActor
    private final class FocusScaledArtworkButton: UIButton {
        weak var reference: DetailTransitionSourceReference?

        override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
            super.didUpdateFocus(in: context, with: coordinator)
            reference?.isFocused = isFocused
            coordinator.addCoordinatedAnimations({
                self.transform = self.isFocused ? CGAffineTransform(scaleX: 1.12, y: 1.12) : .identity
            }, completion: nil)
        }
    }

    private func activeScene() async throws -> UIWindowScene {
        try await waitUntil {
            UIApplication.shared.connectedScenes.contains { $0.activationState == .foregroundActive }
        }
        return try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
    }

    private func makeTrailerVideo() async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("detail-trailer-\(UUID()).mov")
        addTeardownBlock { try FileManager.default.removeItem(at: url) }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 160, AVVideoHeightKey: 96
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 160,
            kCVPixelBufferHeightKey as String: 96
        ])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(
            kCFAllocatorDefault, 160, 96, kCVPixelFormatType_32BGRA, nil, &buffer
        ), kCVReturnSuccess)
        let pixels = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        if let address = CVPixelBufferGetBaseAddress(pixels) {
            memset(address, 0x80, CVPixelBufferGetDataSize(pixels))
        }
        CVPixelBufferUnlockBaseAddress(pixels, [])
        for frame in 0..<30 {
            try await waitUntil { input.isReadyForMoreMediaData || writer.status == .failed }
            XCTAssertTrue(adaptor.append(pixels, withPresentationTime: CMTime(value: Int64(frame), timescale: 1)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
        return url
    }

    private func verticalScroll(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView,
           scroll.bounds.height > 700 {
            return scroll
        }
        return view.subviews.lazy.compactMap { self.verticalScroll(in: $0) }.first
    }

    private func focusLowestDetailControl(in window: UIWindow, host: TransitionShowController) async throws {
        let scroll = try XCTUnwrap(verticalScroll(in: window))
        try await waitUntil { scroll.isScrollEnabled }
        let bottom = max(-scroll.adjustedContentInset.top,
                         scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
        scroll.setContentOffset(CGPoint(x: 0, y: bottom), animated: false)
        try await Task.sleep(for: .milliseconds(300))
        let system = try XCTUnwrap(UIFocusSystem.focusSystem(for: window))
        let target = try XCTUnwrap(focusTargets(in: scroll).compactMap { $0 as? UIView }.filter {
            window.bounds.intersects($0.convert($0.bounds, to: window))
        }.max {
            $0.convert($0.bounds, to: window).minY < $1.convert($1.bounds, to: window).minY
        })
        host.target = target
        system.requestFocusUpdate(to: host)
        system.updateFocusIfNeeded()
        try await waitUntil {
            system.focusedItem.map(ObjectIdentifier.init) == ObjectIdentifier(target)
                && host.settledFocusItemID == ObjectIdentifier(target)
        }
    }

    private func seedArtwork(
        color: UIColor = .blue, size: CGSize = CGSize(width: 320, height: 180), padding: CGFloat = 0
    ) async throws -> URL {
        let url = try XCTUnwrap(URL(string: "https://transition-fixture.example.test/\(UUID()).png"))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(
            size: CGSize(width: size.width + padding * 2, height: size.height + padding * 2), format: format
        ).image {
            color.setFill()
            $0.fill(CGRect(origin: CGPoint(x: padding, y: padding), size: size))
        }
        let bytes = try XCTUnwrap(image.pngData())
        let cache = try XCTUnwrap(ArtworkSession.shared.configuration.urlCache)
        for variant in ArtworkImageVariant.allCases {
            let requestURL = variant.requestURL(for: url)
            let request = URLRequest(url: requestURL)
            let response = try XCTUnwrap(HTTPURLResponse(
                url: requestURL, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "image/png", "Cache-Control": "max-age=3600"]
            ))
            cache.storeCachedResponse(CachedURLResponse(response: response, data: bytes), for: request)
            let decoded = await ArtworkImageCache.shared.image(for: url, variant: variant)
            _ = try XCTUnwrap(decoded)
        }
        return url
    }

    private func waitUntil(
        file: StaticString = #filePath, line: UInt = #line,
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + .seconds(6)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(condition(), "Production series fixture did not settle", file: file, line: line)
    }
}

@MainActor
private final class NativeFocusGridHost: UIViewController {
    let cards = (0..<4).map { UIHostingController(rootView: NativeFocusTestCard(index: $0)) }
    var preferredIndex = 0

    override var preferredFocusEnvironments: [any UIFocusEnvironment] { [cards[preferredIndex]] }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        for (index, card) in cards.enumerated() {
            addChild(card)
            view.addSubview(card.view)
            card.view.backgroundColor = .clear
            card.view.frame = CGRect(x: 250 + (index % 2) * 620, y: 80 + (index / 2) * 440, width: 540, height: 380)
            card.didMove(toParent: self)
        }
    }
}

private struct IndependentFocusSurface: View {
    let onFocus: (Bool) -> Void
    @FocusState private var focused: Bool

    var body: some View {
        Color.clear
            .frame(width: 400, height: 220)
            .focusableCard(isFocused: $focused, cornerRadius: 10, action: {})
            .onChange(of: focused) { _, value in onFocus(value) }
            .accessibilityLabel("Independent picture control")
    }
}

private struct NativeFocusTestCard: View {
    let index: Int
    @PlozzCardFocus private var focused: Bool

    var body: some View {
        VStack(spacing: 28) {
            Color(uiColor: .red)
                .frame(width: 440, height: 248)
                .clipShape(RoundedRectangle(cornerRadius: 28))
                .plozzFocusHalo(cornerRadius: 28, focusScale: 1.1, isFocused: focused)
            Text(verbatim: "Native card \(index)")
                .foregroundStyle(.white)
        }
        .focusableCard(isFocused: $focused, cornerRadius: 28, action: {})
        .plozzCardFocusTransition(isFocused: focused)
        .environment(\.plozzCardFocusStyle, .system)
    }
}

@MainActor @Observable
private final class RealPosterReturnModel {
    let item: MediaItem
    var path: [Int] = []
    @ObservationIgnored var session: TVDetailEntranceSession?

    init(artwork: URL) {
        item = MediaItem(id: "real-return", title: "Real return", kind: .movie, posterURL: artwork)
    }
}

private struct RealPosterReturnRoot: View {
    @Bindable var model: RealPosterReturnModel
    let style: CardStyle
    let focusStyle: CardFocusStyle
    var shape = PosterCardView.Style.poster

    var body: some View {
        NavigationStack(path: $model.path) {
            PosterCardView(item: model.item, style: shape, enablesAsyncArtworkFallback: false) { model.path.append(1) }
                .frame(width: shape == .poster ? 240 : 520)
                .environment(\.plozzCardStyle, style)
                .environment(\.plozzCardFocusStyle, focusStyle)
                .environment(\.plozzReduceTransparency, true)
                .navigationDestination(for: Int.self) { _ in
                    RealPosterReturnPage(model: model)
                        .cinematicDetailPage(isEnabled: true)
                }
        }
    }
}

private struct RealPosterReturnPage: View {
    let model: RealPosterReturnModel
    @Environment(\.detailEntranceSession) private var session

    var body: some View {
        Button("Play") {}
            .detailEntranceStage(.controls)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.blue)
            .onAppear { model.session = session }
    }
}

@MainActor
private final class PendingDetailTrailer {
    private(set) var started = false
    private var continuation: CheckedContinuation<HeroTrailerSource?, Never>?

    func resolve() async -> HeroTrailerSource? {
        await withCheckedContinuation {
            continuation = $0
            started = true
        }
    }

    func complete(_ source: HeroTrailerSource?) {
        continuation?.resume(returning: source)
        continuation = nil
    }
}

@MainActor @Observable
private final class TransitionShowModel {
    let provider: TransitionShowProvider
    let detail: ItemDetailViewModel
    let trailer = HeroTrailerController()
    var trailerReturnItemID: String?
    let stackDepth = DetailStackDepth()
    let coveredPageID = UUID()
    let homeRecede = HomeHeroRecedeModel()
    var showsHomeHero = true
    var gradientEnabled = true
    @ObservationIgnored var resolveTrailer: HeroTrailerResolving = { _ in nil }
    let background = HeroBackgroundSettingsModel(store: InMemoryHeroBackgroundSettingsStore(
        HeroBackgroundSettings(homeTrailerEnabled: false, detailMode: .off)
    ))
    var path: [Int] = []

    init(provider: TransitionShowProvider) {
        self.provider = provider
        detail = ItemDetailViewModel(
            provider: provider, itemID: provider.show.id,
            initialItem: provider.show,
            externalMetadataResolver: { _, region in
                ExternalTitleMetadata(enrichment: MetadataEnrichment(),
                                      availability: ExternalTitleAvailability(regionCode: region))
            },
            sourceAccountID: "transition-fixture",
            onlineTrailerResolver: { _ in [] },
            playableVideoIDResolver: { _ in nil },
            trailerCache: TrailerResolutionCache()
        )
    }
}

private struct TrailerReturnHomeRoot: View {
    @Bindable var model: TransitionShowModel
    @Namespace private var focusScope

    var body: some View {
        if model.showsHomeHero {
            HomeHeroView(
                items: [model.provider.show], settings: .default,
                backgroundSettings: model.background.settings,
                trailerController: model.trailer, trailerResolver: { _ in nil },
                isFrontmost: model.path.isEmpty, spoilerSettings: .default,
                navigationStyle: .rail, focusScope: focusScope,
                onSelect: { _ in }, onPlay: { _ in },
                onTrailerReturnItemChanged: { model.trailerReturnItemID = $0 },
                recedeModel: model.homeRecede
            )
        } else {
            Color.clear
        }
    }
}

private struct TransitionShowRoot: View {
    @Bindable var model: TransitionShowModel
    var focusStyle: CardFocusStyle = .system
    var directEntry = false

    var body: some View {
        TabView {
            Tab("Home", systemImage: "house") {
                NavigationStack(path: $model.path) {
                    Button("Open show") { model.path.append(1) }
                        .navigationDestination(for: Int.self) { destination in
                            if destination == 2 {
                                Button("Covered detail") {}
                                    .onAppear { model.stackDepth.pageAppeared(model.coveredPageID) }
                                    .onDisappear { model.stackDepth.pageDismissed(model.coveredPageID) }
                            } else {
                                ItemDetailView(
                                    viewModel: model.detail, onPlay: { _ in }, onSelectChild: { _ in },
                                    stackDepth: model.stackDepth,
                                    heroTrailerResolver: model.resolveTrailer,
                                    preservesHeroTrailerOnDisappear: {
                                        model.path.isEmpty && model.trailerReturnItemID == $0
                                    },
                                    initialEpisode: directEntry ? model.provider.episode : nil
                                )
                                .environment(model.trailer)
                                .environment(model.background)
                                .environment(\.plozzCardFocusStyle, focusStyle)
                                .environment(\.plozzPinnedSidebarActive, true)
                                .environment(\.plozzNavigationContentInset, 0)
                            }
                        }
                }
            }
        }
        .tabViewStyle(.tabBarOnly)
        .environment(\.themePalette, .dark)
        .environment(\.gradientBackgroundsEnabled, model.gradientEnabled)
    }
}

@MainActor
private final class TransitionShowController: UIHostingController<TransitionShowRoot> {
    var target: (any UIFocusEnvironment)?
    private var focusAnimationGeneration = 0
    private(set) var settledFocusItemID: ObjectIdentifier?

    override var preferredFocusEnvironments: [any UIFocusEnvironment] {
        target.map { [$0] } ?? super.preferredFocusEnvironments
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        focusAnimationGeneration += 1
        let generation = focusAnimationGeneration
        let focused = context.nextFocusedItem.map(ObjectIdentifier.init)
        settledFocusItemID = nil
        coordinator.addCoordinatedAnimations(nil) { [weak self] in
            guard let self, focusAnimationGeneration == generation else { return }
            settledFocusItemID = focused
        }
    }
}

private struct TransitionShowProvider: MediaProvider {
    let artwork: URL
    var logo: URL?
    var episodeCount = 1
    var detailItem: MediaItem?
    var kind: ProviderKind { .jellyfin }
    var session: UserSession {
        UserSession(server: MediaServer(id: "transition-fixture", name: "Fixture",
                                       baseURL: artwork, provider: .jellyfin),
                    userID: "fixture", userName: "Fixture", deviceID: "fixture", accessToken: "")
    }
    var show: MediaItem {
        if let detailItem { return detailItem }
        var item = MediaItem(id: "show", title: "Transition Show", kind: .series)
        item.sourceAccountID = "transition-fixture"
        item.posterURL = artwork
        item.backdropURL = artwork
        item.logoURL = logo ?? artwork
        item.overview = "A production series detail fixture with a real episode browser."
        return item
    }
    var season: MediaItem {
        var item = MediaItem(id: "season", title: "Season 1", kind: .season)
        item.seriesID = "show"
        item.sourceAccountID = "transition-fixture"
        item.seasonNumber = 1
        return item
    }
    var episode: MediaItem {
        var item = MediaItem(id: "episode", title: "Episode 1", kind: .episode)
        item.sourceAccountID = "transition-fixture"
        item.seriesID = "show"
        item.seasonID = "season"
        item.seasonNumber = 1
        item.episodeNumber = 1
        item.posterURL = artwork
        item.runtime = 1800
        return item
    }
    func libraries() async throws -> [MediaLibrary] { [] }
    func continueWatching(limit: Int) async throws -> [MediaItem] {
        try await Task.sleep(for: .milliseconds(700))
        return []
    }
    func latest(limit: Int) async throws -> [MediaItem] { [] }
    func item(id: String) async throws -> MediaItem { id == "show" ? show : episode }
    func children(of itemID: String) async throws -> [MediaItem] {
        if show.kind == .movie { return [] }
        try await Task.sleep(for: .milliseconds(100))
        if itemID == "show" { return [season] }
        return (0..<episodeCount).map { index in
            var item = episode
            item.id = index == 0 ? episode.id : "episode-\(index)"
            item.episodeNumber = index + 1
            item.title = "Episode \(index + 1)"
            item.overview = "An episode overview that occupies the focused card's reserved synopsis area."
            return item
        }
    }
    func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        MediaPage(items: [], startIndex: 0, totalCount: 0)
    }
    func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
    func playbackInfo(for itemID: String) async throws -> PlaybackRequest { throw AppError.notFound }
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {}
    func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { artwork }
}
