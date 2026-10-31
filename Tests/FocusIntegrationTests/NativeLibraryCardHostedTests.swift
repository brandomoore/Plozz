#if os(tvOS)
import CoreModels
@testable import CoreUI
@testable import FeatureHome
import MetadataKit
import Network
import Observation
import SwiftUI
import TVUIKit
import UIKit
import XCTest

@MainActor
final class NativeLibraryCardHostedTests: XCTestCase {
    private var savedProviders = MetadataProviderSettings.default

    func testLibraryCaptionsHonorHomeLibraryOverrideAcrossCardAndFocusStyles() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let library = AggregatedLibrary(
            accountID: "fixture", accountName: "Viewer", serverName: "Server", providerKind: .jellyfin,
            library: MediaLibrary(id: "movies", title: "Movies", kind: .movie)
        )
        let host = UIHostingController(rootView: AnyView(EmptyView()))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        for style in CardStyle.allCases {
            for focusStyle in CardFocusStyle.allCases {
                var heights: [CardCaptionPreference: CGFloat] = [:]
                for preset in [CardCaptionPreference.show, .hide, .recommended] {
                    var activations = 0
                    host.rootView = AnyView(
                        LibraryCardView(aggregated: library, subtitle: "Server", action: { activations += 1 })
                            .fixedSize(horizontal: false, vertical: true)
                            .background(LibraryCardFrameProbe())
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .environment(\.plozzCardCaptionSettings, .init(
                                preference: preset,
                                overrides: [.home: preset == .hide, .homeLibraries: preset != .hide]
                            ))
                            .environment(\.plozzCardCaptionView, .home)
                            .environment(\.plozzCardStyle, style)
                            .environment(\.plozzCardFocusStyle, focusStyle)
                    )
                    host.view.layoutIfNeeded()
                    try await Task.sleep(for: .milliseconds(150))
                    host.view.layoutIfNeeded()
                    heights[preset] = try XCTUnwrap(slotProbe(in: host.view)).bounds.height
                    if focusStyle.usesSystemEffect {
                        XCTAssertEqual(descendant(SystemPosterCaption.CaptionView.self, in: host.view) == nil,
                                       preset == .hide)
                        let poster = try XCTUnwrap(descendant(NativePosterButton.self, in: host.view))
                        XCTAssertTrue(poster.accessibilityLabel?.contains("Movies") == true)
                        poster.sendActions(for: .primaryActionTriggered)
                        XCTAssertEqual(activations, 1)
                    }
                }
                XCTAssertLessThan(try XCTUnwrap(heights[.hide]), try XCTUnwrap(heights[.show]) - 20)
                XCTAssertEqual(try XCTUnwrap(heights[.show]), try XCTUnwrap(heights[.recommended]), accuracy: 1)
            }
        }
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

    func testNativeBrowseChangesBetweenOnlineAndLibraryPixelsWithoutChangingTheItem() async throws {
        try await checkNativeBrowseArtwork(onlineDelay: 0)
    }

    func testSharedPosterMeasurementDoesNotChangeCommittedArtwork() async throws {
        let image = try XCTUnwrap(UIImage(data: artworkData(.red)))
        let host = UIHostingController(rootView: SharedZoomFixture(image: image, aspect: 2 / 3))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        controller.addChild(host)
        controller.view.addSubview(host.view)
        host.didMove(toParent: controller)
        host.view.frame = CGRect(x: 400, y: 200, width: 260, height: 390)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        window.layoutIfNeeded()
        host.view.layoutIfNeeded()
        let poster = try XCTUnwrap(descendant(NativePosterButton.self, in: host.view))
        poster.layoutIfNeeded()
        let deadline = ContinuousClock.now + .seconds(5)
        while !(try poster.image.map {
            try isRed($0, at: CGPoint(x: $0.size.width * $0.scale / 2, y: $0.size.height * $0.scale / 2))
        } ?? false), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let rendered = try XCTUnwrap(poster.image)
        XCTAssertEqual(rendered.size, CGSize(width: 260, height: 390))
        XCTAssertTrue(try isRed(rendered, at: CGPoint(
            x: rendered.size.width * rendered.scale / 2, y: rendered.size.height * rendered.scale / 2
        )))
        for width: CGFloat in [280, 260, 600, 260] {
            _ = host.sizeThatFits(in: CGSize(width: width, height: 1000))
            XCTAssertTrue(poster.image === rendered, "Measurements must leave committed pixels alone.")
            XCTAssertEqual(poster.contentSize, CGSize(width: 260, height: 390))
        }
    }

    func testDetachedPosterDefersArtworkPreparation() {
        let size = CGSize(width: 260, height: 390)
        let placeholder = NativePosterArtworkBitmap.placeholder(size: size, scale: 2)
        XCTAssertTrue(placeholder === NativePosterArtworkBitmap.placeholder(size: size, scale: 2))
        let poster = NativePosterButton(image: placeholder)
        poster.contentSize = size
        var preparations = 0
        poster.prepareArtwork = { _ in
            preparations += 1
            return placeholder
        }
        for width: CGFloat in [280, 260, 600, 260] {
            poster.frame.size = CGSize(width: width, height: width * 1.5)
            poster.layoutIfNeeded()
        }
        XCTAssertEqual(preparations, 0, "Unattached lazy-row estimates must not render artwork or indicators.")
        XCTAssertTrue(poster.image === placeholder)
    }

    func testSharedStatusBitmapsReusePixelsAndBoundTheirCache() throws {
        var environment = EnvironmentValues()
        environment.displayScale = 2
        environment.plozzWatchStatusIndicator = .unwatched
        environment.plozzShowsUnwatchedEpisodeCount = true
        let size = CGSize(width: 280, height: 420)
        func render(_ count: Int, layer: NativePosterIndicatorLayer = .background) throws -> UIImage {
            let inputs = NativePosterIndicators.media(MediaCardPlaybackIndicators(
                item: MediaItem(id: "count-\(count)", title: "Series", kind: .series, unwatchedEpisodeCount: count),
                badgeInset: 8
            ).statusOnly)
            return try XCTUnwrap(NativePosterArtworkBitmap.indicatorImage(
                key: .init(inputs, environment: environment, layer: layer),
                size: size, scale: 2, environment: environment
            ))
        }
        let first = try render(21)
        XCTAssertTrue(try render(21) === first)
        let foreground = try render(21, layer: .foreground)
        XCTAssertNotEqual(foreground.pngData(), first.pngData(), "Digits and their baked background need separate pixels.")
        XCTAssertTrue(try render(21, layer: .foreground) === foreground)
        XCTAssertTrue(try render(21) === first)
        XCTAssertFalse(try render(22) === first)
        for count in 100..<120 {
            try autoreleasepool {
                _ = try render(count)
                _ = try render(count, layer: .foreground)
            }
            XCTAssertLessThanOrEqual(NativePosterArtworkBitmap.indicatorBytes, NativePosterArtworkBitmap.indicatorByteLimit)
            XCTAssertLessThanOrEqual(NativePosterArtworkBitmap.indicatorCount, NativePosterArtworkBitmap.indicatorCountLimit)
        }
    }

    func testAttachedCountDoesNotExposePaleArtworkAlongItsOuterCurve() throws {
        let size = CGSize(width: 252, height: 378)
        var environment = EnvironmentValues()
        environment.displayScale = 2
        environment.plozzWatchStatusIndicator = .unwatched
        environment.plozzShowsUnwatchedEpisodeCount = true
        let indicators = NativePosterIndicators.media(MediaCardPlaybackIndicators(
            item: MediaItem(id: "pale", title: "Pale artwork", kind: .series, unwatchedEpisodeCount: 21),
            badgeInset: 8, artworkCornerRadius: 21
        ).statusOnly)
        let key = NativePosterArtworkBitmap.IndicatorKey(indicators, environment: environment)
        let overlay = try XCTUnwrap(NativePosterArtworkBitmap.indicatorImage(
            key: key, size: size, scale: 2, environment: environment
        ))
        let source = try XCTUnwrap(UIImage(data: artworkData(.white)))
        let image = try XCTUnwrap(NativePosterArtworkBitmap.image(source: source, overlay: overlay, size: size, scale: 2))
        let bitmap = try XCTUnwrap(image.cgImage)
        var lightest = 0
        var samples = 0
        for x in (bitmap.width - 42)..<bitmap.width {
            for y in 0..<20 {
                let value = try pixel(image, at: CGPoint(x: x, y: y))
                guard value[3] > 32 else { continue }
                lightest = max(lightest, Int(value[0]) * 255 / Int(value[3]))
                samples += 1
            }
        }
        XCTAssertGreaterThan(samples, 100)
        XCTAssertLessThan(lightest, 70, "The count must cover pale artwork right up to the one outer clip.")
    }

    func testNativeOverlayIsLimitedToCountsAndFloatingStatus() {
        let movie = MediaItem(id: "movie", title: "Movie", kind: .movie)
        let watched = MediaItem(id: "watched", title: "Watched", kind: .movie, isPlayed: true)
        let series = MediaItem(id: "series", title: "Series", kind: .series, unwatchedEpisodeCount: 12)
        let cases: [(NativePosterIndicators, WatchStatusIndicator, Bool)] = [
            (.media(MediaCardPlaybackIndicators(item: movie, badgeInset: 8).statusOnly), .unwatched, false),
            (.media(MediaCardPlaybackIndicators(item: movie, badgeInset: 8).withoutStatus), .unwatched, false),
            (.media(MediaCardPlaybackIndicators(item: watched, badgeInset: 8).statusOnly), .unwatched, false),
            (.media(MediaCardPlaybackIndicators(item: watched, badgeInset: 8).statusOnly), .watched, true),
            (.media(MediaCardPlaybackIndicators(item: series, badgeInset: 8).statusOnly), .unwatched, true),
            (.media(MediaCardPlaybackIndicators(item: series, hidesStatus: true, badgeInset: 8)), .unwatched, false),
            (.episode(isWatched: false, hasProgress: false, isVisible: true,
                      style: .unwatched, badgeSize: 40, flagSize: 40), .unwatched, false)
        ]
        for (inputs, style, usesOverlay) in cases {
            var environment = EnvironmentValues()
            environment.plozzWatchStatusIndicator = style
            environment.plozzShowsUnwatchedEpisodeCount = true
            let key = NativePosterArtworkBitmap.IndicatorKey(inputs, environment: environment)
            XCTAssertEqual(key.overlayPlacement != nil, usesOverlay)
        }
    }

    func testAttachedUnwatchedFlagIsWhiteOverDarkArtwork() throws {
        let size = CGSize(width: 252, height: 378)
        var environment = EnvironmentValues()
        environment.plozzWatchStatusIndicator = .unwatched
        let key = NativePosterArtworkBitmap.IndicatorKey(.media(MediaCardPlaybackIndicators(
            item: MediaItem(id: "dark", title: "Dark artwork", kind: .movie), badgeInset: 8
        ).statusOnly), environment: environment)
        let overlay = try XCTUnwrap(NativePosterArtworkBitmap.indicatorImage(
            key: key, size: size, scale: 1, environment: environment
        ))
        let source = try XCTUnwrap(UIImage(data: artworkData(.black)))
        let image = try XCTUnwrap(NativePosterArtworkBitmap.image(source: source, overlay: overlay, size: size, scale: 1))
        let value = try pixel(image, at: CGPoint(x: size.width - 20, y: 10))
        XCTAssertGreaterThanOrEqual(value[0], 254)
        XCTAssertGreaterThanOrEqual(value[1], 254)
        XCTAssertGreaterThanOrEqual(value[2], 254)
    }

    func testFinalArtworkMaskPreservesSourceAlphaAndOrientation() throws {
        let size = CGSize(width: 120, height: 180)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.preferredRange = .standard
        let source = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.red.withAlphaComponent(0.5).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 120, height: 90))
            UIColor.blue.withAlphaComponent(0.5).setFill()
            context.fill(CGRect(x: 0, y: 90, width: 120, height: 90))
        }
        let rotated = UIImage(cgImage: try XCTUnwrap(source.cgImage), scale: 1, orientation: .down)
        let image = try XCTUnwrap(NativePosterArtworkBitmap.image(source: rotated, size: size, scale: 1))
        let top = try pixel(image, at: CGPoint(x: 60, y: 40))
        let bottom = try pixel(image, at: CGPoint(x: 60, y: 140))
        XCTAssertEqual(Int(top[2]), 128, accuracy: 2)
        XCTAssertEqual(top[0], 0)
        XCTAssertEqual(Int(bottom[0]), 128, accuracy: 2)
        XCTAssertEqual(bottom[2], 0)
        XCTAssertEqual(Int(top[3]), 128, accuracy: 2)
        XCTAssertEqual(Int(bottom[3]), 128, accuracy: 2)
        XCTAssertEqual(try pixel(image, at: .zero)[3], 0)
    }

    func testRoundedArtworkHasNoResidualPixelsInAnyCornerAtFractionalSizes() throws {
        let source = try XCTUnwrap(UIImage(data: artworkData(.white)))
        for size in [
            CGSize(width: 252, height: 378),
            CGSize(width: 252.25, height: 378.375),
            CGSize(width: 388, height: 388 / ContinueWatchingCardShape.aspectRatio)
        ] {
            for scale: CGFloat in [1, 2] {
                let image = try XCTUnwrap(NativePosterArtworkBitmap.image(
                    source: source, size: size, scale: scale
                ))
                let bitmap = try XCTUnwrap(image.cgImage)
                var maximumAlpha: UInt8 = 0
                for x in [0, 1, bitmap.width - 2, bitmap.width - 1] {
                    for y in [0, 1, bitmap.height - 2, bitmap.height - 1] {
                        maximumAlpha = max(maximumAlpha, try pixel(image, at: CGPoint(x: x, y: y))[3])
                    }
                }
                XCTAssertEqual(maximumAlpha, 0, "Every corner must be clear at \(size) @\(scale).")
                let attachment = XCTAttachment(image: image)
                attachment.name = "rounded-edge-\(size.width)-\(size.height)-\(scale)"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }

    func testContinueWatchingKeepsResumeChromeWithoutWatchMarksOrDarkRim() async throws {
        let color = UIColor(red: 0.2, green: 0.85, blue: 0.2, alpha: 1)
        let server = try LibraryArtworkServer(images: ["artwork": artworkData(color, size: CGSize(width: 640, height: 360))])
        defer { server.stop() }
        let port = try await server.start()
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/artwork/\(UUID())"))
        let model = AttachedStatusModel(item: MediaItem(
            id: "continue", title: "Continue episode", kind: .episode, seasonNumber: 4, episodeNumber: 4,
            runtime: 1380, fallbackArtworkURL: url, allowsTitleBasedMetadataMatching: false
        ))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let controller = LibraryFocusController()
        controller.view.backgroundColor = .magenta
        let host = UIHostingController(rootView: ContinueWatchingStatusFixture(model: model))
        controller.addChild(host)
        controller.view.addSubview(host.view)
        host.didMove(toParent: controller)
        host.view.frame = CGRect(x: 400, y: 200, width: 408, height: 400)
        host.view.backgroundColor = .clear
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        window.layoutIfNeeded()
        let poster = try XCTUnwrap(descendant(NativePosterButton.self, in: host.view))
        for (watched, progress) in [(false, nil), (true, nil), (false, 0.4)] as [(Bool, Double?)] {
            model.item.isPlayed = watched
            model.item.playedPercentage = progress
            model.indicator = watched ? .watched : .unwatched
            let deadline = ContinuousClock.now + .seconds(5)
            while ContinuousClock.now < deadline {
                if let image = poster.image, let bitmap = image.cgImage {
                    let sample = try pixel(image, at: CGPoint(x: bitmap.width / 2, y: bitmap.height / 4))
                    if sample[1] > 90, sample[0] < 60 { break }
                }
                try await Task.sleep(for: .milliseconds(30))
            }
            try await Task.sleep(for: .milliseconds(500))
            let image = try XCTUnwrap(poster.image)
            let bitmap = try XCTUnwrap(image.cgImage)
            XCTAssertEqual(image.size, poster.artworkView.bounds.size,
                           "Native alpha-masked focus requires the bitmap and image view to have the same aspect.")
            let scale = image.scale
            let center = try pixel(image, at: CGPoint(x: bitmap.width / 2, y: bitmap.height / 4))
            XCTAssertGreaterThan(center[1], 90, "Fixture must load its actual artwork with the legibility wash.")
            XCTAssertLessThan(center[0], 60, "A gray placeholder is not loaded artwork.")
            for point in [
                CGPoint(x: CGFloat(bitmap.width) / 2, y: 2 * scale),
                CGPoint(x: 2 * scale, y: CGFloat(bitmap.height) / 4),
                CGPoint(x: CGFloat(bitmap.width) - 20 * scale, y: 10 * scale),
                CGPoint(x: CGFloat(bitmap.width) - 37 * scale, y: 34 * scale)
            ] {
                let edge = try pixel(image, at: point)
                XCTAssertEqual(Int(edge[0]), Int(center[0]), accuracy: 3, "No watch mark or dark rim at \(point).")
                XCTAssertEqual(Int(edge[1]), Int(center[1]), accuracy: 3, "No watch mark or dark rim at \(point).")
            }
            let rendered = snapshot(window)
            let frame = try XCTUnwrap(NativeFocusProjection.artworkFrame(of: poster.artworkView, in: window))
            XCTAssertTrue(poster.isFocused)
            poster.hostedOverlay?.isHidden = true
            let artworkOnly = snapshot(window)
            poster.hostedOverlay?.isHidden = false
            for point in [
                CGPoint(x: frame.midX, y: frame.minY - 2),
                CGPoint(x: frame.minX - 2, y: frame.midY),
                CGPoint(x: frame.maxX + 2, y: frame.midY),
                CGPoint(x: frame.midX, y: frame.maxY + 2)
            ] {
                let actual = try pixel(rendered, at: point)
                let expected = try pixel(artworkOnly, at: point)
                for channel in 0..<3 {
                    XCTAssertEqual(Int(actual[channel]), Int(expected[channel]), accuracy: 4,
                                   "Live chrome must not paint a dark rim outside the artwork at \(point).")
                }
            }
            let bottom = try XCTUnwrap(rendered.cgImage?.cropping(to: CGRect(
                x: frame.minX + 10, y: frame.maxY - 65, width: frame.width - 20, height: 50
            )))
            let pixels = try rgba(bottom)
            let whitePixels = stride(from: 0, to: pixels.count, by: 4).filter {
                pixels[$0] > 220 && pixels[$0 + 1] > 220 && pixels[$0 + 2] > 220
            }.count
            XCTAssertGreaterThan(whitePixels, 200, "Keep the live play/episode/time or resume-progress chrome.")
            let logo = try XCTUnwrap(rendered.cgImage?.cropping(to: CGRect(
                x: frame.minX + 30,
                y: frame.minY + frame.height * ContinueWatchingCardShape.logoCenter - 30,
                width: frame.width - 60, height: 60
            )))
            let logoPixels = try rgba(logo)
            XCTAssertGreaterThan(stride(from: 0, to: logoPixels.count, by: 4).filter {
                logoPixels[$0] > 220 && logoPixels[$0 + 1] > 220 && logoPixels[$0 + 2] > 220
            }.count, 400, "Moving the background must not move the logo down toward the resume chip.")
            let attachment = XCTAttachment(image: rendered)
            attachment.name = "continue-watching-edge-and-chrome-\(watched)-\(progress ?? 0)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    private struct ContinueWatchingStatusFixture: View {
        let model: AttachedStatusModel
        var body: some View {
            PosterCardView(
                item: model.item, style: .landscape, showsSeriesArtwork: true,
                enablesAsyncArtworkFallback: false, showsResumeChip: true, action: {}
            )
            .environment(\.plozzCardStyle, .borderless)
            .environment(\.plozzCardFocusStyle, .system)
            .environment(\.plozzCardCaptionSettings, CardCaptionSettings(showsLabels: false))
            .environment(\.plozzWatchStatusIndicator, model.indicator)
        }
    }

    func testSharedPosterKeepsApprovedNativeFocusCompositionAtEveryAspect() async throws {
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
        for (aspect, hasStatus) in [
            (2 / 3, true), (2 / 3, false), (16 / 9, true), (1, true),
            (ContinueWatchingCardShape.aspectRatio, true)
        ] as [(CGFloat, Bool)] {
            let size = CGSize(width: 100, height: 100 / aspect)
            let image = UIGraphicsImageRenderer(size: size).image { context in
                UIColor.gray.setFill()
                context.fill(CGRect(origin: .zero, size: size))
                UIColor.red.setFill()
                for x: CGFloat in [12, 82] {
                    context.fill(CGRect(x: x, y: size.height * 0.25, width: 6, height: size.height * 0.4))
                }
            }
            let controller = LibraryFocusController()
            controller.view.backgroundColor = .black
            let host = UIHostingController(rootView: SharedZoomFixture(
                image: image, aspect: aspect,
                item: MediaItem(id: "composition", title: "Composition", kind: .series,
                               unwatchedEpisodeCount: hasStatus ? 12 : nil, isPlayed: !hasStatus)
            ).environment(\.displayScale, 2).environment(\.plozzWatchStatusIndicator, .unwatched))
            controller.addChild(host)
            controller.view.addSubview(host.view)
            host.didMove(toParent: controller)
            host.view.backgroundColor = .clear
            host.view.frame = CGRect(x: 400, y: 200, width: 280, height: 280 / aspect)
            window.rootViewController = controller
            window.makeKeyAndVisible()
            window.layoutIfNeeded()
            let poster = try XCTUnwrap(descendant(NativePosterButton.self, in: host.view))
            let artworkDeadline = ContinuousClock.now + .seconds(5)
            while ContinuousClock.now < artworkDeadline {
                let bitmap = try XCTUnwrap(poster.image)
                let marker = try pixel(bitmap, at: CGPoint(
                    x: bitmap.size.width * bitmap.scale * 0.15, y: bitmap.size.height * bitmap.scale * 0.4
                ))
                if marker[0] > 180 && marker[1] < 100 { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            let before = try XCTUnwrap(poster.image)
            XCTAssertGreaterThan(try pixel(before, at: CGPoint(
                x: before.size.width * before.scale * 0.15, y: before.size.height * before.scale * 0.4
            ))[0], 180)
            XCTAssertEqual(before.size, poster.artworkView.bounds.size,
                           "The native alpha-mask contract must hold at 2x, including fractional layout heights.")
            if aspect < 1 {
                let alpha = try XCTUnwrap(before.cgImage).alphaInfo
                XCTAssertTrue([.none, .noneSkipFirst, .noneSkipLast].contains(alpha),
                              "Rectangular native focus requires opaque artwork without baked alpha corners.")
            }
            let overlay = try XCTUnwrap(poster.hostedOverlay)
            controller.target = poster
            let system = try XCTUnwrap(UIFocusSystem.focusSystem(for: window))
            system.requestFocusUpdate(to: controller)
            system.updateFocusIfNeeded()
            try await Task.sleep(for: .milliseconds(500))
            XCTAssertTrue(system.focusedItem === poster)
            try assertCompositedArtworkGeometry(
                poster.artworkView, in: window, expectedScale: nil, landmarkTolerance: 1,
                maximumInternalScale: aspect < 1 ? 1.02 : 1
            )
            XCTAssertTrue(poster.image === before, "Native focus must always reuse the artwork bitmap.")
            XCTAssertTrue(poster.hostedOverlay === overlay, "Counts and progress must retain their live overlay.")
            let surface = poster.overlayView
            XCTAssertEqual(overlay.convert(overlay.bounds, to: surface), surface.bounds)
            let attachment = XCTAttachment(image: snapshot(window))
            attachment.name = "shared-poster-focus-composition-\(aspect)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    func testNativePortraitMotionEffectOffsetsHaveCleanCorners() async throws {
        for width: CGFloat in [200, 240, 280, 320] {
            try await checkDirectionalPortrait(width: width, checksSheen: false)
        }
    }

    func testSharedPosterUpdatesNativeMaskWhenAspectChanges() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let image = try XCTUnwrap(UIImage(data: artworkData(.red)))
        let host = UIHostingController(rootView: SharedZoomFixture(image: image, aspect: 2 / 3))
        let controller = LibraryFocusController()
        controller.addChild(host)
        controller.view.addSubview(host.view)
        host.didMove(toParent: controller)
        host.view.frame = CGRect(x: 400, y: 200, width: 280, height: 420)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        window.layoutIfNeeded()
        let poster = try XCTUnwrap(descendant(NativePosterButton.self, in: host.view))
        for aspect: CGFloat in [16 / 9, 1, 2 / 3] {
            host.rootView = SharedZoomFixture(image: image, aspect: aspect)
            try await Task.sleep(for: .milliseconds(100))
            window.layoutIfNeeded()
            XCTAssertTrue(descendant(NativePosterButton.self, in: host.view) === poster)
            XCTAssertEqual(poster.artworkView.masksFocusEffectToContents, aspect >= 1)
        }
    }

    func testNativePortraitMotionEffectOffsetsMoveTheHighlight() async throws {
        try await checkDirectionalPortrait(width: 280, checksSheen: true)
    }

    func testNativePortraitCountStaysInsideTileWithMotionEffectOffsets() async throws {
        try await checkDirectionalPortrait(width: 280, checksSheen: false, count: 88)
    }

    func testNativePortraitMotionEffectOffsetsAtRetinaRowSizes() async throws {
        for width: CGFloat in [220.25, 280] {
            try await checkDirectionalPortrait(width: width, checksSheen: false, displayScale: 2)
        }
    }

    func testNativePortraitMotionEffectOffsetsAfterFocusedArtworkReplacement() async throws {
        try await checkDirectionalPortrait(width: 280, checksSheen: false, displayScale: 2,
                                           replacesFocusedArtwork: true)
    }

    private func checkDirectionalPortrait(
        width: CGFloat, checksSheen: Bool, count: Int? = nil, displayScale: CGFloat = 1,
        replacesFocusedArtwork: Bool = false
    ) async throws {
        // Fixed interpolation offsets cover motion effects, not the remote's
        // continuous touch input or UIFocusMovementHint interaction transform.
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let controller = LibraryFocusController()
        controller.view.backgroundColor = .black
        let size = CGSize(width: width, height: width * 1.5)
        let source = UIGraphicsImageRenderer(size: size).image {
            (count != nil ? UIColor.red : checksSheen ? UIColor(white: 0.35, alpha: 1) : .white).setFill()
            $0.fill(CGRect(origin: .zero, size: size))
            UIColor.red.setFill()
            for x: CGFloat in [0.14, 0.84] {
                $0.fill(CGRect(x: width * x, y: width * 0.4, width: width * 0.02, height: width * 0.4))
            }
        }
        let host = UIHostingController(rootView: SharedZoomFixture(
            image: source, aspect: 2 / 3,
            item: MediaItem(id: "tilt", title: "Tilt", kind: .series,
                            unwatchedEpisodeCount: count, isPlayed: count == nil)
        ).environment(\.plozzWatchStatusIndicator, .unwatched).environment(\.displayScale, displayScale))
        controller.addChild(host)
        controller.view.addSubview(host.view)
        host.didMove(toParent: controller)
        let container = try XCTUnwrap(host.view)
        container.backgroundColor = .clear
        container.frame = CGRect(origin: CGPoint(x: 700, y: 300), size: size)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        window.layoutIfNeeded()
        let poster = try XCTUnwrap(descendant(NativePosterButton.self, in: container))
        controller.target = poster
        let system = try XCTUnwrap(UIFocusSystem.focusSystem(for: window))
        system.requestFocusUpdate(to: controller)
        system.updateFocusIfNeeded()
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertTrue(poster.isFocused)
        if replacesFocusedArtwork {
            let before = poster.image
            let replacement = try XCTUnwrap(UIImage(data: XCTUnwrap(source.pngData())))
            host.rootView = SharedZoomFixture(
                image: replacement, aspect: 2 / 3,
                item: MediaItem(id: "tilt", title: "Tilt", kind: .series,
                                unwatchedEpisodeCount: count, isPlayed: count == nil)
            ).environment(\.plozzWatchStatusIndicator, .unwatched).environment(\.displayScale, displayScale)
            try await Task.sleep(for: .milliseconds(600))
            XCTAssertTrue(descendant(NativePosterButton.self, in: container) === poster)
            XCTAssertFalse(poster.image === before)
            XCTAssertTrue(poster.isFocused)
        }
        XCTAssertFalse(poster.artworkView.masksFocusEffectToContents)
        XCTAssertFalse(poster.indicatorView.adjustsImageWhenAncestorFocused)
        if count == nil {
            try assertCompositedArtworkGeometry(
                poster.artworkView, in: window, expectedScale: nil, landmarkTolerance: 1, maximumInternalScale: 1.02
            )
        }
        func motionViews(_ view: UIView) -> [(UIView, [UIMotionEffect])] {
            (view.motionEffects.isEmpty ? [] : [(view, view.motionEffects)])
                + view.subviews.flatMap(motionViews)
        }
        let effects = motionViews(container)
        XCTAssertFalse(effects.isEmpty)
        defer {
            for (view, original) in effects {
                for effect in view.motionEffects { view.removeMotionEffect(effect) }
                for effect in original { view.addMotionEffect(effect) }
            }
        }
        var centered: Data?
        var centeredCountSize: CGSize?
        var lighting: [String: [UInt8]] = [:]
        for (name, offset) in [
            ("center", UIOffset.zero),
            ("left", UIOffset(horizontal: -0.5, vertical: 0)),
            ("right", UIOffset(horizontal: 0.5, vertical: 0)),
            ("bottom-left", UIOffset(horizontal: -0.9, vertical: 0.9)),
            ("bottom-right", UIOffset(horizontal: 0.9, vertical: 0.9)),
            ("top-left", UIOffset(horizontal: -0.9, vertical: -0.9)),
            ("top-right", UIOffset(horizontal: 0.9, vertical: -0.9))
        ] {
            for (view, original) in effects {
                for effect in view.motionEffects { view.removeMotionEffect(effect) }
                for effect in original { view.addMotionEffect(FixedNativeViewerOffset(effect: effect, offset: offset)) }
            }
            try await Task.sleep(for: .milliseconds(300))
            let rendered = snapshot(window)
            if name == "center" {
                centered = try XCTUnwrap(rendered.pngData())
            } else {
                XCTAssertNotEqual(rendered.pngData(), centered, "Native directional motion must remain active.")
            }
            let bitmap = try XCTUnwrap(rendered.cgImage)
            let pixels = try rgba(bitmap)
            let frame = try XCTUnwrap(NativeFocusProjection.artworkFrame(of: poster.artworkView, in: window))
            var samples: [UInt8] = []
            for y: CGFloat in [0.2, 0.5, 0.8] {
                for x: CGFloat in [0.3, 0.5, 0.7] {
                    let row = Int(frame.minY + frame.height * y)
                    let column = Int(frame.minX + frame.width * x)
                    samples.append(pixels[(row * bitmap.width + column) * 4])
                }
            }
            lighting[name] = samples
            if count != nil {
                var minX = bitmap.width, maxX = 0, minY = bitmap.height, maxY = 0
                for y in Int(frame.minY) - 5..<Int(frame.minY) + 100 {
                    for x in Int(frame.maxX) - 140...Int(frame.maxX) + 5 {
                        let pixel = (y * bitmap.width + x) * 4
                        guard pixels[pixel...pixel + 2].allSatisfy({ $0 > 210 }) else { continue }
                        minX = min(minX, x)
                        maxX = max(maxX, x)
                        minY = min(minY, y)
                        maxY = max(maxY, y)
                    }
                }
                XCTAssertGreaterThan(maxX, minX, "Count digits must be visible at \(name).")
                XCTAssertGreaterThan(maxY, minY, "Count digits must be visible at \(name).")
                let digitSize = CGSize(width: maxX - minX, height: maxY - minY)
                if name == "center" {
                    centeredCountSize = digitSize
                } else {
                    let baseline = try XCTUnwrap(centeredCountSize)
                    XCTAssertEqual(digitSize.width, baseline.width, accuracy: 2, "Tilt must not clip digits at \(name).")
                    XCTAssertEqual(digitSize.height, baseline.height, accuracy: 2, "Tilt must not clip digits at \(name).")
                }
                if maxX > minX, maxY > minY {
                    for y in minY - 3...maxY + 3 {
                        for x in minX - 3...maxX + 3
                            where x == minX - 3 || x == maxX + 3 || y == minY - 3 || y == maxY + 3 {
                            XCTAssertLessThan(pixels[(y * bitmap.width + x) * 4], 130,
                                              "Digits need tile background on every side at \(name).")
                        }
                    }
                }
            } else if !checksSheen {
                var outside = 0
                for y in 2..<(bitmap.height - 2) {
                    for x in 2..<(bitmap.width - 2) {
                        let value = pixels[(y * bitmap.width + x) * 4]
                        guard value > 12, value <= 200 else { continue }
                        let nearArtwork = (-2...2).contains { dy in
                            (-2...2).contains { dx in
                                pixels[((y + dy) * bitmap.width + x + dx) * 4] > 200
                            }
                        }
                        if !nearArtwork { outside += 1 }
                    }
                }
                XCTAssertEqual(outside, 0, "The native highlight must not form a second edge at \(name).")
            }
            let attachment = XCTAttachment(image: rendered)
            attachment.name = "native-poster-\(Int(width))-\(count != nil ? "count" : checksSheen ? "gray" : "white")-\(name)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        if checksSheen {
            let left = try XCTUnwrap(lighting["left"])
            let right = try XCTUnwrap(lighting["right"])
            XCTAssertGreaterThan(Int(left[0]) - Int(left[2]), 4, "The sheen must brighten the touched left side.")
            XCTAssertGreaterThan(Int(right[2]) - Int(right[0]), 4, "The sheen must move to the touched right side.")
        }
    }

    private final class FixedNativeViewerOffset: UIMotionEffect {
        let effect: UIMotionEffect
        let offset: UIOffset

        init(effect: UIMotionEffect, offset: UIOffset) {
            self.effect = effect
            self.offset = offset
            super.init()
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func copy(with zone: NSZone? = nil) -> Any {
            FixedNativeViewerOffset(effect: effect, offset: offset)
        }

        override func keyPathsAndRelativeValues(forViewerOffset viewerOffset: UIOffset) -> [String: Any]? {
            effect.keyPathsAndRelativeValues(forViewerOffset: offset)
        }
    }

        func testPortraitArtworkLeavesCornerClippingToUIKit() async throws {
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .first { $0.activationState == .foregroundActive })
            let previous = scene.windows.first(where: \.isKeyWindow)
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
            let controller = LibraryFocusController()
            controller.view.backgroundColor = .black
            let image = UIGraphicsImageRenderer(size: CGSize(width: 280, height: 420)).image {
                UIColor.systemIndigo.setFill()
                $0.fill(CGRect(x: 0, y: 0, width: 280, height: 420))
            }
            let host = UIHostingController(rootView: SharedZoomFixture(
                image: image, aspect: 2 / 3,
                item: MediaItem(id: "native-corners", title: "Native corners", kind: .movie, isPlayed: true)
            ).environment(\.displayScale, 2).environment(\.plozzWatchStatusIndicator, .unwatched))
            controller.addChild(host)
            controller.view.addSubview(host.view)
            host.didMove(toParent: controller)
            host.view.backgroundColor = .clear
            host.view.frame = CGRect(x: 500, y: 200, width: 280, height: 420)
            let other = UIButton(type: .system)
            other.setTitle("Other", for: .normal)
            other.frame = CGRect(x: 100, y: 200, width: 200, height: 80)
            controller.view.addSubview(other)
            controller.target = other
            window.rootViewController = controller
            window.makeKeyAndVisible()
            defer {
                window.isHidden = true
                window.rootViewController = nil
                previous?.makeKeyAndVisible()
            }
            window.layoutIfNeeded()
            let poster = try XCTUnwrap(descendant(NativePosterButton.self, in: host.view))
            let artworkDeadline = ContinuousClock.now + .seconds(5)
            while ContinuousClock.now < artworkDeadline {
                let image = try XCTUnwrap(poster.image)
                if try pixel(image, at: CGPoint(x: image.size.width / 2, y: image.size.height / 2))[2] > 180 { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            let bitmap = try XCTUnwrap(poster.image)
            XCTAssertEqual(try pixel(bitmap, at: .zero)[3], 255)
            XCTAssertFalse(poster.artworkView.masksFocusEffectToContents)
            let system = try XCTUnwrap(UIFocusSystem.focusSystem(for: window))
            for (state, target) in [("rest", other), ("focus", poster), ("defocus", other)] {
                controller.target = target
                system.requestFocusUpdate(to: controller)
                system.updateFocusIfNeeded()
                try await Task.sleep(for: .milliseconds(600))
                XCTAssertTrue(system.focusedItem === target)
                XCTAssertTrue(poster.image === bitmap)
                let frame = try XCTUnwrap(NativeFocusProjection.artworkFrame(of: poster.artworkView, in: window))
                let rendered = snapshot(window)
                for x in [frame.minX + 1, frame.maxX - 2] {
                    for y in [frame.minY + 1, frame.maxY - 2] {
                        XCTAssertLessThan(try pixel(rendered, at: CGPoint(x: x, y: y))[2], 80,
                                          "UIKit must round opaque artwork at \(state), without a baked alpha cutout.")
                    }
                }
                XCTAssertGreaterThan(try pixel(rendered, at: CGPoint(x: frame.midX, y: frame.midY))[2], 180)
                let attachment = XCTAttachment(image: rendered)
                attachment.name = "native-opaque-indigo-\(state)"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
            let placeholder = NativePosterArtworkBitmap.placeholder(
                size: CGSize(width: 280, height: 420), scale: 2, clipsToArtwork: false
            )
            XCTAssertTrue([.none, .noneSkipFirst, .noneSkipLast].contains(try XCTUnwrap(placeholder.cgImage).alphaInfo))
            let masked = NativePosterArtworkBitmap.placeholder(size: CGSize(width: 280, height: 420), scale: 2)
            XCTAssertEqual(try pixel(masked, at: .zero)[3], 0)
        }

    private struct SharedZoomFixture: View {
        let image: UIImage
        let aspect: CGFloat
        var item = MediaItem(id: "shared", title: "Shared poster", kind: .series,
                             playedPercentage: 0.3, unwatchedEpisodeCount: 12)
        @PlozzCardFocus private var focus: Bool

        var body: some View {
            NativeTVPoster(
                image: image, treatment: .original, aspectRatio: aspect, fallbackWidth: 280,
                title: .content("Shared poster"), subtitle: nil,
                overlay: Color.clear,
                indicators: .media(MediaCardPlaybackIndicators(
                    item: item,
                    badgeInset: 8, progressHeight: 6, progressHorizontalInset: 16, progressBottomInset: 16).statusOnly),
                focus: $focus, action: {}
            )
            .focused($focus.focusState)
        }
    }

    func testPortraitCountKeepsEvenPaddingAtRestFocusAndReturn() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let image = try XCTUnwrap(UIImage(data: artworkData(.red)))
        defer { previous?.makeKeyAndVisible() }
        for (direction, width): (LayoutDirection, CGFloat) in [
            (.leftToRight, 220), (.leftToRight, 280), (.rightToLeft, 220), (.rightToLeft, 280)
        ] {
            for count in [8, 88, 12345] {
                let window = UIWindow(windowScene: scene)
                window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
                let controller = LibraryFocusController()
                controller.view.backgroundColor = .black
                let host = UIHostingController(rootView: SharedZoomFixture(
                    image: image, aspect: 2 / 3,
                    item: MediaItem(id: "count", title: "Count", kind: .series, unwatchedEpisodeCount: count)
                ).environment(\.plozzWatchStatusIndicator, .unwatched)
                    .environment(\.layoutDirection, direction))
                controller.addChild(host)
                controller.view.addSubview(host.view)
                host.didMove(toParent: controller)
                host.view.backgroundColor = .clear
                host.view.frame = CGRect(x: 500, y: 200, width: width, height: width * 1.5)
                let other = UIButton(type: .system)
                other.setTitle("Other", for: .normal)
                other.frame = CGRect(x: 100, y: 200, width: 200, height: 80)
                controller.view.addSubview(other)
                controller.target = other
                window.rootViewController = controller
                window.makeKeyAndVisible()
                defer {
                    window.isHidden = true
                    window.rootViewController = nil
                }
                window.layoutIfNeeded()
                let poster = try XCTUnwrap(descendant(NativePosterButton.self, in: host.view))
                let system = try XCTUnwrap(UIFocusSystem.focusSystem(for: window))
                for (state, target) in [("rest", other), ("focus", poster), ("defocus", other), ("refocus", poster)] {
                    controller.target = target
                    system.requestFocusUpdate(to: controller)
                    system.updateFocusIfNeeded()
                    try await Task.sleep(for: .milliseconds(600))
                    XCTAssertTrue(system.focusedItem === target)
                    try assertCountPadding(poster.artworkView, in: window, direction: direction,
                                           label: "\(state)-\(direction)-\(Int(width))-\(count)")
                    let settled = poster.image
                    for _ in 0..<10 {
                        poster.setNeedsLayout()
                        poster.layoutIfNeeded()
                    }
                    XCTAssertTrue(poster.image === settled, "Stable focus must reuse the image, not recompose every layout.")
                }
            }
        }
    }

    func testPortraitFocusAndDefocusRetainNativeIntermediateFrames() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let image = try XCTUnwrap(UIImage(data: artworkData(.red)))
        defer { previous?.makeKeyAndVisible() }
        for hasCount in [false, true] {
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
            let controller = LibraryFocusController()
            controller.view.backgroundColor = .black
            let host = UIHostingController(rootView: SharedZoomFixture(
                image: image, aspect: 2 / 3,
                item: MediaItem(id: "motion", title: "Motion", kind: .series,
                               unwatchedEpisodeCount: hasCount ? 88 : nil, isPlayed: !hasCount)
            ).environment(\.plozzWatchStatusIndicator, .unwatched))
            controller.addChild(host)
            controller.view.addSubview(host.view)
            host.didMove(toParent: controller)
            host.view.frame = CGRect(x: 500, y: 200, width: 280, height: 420)
            let other = UIButton(type: .system)
            other.setTitle("Other", for: .normal)
            other.frame = CGRect(x: 100, y: 200, width: 200, height: 80)
            controller.view.addSubview(other)
            controller.target = other
            window.rootViewController = controller
            window.makeKeyAndVisible()
            defer {
                window.isHidden = true
                window.rootViewController = nil
            }
            window.layoutIfNeeded()
            let poster = try XCTUnwrap(descendant(NativePosterButton.self, in: host.view))
            let system = try XCTUnwrap(UIFocusSystem.focusSystem(for: window))
            system.requestFocusUpdate(to: controller)
            system.updateFocusIfNeeded()
            try await Task.sleep(for: .milliseconds(600))
            func visibleArtworkLayers() -> [CALayer] {
                func imageLayers(_ layer: CALayer) -> [CALayer] {
                    guard layer !== poster.overlayView.layer else { return [] }
                    let state = layer.presentation() ?? layer
                    guard !state.isHidden, state.opacity > 0 else { return [] }
                    let matches = layer.contents != nil && abs(layer.bounds.width - 280) < 2
                        && abs(layer.bounds.height - 420) < 2
                    let frame = NativeFocusProjection.frame(of: layer, in: window.layer)
                    // The sheen has image contents too, but is projected square.
                    let artwork = matches && frame.map { abs($0.height / $0.width - 1.5) < 0.05 } == true
                    return (artwork ? [layer] : []) + (layer.sublayers ?? []).flatMap(imageLayers)
                }
                return imageLayers(poster.artworkView.layer)
            }
            func paintedWidth() throws -> CGFloat {
                try XCTUnwrap(visibleArtworkLayers().compactMap {
                    NativeFocusProjection.frame(of: $0, in: window.layer)?.width
                }.max())
            }
            func presentedImages() -> [CGImage] {
                visibleArtworkLayers().compactMap { layer -> CGImage? in
                    guard let contents = (layer.presentation() ?? layer).contents,
                          CFGetTypeID(contents as CFTypeRef) == CGImage.typeID else { return nil }
                    return (contents as! CGImage)
                }
            }
            func assertPresentedPixels(_ images: [CGImage], expected: [UInt8], label: String) throws {
                XCTAssertFalse(images.isEmpty)
                XCTAssertTrue(try images.contains { try rgba($0) == expected },
                              "Visible native artwork must update without waiting for animation completion: \(label)")
            }
            let restingPixels = try rgba(XCTUnwrap(poster.image?.cgImage))
            let restingImage = poster.image
            let indicatorImage = poster.indicatorView.image
            XCTAssertEqual(indicatorImage != nil, hasCount)
            for (state, target) in [("focus", poster), ("defocus", other), ("refocus", poster)] {
                let initial = try paintedWidth()
                controller.target = target
                system.requestFocusUpdate(to: controller)
                system.updateFocusIfNeeded()
                var samples: [CGFloat] = []
                var firstImage: CGImage?
                var firstPresentedImages: [CGImage] = []
                var firstIndicatorTransform = CGAffineTransform.identity
                var firstIndicatorCenter = CGPoint.zero
                for sample in 0..<20 {
                    try await Task.sleep(for: .milliseconds(20))
                    samples.append(try paintedWidth())
                    if sample == 0 {
                        firstImage = poster.image?.cgImage
                        firstPresentedImages = presentedImages()
                        firstIndicatorTransform = poster.indicatorView.transform
                        firstIndicatorCenter = poster.indicatorView.center
                    }
                }
                let pixels = try rgba(XCTUnwrap(firstImage))
                XCTAssertTrue(pixels == restingPixels, "Focus must not replace the artwork image: \(state)")
                try assertPresentedPixels(firstPresentedImages, expected: restingPixels, label: state)
                try await Task.sleep(for: .milliseconds(300))
                let final = try paintedWidth()
                if hasCount {
                    XCTAssertEqual(firstIndicatorTransform, poster.indicatorView.transform, "No delayed badge transform: \(state)")
                    XCTAssertEqual(firstIndicatorCenter, poster.indicatorView.center, "No delayed badge repositioning: \(state)")
                    if target === other {
                        XCTAssertEqual(firstIndicatorTransform, .identity)
                        XCTAssertEqual(firstIndicatorCenter, CGPoint(x: 140, y: 210))
                    }
                }
                XCTAssertTrue(poster.image === restingImage)
                XCTAssertTrue(poster.indicatorView.image === indicatorImage)
                XCTAssertTrue(system.focusedItem === target)
                XCTAssertGreaterThan(abs(final - initial), 10)
                let lower = min(initial, final) + 1
                let upper = max(initial, final) - 1
                XCTAssertGreaterThanOrEqual(samples.filter { $0 > lower && $0 < upper }.count, 3,
                                            "Native \(state) must animate, not snap; count=\(hasCount), \(initial) -> \(final): \(samples)")
                let attachment = XCTAttachment(string: "\(initial) -> \(final): \(samples)")
                attachment.name = "native-transition-\(hasCount)-\(state)"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
            for target in [other, poster, other, poster, other] {
                controller.target = target
                system.requestFocusUpdate(to: controller)
                system.updateFocusIfNeeded()
                try await Task.sleep(for: .milliseconds(40))
                poster.setNeedsLayout()
                poster.layoutIfNeeded()
                XCTAssertTrue(poster.image === restingImage)
                XCTAssertTrue(poster.indicatorView.image === indicatorImage)
                try assertPresentedPixels(presentedImages(), expected: restingPixels, label: "rapid reversal")
                if target === other {
                    XCTAssertEqual(poster.indicatorView.transform, .identity)
                }
            }
            try await Task.sleep(for: .milliseconds(600))
            XCTAssertTrue(system.focusedItem === other)
            XCTAssertTrue(try rgba(XCTUnwrap(poster.image?.cgImage)) == restingPixels)
            if hasCount {
                try assertCountPadding(poster.artworkView, in: window, label: "rapid-reversal-rest")
            }
        }
    }

    private func assertCountPadding(
        _ artwork: UIImageView, in window: UIWindow, direction: LayoutDirection = .leftToRight, label: String
    ) throws {
        let nativeFrame = try XCTUnwrap(NativeFocusProjection.artworkFrame(of: artwork, in: window))
        let rendered = snapshot(window)
        let bitmap = try XCTUnwrap(rendered.cgImage)
        let bytes = try rgba(bitmap)
        let frame = direction == .leftToRight ? nativeFrame : CGRect(
            x: CGFloat(bitmap.width) - nativeFrame.maxX, y: nativeFrame.minY,
            width: nativeFrame.width, height: nativeFrame.height
        )
        func pixelOffset(_ x: Int, _ y: Int) -> Int {
            let column = direction == .leftToRight ? x : bitmap.width - 1 - x
            return (y * bitmap.width + column) * 4
        }
        func red(_ x: Int, _ y: Int) -> UInt8 { bytes[pixelOffset(x, y)] }
        let top = try XCTUnwrap((Int(frame.minY) - 5..<Int(frame.midY)).first {
            red(Int(frame.midX), $0) > 180
        })
        let right = try XCTUnwrap((Int(frame.midX)...Int(frame.maxX) + 5).last {
            red($0, Int(frame.midY)) > 180
        })
        let left = try XCTUnwrap((right - 140..<right - 10).first { red($0, top + 10) < 130 })
        let bottom = try XCTUnwrap((top + 10..<top + 100).last { red(right - 10, $0) < 130 })
        var minX = right, maxX = left, minY = bottom, maxY = top
        for y in top...bottom {
            for x in left...right {
                let offset = pixelOffset(x, y)
                if bytes[offset...offset + 2].allSatisfy({ $0 > 210 }) {
                    minX = min(minX, x)
                    maxX = max(maxX, x)
                    minY = min(minY, y)
                    maxY = max(maxY, y)
                }
            }
        }
        XCTAssertGreaterThan(maxX, minX, "The complete count must remain visible: \(label)")
        // Preserve the two-point resting allowance when native focus projects it onto whole screen pixels.
        let paddingTolerance = ceil(2 * nativeFrame.width / artwork.bounds.width)
        XCTAssertEqual(CGFloat(minX - left), CGFloat(right - maxX), accuracy: paddingTolerance, "Trailing padding: \(label)")
        XCTAssertEqual(CGFloat(minY - top), CGFloat(bottom - maxY), accuracy: paddingTolerance, "Top padding: \(label)")
        let attachment = XCTAttachment(image: rendered)
        attachment.name = "native-count-\(label)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testSharedPosterCornerFlagStaysInsidePaintedArtworkOnFocus() async throws {
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
        let image = try XCTUnwrap(UIImage(data: artworkData(.red)))
        for aspect: CGFloat in [2 / 3, 16 / 9] {
            let controller = LibraryFocusController()
            controller.view.backgroundColor = .black
            let host = UIHostingController(rootView:
                SharedZoomFixture(
                    image: image, aspect: aspect,
                    item: MediaItem(id: "unwatched", title: "Unwatched movie", kind: .movie)
                )
                .environment(\.plozzWatchStatusIndicator, .unwatched)
            )
            controller.addChild(host)
            controller.view.addSubview(host.view)
            host.didMove(toParent: controller)
            host.view.backgroundColor = .clear
            host.view.frame = CGRect(x: 400, y: 200, width: 280, height: 280 / aspect)
            window.rootViewController = controller
            window.makeKeyAndVisible()
            window.layoutIfNeeded()
            let poster = try XCTUnwrap(descendant(NativePosterButton.self, in: host.view))
            controller.target = poster
            let system = try XCTUnwrap(UIFocusSystem.focusSystem(for: window))
            system.requestFocusUpdate(to: controller)
            system.updateFocusIfNeeded()
            try await Task.sleep(for: .milliseconds(500))
            XCTAssertTrue(system.focusedItem === poster)
            try assertAttachedCornerFlag(poster, in: window, name: "shared-focused-corner-flag-\(aspect)")
        }
    }

    private func assertAttachedCornerFlag(_ poster: NativePosterButton, in window: UIWindow, name: String) throws {
        let frame = try XCTUnwrap(NativeFocusProjection.artworkFrame(of: poster.artworkView, in: window))
        let rendered = snapshot(window)
        let attachment = XCTAttachment(image: rendered)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let bitmap = try XCTUnwrap(rendered.cgImage)
        let bytes = try rgba(bitmap)
        func components(_ x: Int, _ y: Int) -> ArraySlice<UInt8> {
            let offset = (y * bitmap.width + x) * 4
            return bytes[offset..<(offset + 3)]
        }
        let top = try XCTUnwrap((Int(frame.minY) - 16..<Int(frame.midY)).first {
            let p = components(Int(frame.midX), $0)
            return p[p.startIndex] > 150 && p.dropFirst().allSatisfy { $0 < 120 }
        })
        let right = try XCTUnwrap((Int(frame.midX)...Int(frame.maxX) + 16).last {
            let p = components($0, Int(frame.midY))
            return p[p.startIndex] > 150 && p.dropFirst().allSatisfy { $0 < 120 }
        })
        var flagPixels = 0
        var whitePixels = 0
        var outsidePixels = 0
        for y in Int(frame.minY) - 16..<Int(frame.minY) + 80 {
            for x in Int(frame.maxX) - 80...Int(frame.maxX) + 16 {
                guard components(x, y).allSatisfy({ $0 > 180 }) else { continue }
                flagPixels += 1
                if components(x, y).allSatisfy({ $0 >= 250 }) { whitePixels += 1 }
                if y < top - 1 || x > right + 1 { outsidePixels += 1 }
            }
        }
        XCTAssertGreaterThan(flagPixels, 100, "The actual unwatched flag must be visible.")
        XCTAssertGreaterThan(whitePixels, 100, "The focused flag must be white, not a translucent gray.")
        XCTAssertEqual(outsidePixels, 0, "The indicator must not lift beyond the painted artwork's top/right edges.")
    }

    func testHomePosterUpdatesAttachedStatusWithoutReplacingFocus() async throws {
        let server = try LibraryArtworkServer(images: ["artwork": artworkData(.red)])
        defer { server.stop() }
        let port = try await server.start()
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/artwork/\(UUID())"))
        let model = AttachedStatusModel(item: MediaItem(
            id: "status", title: "Status", kind: .series, unwatchedEpisodeCount: 21,
            posterURL: url, allowsTitleBasedMetadataMatching: false
        ))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let controller = LibraryFocusController()
        controller.view.backgroundColor = .black
        let host = UIHostingController(rootView: AttachedStatusFixture(model: model))
        controller.addChild(host)
        controller.view.addSubview(host.view)
        host.didMove(toParent: controller)
        host.view.frame = CGRect(x: 400, y: 200, width: 300, height: 550)
        host.view.backgroundColor = .clear
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        window.layoutIfNeeded()
        let poster = try XCTUnwrap(descendant(NativePosterButton.self, in: host.view))
        controller.target = poster
        let system = try XCTUnwrap(UIFocusSystem.focusSystem(for: window))
        system.requestFocusUpdate(to: controller)
        system.updateFocusIfNeeded()
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if let image = poster.image, let bitmap = image.cgImage,
               try isRed(image, at: CGPoint(x: bitmap.width / 2, y: bitmap.height / 2)) { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        let loaded = try XCTUnwrap(poster.image)
        let bitmap = try XCTUnwrap(loaded.cgImage)
        XCTAssertTrue(try isRed(loaded, at: CGPoint(x: bitmap.width / 2, y: bitmap.height / 2)))
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertTrue(system.focusedItem === poster)
        let first = try XCTUnwrap(loaded.pngData())
        for change in 0..<4 {
            let before = try XCTUnwrap(poster.image)
            let beforePixels = try XCTUnwrap(before.pngData())
            let beforeForeground = poster.indicatorView.image
            let beforeForegroundPixels = beforeForeground?.pngData()
            switch change {
            case 0: model.item.unwatchedEpisodeCount = 12345
            case 1: model.showsCount = false
            case 2:
                model.indicator = .watched
                model.item.isPlayed = true
            default: model.item.isPlayed = false
            }
            let changeDeadline = ContinuousClock.now + .seconds(3)
            while poster.image?.pngData() == beforePixels
                && poster.indicatorView.image?.pngData() == beforeForegroundPixels
                && ContinuousClock.now < changeDeadline {
                try await Task.sleep(for: .milliseconds(30))
            }
            XCTAssertTrue(poster.image !== before || poster.indicatorView.image !== beforeForeground,
                          "Watch/count/preference changes must replace the affected pixels.")
            XCTAssertTrue(poster.image?.pngData() != beforePixels
                          || poster.indicatorView.image?.pngData() != beforeForegroundPixels,
                          "Status transition \(change) must repaint.")
            XCTAssertTrue(descendant(NativePosterButton.self, in: host.view) === poster)
            XCTAssertTrue(system.focusedItem === poster)
            if change == 1 {
                try assertAttachedCornerFlag(poster, in: window, name: "home-focused-corner-flag")
            }
        }
        XCTAssertNotEqual(poster.image?.pngData(), first)
        let attachment = XCTAttachment(image: snapshot(window))
        attachment.name = "home-poster-live-attached-status"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @Observable final class AttachedStatusModel {
        var item: MediaItem
        var showsCount = true
        var indicator = WatchStatusIndicator.unwatched
        init(item: MediaItem) { self.item = item }
    }

    private struct AttachedStatusFixture: View {
        let model: AttachedStatusModel
        var body: some View {
            PosterCardView(item: model.item, enablesAsyncArtworkFallback: false, action: {})
                .environment(\.plozzCardStyle, .borderless)
                .environment(\.plozzCardFocusStyle, .system)
                .environment(\.plozzWatchStatusIndicator, model.indicator)
                .environment(\.plozzShowsUnwatchedEpisodeCount, model.showsCount)
        }
    }

    func testLibraryPosterCompositionNeverDrawsPlaceholderOverLoadedArtwork() async throws {
        var environment = EnvironmentValues()
        environment.themePalette = .dark
        environment.colorScheme = .dark
        let size = CGSize(width: 280, height: 420)
        for style in [WatchStatusIndicator.watched, .unwatched] {
            environment.plozzWatchStatusIndicator = style
            for kind in [MediaItemKind.movie, .series] {
                for played in [false, true] {
                    let item = MediaItem(
                        id: UUID().uuidString, title: "Poster", kind: kind,
                        unwatchedEpisodeCount: kind == .series && !played ? 12 : nil,
                        isPlayed: played
                    )
                    let presentation = NativeLibraryPosterBitmap.Presentation(
                        item: item, spoilerSettings: .default, environment: environment
                    )
                    let placeholder = await NativeLibraryPosterBitmap.composite(
                        source: nil, key: .init(image: nil, presentation: presentation, size: size, scale: 2),
                        environment: environment
                    )
                    let missingArtwork = try XCTUnwrap(placeholder)
                    let placeholderRegion = CGRect(x: 80, y: 120, width: 120, height: 180)
                        .applying(CGAffineTransform(scaleX: missingArtwork.scale, y: missingArtwork.scale))
                    let placeholderPixels = try rgba(XCTUnwrap(missingArtwork.cgImage?.cropping(to: placeholderRegion)))
                    let placeholderLevels = stride(from: 0, to: placeholderPixels.count, by: 4).map {
                        placeholderPixels[$0]
                    }
                    XCTAssertGreaterThan(Set(placeholderLevels).count, 1, "Missing artwork must retain its placeholder glyph.")
                    let source = try XCTUnwrap(UIImage(data: artworkData(.blue)))
                    let result = await NativeLibraryPosterBitmap.composite(
                        source: source, key: .init(image: source, presentation: presentation, size: size, scale: 2),
                        environment: environment
                    )
                    let image = try XCTUnwrap(result)
                    let region = CGRect(x: 80, y: 120, width: 120, height: 180)
                        .applying(CGAffineTransform(scaleX: image.scale, y: image.scale))
                    let pixels = try rgba(XCTUnwrap(image.cgImage?.cropping(to: region)))
                    let unexpected = stride(from: 0, to: pixels.count, by: 4).filter {
                        pixels[$0] > 5 || pixels[$0 + 1] > 5 || pixels[$0 + 2] < 250 || pixels[$0 + 3] != 255
                    }.count
                    if unexpected > 0 {
                        let attachment = XCTAttachment(image: image)
                        attachment.name = "loaded-poster-\(style)-\(kind)-\(played)"
                        attachment.lifetime = .keepAlways
                        add(attachment)
                    }
                    XCTAssertEqual(unexpected, 0, "\(style), \(kind), played=\(played): loaded artwork must have no placeholder glyph or wash.")
                }
            }
        }
    }

    func testCompositedLibraryBitmapUsesLivePresentationAndBoundsStorage() throws {
        var environment = EnvironmentValues()
        environment.themePalette = .dark
        environment.colorScheme = .dark
        environment.plozzWatchStatusIndicator = .unwatched
        environment.plozzShowsUnwatchedEpisodeCount = true
        var item = MediaItem(id: "composite", title: "Series", kind: .series, unwatchedEpisodeCount: 12)
        let image = try XCTUnwrap(UIImage(data: artworkData(.blue)))
        let size = CGSize(width: 280, height: 420)
        func render() throws -> UIImage {
            try XCTUnwrap(NativeLibraryPosterBitmap.image(
                source: image,
                key: .init(
                    image: image, presentation: .init(item: item, spoilerSettings: .default, environment: environment),
                    size: size, scale: 2
                ), environment: environment
            ))
        }
        func foreground() throws -> UIImage {
            try XCTUnwrap(NativeLibraryPosterBitmap.overlay(
                key: .init(
                    image: image, presentation: .init(item: item, spoilerSettings: .default, environment: environment),
                    size: size, scale: 2
                ), environment: environment
            )?.image)
        }
        let first = try render()
        let firstForeground = try foreground()
        XCTAssertLessThan(try XCTUnwrap(pixel(first, at: CGPoint(x: 250 * first.scale, y: 10 * first.scale)).prefix(3).max()), 100,
                          "The corrected poster must include main's charcoal episode-count tile.")
        let count = NativeLibraryPosterBitmap.renderCount
        XCTAssertTrue(first === (try render()))
        XCTAssertEqual(NativeLibraryPosterBitmap.renderCount, count)
        XCTAssertEqual(try rgba(XCTUnwrap(first.cgImage))[3], 255, "UIKit alone must own native portrait corners.")
        item.unwatchedEpisodeCount = 11
        let changed = try render()
        XCTAssertEqual(first.pngData(), changed.pngData(), "Count digits belong to the aligned foreground.")
        XCTAssertNotEqual(firstForeground.pngData(), try foreground().pngData())
        environment.plozzShowsUnwatchedEpisodeCount = false
        XCTAssertNotEqual(changed.pngData(), try render().pngData())
        environment.plozzWatchStatusIndicator = .watched
        item.isPlayed = true
        XCTAssertNotEqual(changed.pngData(), try render().pngData())
        for index in 1...40 {
            item.unwatchedEpisodeCount = index
            _ = try render()
            XCTAssertLessThanOrEqual(NativeLibraryPosterBitmap.retainedBytes, NativeLibraryPosterBitmap.byteLimit)
        }
    }

    func testCompositedLibraryBitmapsStayResidentWhenTheGridReturns() throws {
        // Devices under 3 GB keep the small budget, which never held a returning grid.
        guard NativeLibraryPosterBitmap.countLimit >= 42,
              NativeLibraryPosterBitmap.byteLimit >= 42 * 520 * 780 * 4 else {
            throw XCTSkip("This device keeps the small artwork budget.")
        }
        var environment = EnvironmentValues()
        environment.themePalette = .dark
        environment.colorScheme = .dark
        // Seven six-column rows at Apple TV 4K's 2x: a 6 Down + 6 Up Browse traversal.
        let size = CGSize(width: 260, height: 390)
        let posters = try (0..<42).map { index in
            (item: MediaItem(id: "grid-\(index)", title: "Movie \(index)", kind: .movie),
             image: try XCTUnwrap(UIImage(data: artworkData(.blue))))
        }
        func renderGrid() throws {
            for poster in posters {
                let key = NativeLibraryPosterBitmap.Key(
                    image: poster.image,
                    presentation: .init(item: poster.item, spoilerSettings: .default, environment: environment),
                    size: size, scale: 2
                )
                _ = try XCTUnwrap(NativeLibraryPosterBitmap.image(source: poster.image, key: key, environment: environment))
            }
        }
        try renderGrid()
        let rendered = NativeLibraryPosterBitmap.renderCount
        try renderGrid()
        XCTAssertEqual(NativeLibraryPosterBitmap.renderCount, rendered, "Returning rows must reuse their composites.")
        XCTAssertLessThanOrEqual(NativeLibraryPosterBitmap.retainedBytes, NativeLibraryPosterBitmap.byteLimit)
    }

    func testCompositedRealLibraryCellKeepsFocusDuringContentChanges() async throws {
        try await checkCompositedLibraryCell(cardStyle: .borderless)
    }

    func testBrowseCountKeepsEvenPaddingAndUpdatesImmediatelyOnDefocus() async throws {
        let server = try LibraryArtworkServer(images: ["red": artworkData(.red)])
        defer { server.stop() }
        let port = try await server.start()
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/red/\(UUID())"))
        _ = await ArtworkImageCache.shared.image(for: url, variant: .posterCard)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        defer { previous?.makeKeyAndVisible() }
        for direction: LayoutDirection in [.leftToRight, .rightToLeft] {
            var environment = EnvironmentValues()
            environment.plozzCardStyle = .borderless
            environment.plozzCardFocusStyle = .system
            environment.plozzWatchStatusIndicator = .unwatched
            environment.plozzShowsUnwatchedEpisodeCount = true
            environment.layoutDirection = direction
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
            let controller = LibraryFocusController()
            controller.view.backgroundColor = .black
            let cell = NativeTVLibraryCell(frame: CGRect(
                x: 500, y: 200, width: 280, height: NativeTVLibraryCell.height(for: 280, environment: environment)
            ))
            controller.view.addSubview(cell)
            let other = UIButton(type: .system)
            other.setTitle("Other", for: .normal)
            other.frame = CGRect(x: 100, y: 200, width: 200, height: 80)
            controller.view.addSubview(other)
            controller.target = other
            window.rootViewController = controller
            window.makeKeyAndVisible()
            defer {
                cell.prepareForReuse()
                window.isHidden = true
                window.rootViewController = nil
            }
            cell.configure(
                item: MediaItem(id: "show", title: "Show", kind: .series, unwatchedEpisodeCount: 88, posterURL: url),
                spoilerSettings: .default, environment: environment
            )
            window.layoutIfNeeded()
            let artwork = try XCTUnwrap(cell.subviews.compactMap { $0 as? NativePosterImageView }.first)
            let system = try XCTUnwrap(UIFocusSystem.focusSystem(for: window))
            system.requestFocusUpdate(to: controller)
            system.updateFocusIfNeeded()
            try await Task.sleep(for: .milliseconds(600))
            let image = artwork.image
            let foreground = artwork.indicatorView.image
            let restingTransform = artwork.indicatorView.transform
            try assertCountPadding(artwork, in: window, direction: direction, label: "browse-rest-\(direction)")
            controller.target = cell
            system.requestFocusUpdate(to: controller)
            system.updateFocusIfNeeded()
            XCTAssertTrue(system.focusedItem === cell)
            try await Task.sleep(for: .milliseconds(600))
            try assertCountPadding(artwork, in: window, direction: direction, label: "browse-focus-\(direction)")
            controller.target = other
            system.requestFocusUpdate(to: controller)
            system.updateFocusIfNeeded()
            XCTAssertTrue(system.focusedItem === other)
            XCTAssertEqual(artwork.indicatorView.transform, restingTransform, "The destination must update at defocus, not after it.")
            XCTAssertTrue(artwork.image === image)
            XCTAssertTrue(artwork.indicatorView.image === foreground)
            try await Task.sleep(for: .milliseconds(600))
            try assertCountPadding(artwork, in: window, direction: direction, label: "browse-return-\(direction)")
        }
    }

    func testFramedLibraryCellKeepsCorrectedArtworkAndNativeFocus() async throws {
        try await checkCompositedLibraryCell(cardStyle: .framed)
    }

    func testFractionalLibraryCellsMatchTheirRetinaArtworkBounds() async throws {
        for style: CardStyle in [.borderless, .framed] {
            try await checkCompositedLibraryCell(cardStyle: style, width: 280.25, displayScale: 2)
        }
    }

    private func checkCompositedLibraryCell(
        cardStyle: CardStyle, width: CGFloat = 280, displayScale: CGFloat? = nil
    ) async throws {
        let markedArtwork = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 150)).image { context in
            UIColor.darkGray.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 100, height: 150))
            UIColor.red.setFill()
            context.fill(CGRect(x: 12, y: 40, width: 6, height: 50))
            context.fill(CGRect(x: 82, y: 40, width: 6, height: 50))
        }
        let server = try LibraryArtworkServer(images: [
            "first": XCTUnwrap(markedArtwork.pngData()), "second": artworkData(.blue)
        ])
        defer { server.stop() }
        let port = try await server.start()
        let token = UUID().uuidString
        let firstURL = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/first/\(token)"))
        let secondURL = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/second/\(token)"))
        _ = await ArtworkImageCache.shared.image(for: firstURL, variant: .posterCard)
        var item = MediaItem(id: token, title: "Library series", kind: .series, unwatchedEpisodeCount: 12, posterURL: firstURL)
        var environment = EnvironmentValues()
        environment.themePalette = .dark
        environment.colorScheme = .dark
        environment.plozzCardStyle = cardStyle
        environment.plozzCardFocusStyle = .system
        if let displayScale { environment.displayScale = displayScale }
        XCTAssertTrue(environment.compositedLibraryPosters, "Normal app launches must use the zoom correction.")
        environment.plozzShowsUnwatchedEpisodeCount = true
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let controller = LibraryFocusController()
        if let displayScale { controller.traitOverrides.displayScale = displayScale }
        controller.view.backgroundColor = .black
        let cell = NativeTVLibraryCell(frame: CGRect(
            x: 400, y: 200, width: width, height: NativeTVLibraryCell.height(for: width, environment: environment)
        ))
        controller.view.addSubview(cell)
        controller.target = cell
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            cell.prepareForReuse()
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        func update() {
            cell.configure(item: item, spoilerSettings: .default, environment: environment)
            cell.updateConfiguration(using: cell.configurationState)
            window.layoutIfNeeded()
        }
        update()
        let imageView = try XCTUnwrap(cell.subviews.compactMap { $0 as? NativePosterImageView }.first)
        // A cache miss composites off the main thread; the decoded artwork stands in until then.
        var before = try XCTUnwrap(imageView.image)
        let compositeDeadline = Date().addingTimeInterval(2)
        while before.size != imageView.bounds.size, Date() < compositeDeadline {
            try await Task.sleep(for: .milliseconds(20))
            before = try XCTUnwrap(imageView.image)
        }
        let beforeForeground = try XCTUnwrap(imageView.indicatorView.image)
        XCTAssertFalse(imageView.masksFocusEffectToContents, "Browse and rows must share the same native focus surface.")
        XCTAssertEqual(try rgba(XCTUnwrap(before.cgImage))[3], 255)
        XCTAssertEqual(before.size, imageView.bounds.size)
        if let displayScale { XCTAssertEqual(before.scale, displayScale) }
        let system = try XCTUnwrap(UIFocusSystem.focusSystem(for: window))
        system.requestFocusUpdate(to: controller)
        system.updateFocusIfNeeded()
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertTrue(system.focusedItem === cell)
        try assertCompositedArtworkGeometry(
            imageView, in: window,
            cornerBackground: cardStyle == .framed ? UIColor(environment.themePalette.raised.fill) : .black,
            maximumInternalScale: 1.02
        )
        let renderCount = NativeLibraryPosterBitmap.renderCount
        for _ in 0..<3 {
            cell.updateConfiguration(using: cell.configurationState)
            cell.setNeedsLayout()
            window.layoutIfNeeded()
        }
        XCTAssertEqual(NativeLibraryPosterBitmap.renderCount, renderCount, "Focus/configuration passes must not composite.")
        item.unwatchedEpisodeCount = 11
        update()
        XCTAssertTrue(system.focusedItem === cell)
        XCTAssertNotEqual(beforeForeground.pngData(), imageView.indicatorView.image?.pngData())
        item.posterURL = secondURL
        update()
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
            window.layoutIfNeeded()
            if let image = imageView.image, try pixel(image, at: CGPoint(x: 100, y: 180))[2] > 150 { break }
        }
        XCTAssertTrue(system.focusedItem === cell, "Async artwork must update without replacing the focused cell.")
        XCTAssertTrue(imageView.superview === cell)
        XCTAssertGreaterThan(try pixel(XCTUnwrap(imageView.image), at: CGPoint(x: 100, y: 180))[2], 150)
        let attachment = XCTAttachment(image: snapshot(window))
        attachment.name = "real-library-cell-composited-focus"
        attachment.lifetime = .keepAlways
        add(attachment)
        environment.compositedLibraryPosters = false
        update()
        let nativeArtwork = try XCTUnwrap(descendant(TVMediaItemContentView.self, in: cell))
        XCTAssertTrue(nativeArtwork.superview === cell)
        XCTAssertFalse(nativeArtwork.isHidden)
        XCTAssertNil(imageView.superview)
        XCTAssertTrue(system.focusedItem === cell)
        environment.compositedLibraryPosters = true
        update()
        XCTAssertTrue(nativeArtwork.isHidden)
        XCTAssertNil((nativeArtwork.configuration as? TVMediaItemContentConfiguration)?.image)
        XCTAssertTrue(imageView.superview === cell)
        XCTAssertTrue(system.focusedItem === cell)
        cell.prepareForReuse()
        XCTAssertNil(imageView.image, "Reusable cells must release their composed pixels.")
        XCTAssertNil(imageView.indicatorView.image, "Reusable cells must release their indicator foreground.")
    }

    private func assertCompositedArtworkGeometry(
        _ imageView: UIImageView, in window: UIWindow, expectedScale: CGFloat? = 1.1,
        cornerBackground: UIColor = .black, landmarkTolerance: CGFloat = 3, maximumInternalScale: CGFloat = 1
    ) throws {
        let source = try XCTUnwrap(imageView.image)
        let frame = try XCTUnwrap(NativeFocusProjection.artworkFrame(of: imageView, in: window))
        let rendered = snapshot(window)
        if let expectedScale {
            XCTAssertEqual(frame.width, imageView.bounds.width * expectedScale, accuracy: 3)
            XCTAssertEqual(frame.height, imageView.bounds.height * expectedScale, accuracy: 3)
        } else {
            // UIImageView's native enlargement varies with artwork dimensions.
            XCTAssertGreaterThan(frame.width, imageView.bounds.width)
            XCTAssertGreaterThan(frame.height, imageView.bounds.height)
            XCTAssertEqual(frame.width / frame.height,
                           imageView.bounds.width / imageView.bounds.height, accuracy: 0.01)
        }
        func markerSpan(_ image: UIImage, frame: CGRect) throws -> CGFloat {
            let bitmap = try XCTUnwrap(image.cgImage)
            let bytes = try rgba(bitmap)
            var minimum = bitmap.width, maximum = -1
            for y in Int((frame.minY + frame.height * 0.25) * image.scale)..<Int((frame.minY + frame.height * 0.65) * image.scale) {
                for x in Int(frame.minX * image.scale)..<Int(frame.maxX * image.scale) {
                    let offset = (y * bitmap.width + x) * 4
                    if bytes[offset] > 180 && bytes[offset + 1] < 125 && bytes[offset + 2] < 125 {
                        minimum = min(minimum, x)
                        maximum = max(maximum, x)
                    }
                }
            }
            XCTAssertGreaterThan(maximum, minimum, "The source landmarks must remain visible.")
            return CGFloat(maximum - minimum + 1) / image.scale
        }
        let sourceSpan = try markerSpan(source, frame: CGRect(origin: .zero, size: source.size))
        let expectedSpan = sourceSpan * frame.width / source.size.width
        let actualSpan = try markerSpan(rendered, frame: frame)
        // Inclusive pixel spans incur rounding at both the source and final rasterization.
        let spanRounding = frame.width / source.size.width / source.scale + 1 / rendered.scale
        let tolerance = max(landmarkTolerance, spanRounding)
        if maximumInternalScale > 1 {
            XCTAssertGreaterThanOrEqual(actualSpan, expectedSpan - tolerance)
            XCTAssertLessThanOrEqual(actualSpan, expectedSpan * maximumInternalScale + tolerance,
                                     "Only the approved small native crop is allowed.")
        } else {
            XCTAssertEqual(actualSpan, expectedSpan, accuracy: tolerance,
                           "Painted landmarks must enlarge with the card, without additional internal zoom.")
        }
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        XCTAssertTrue(cornerBackground.getRed(&red, green: &green, blue: &blue, alpha: &alpha))
        let cornerLimit = max(red, green, blue) * 255 + 12
        for point in [
            CGPoint(x: frame.minX + 2, y: frame.minY + 2), CGPoint(x: frame.maxX - 2, y: frame.minY + 2),
            CGPoint(x: frame.minX + 2, y: frame.maxY - 2), CGPoint(x: frame.maxX - 2, y: frame.maxY - 2)
        ] {
            XCTAssertLessThan(CGFloat(try XCTUnwrap(pixel(rendered, at: point).prefix(3).max())), cornerLimit,
                              "The native highlight must respect every rounded corner.")
        }
        for point in [
            CGPoint(x: frame.minX + 4, y: frame.midY), CGPoint(x: frame.maxX - 4, y: frame.midY),
            CGPoint(x: frame.midX, y: frame.minY + 4), CGPoint(x: frame.midX, y: frame.maxY - 4)
        ] {
            XCTAssertGreaterThan(try XCTUnwrap(pixel(rendered, at: point).prefix(3).max()), 20,
                                 "The enlarged artwork must not be clipped to its resting bounds.")
        }
    }

    func testNativeBrowseKeepsProviderPreferenceDuringSlowArtworkDownload() async throws {
        try await checkNativeBrowseArtwork(onlineDelay: 1)
    }

    func testSwiftUIBrowseKeepsProviderPreferenceDuringQueuedLookup() async throws {
        try await checkSwiftUIBrowseArtwork(cancelLookup: false)
    }

    func testLeavingSwiftUIBrowseDoesNotPaintCachedLibraryArtworkAfterCancellation() async throws {
        try await checkSwiftUIBrowseArtwork(cancelLookup: true)
    }

    func testCustomFocusLibraryBrowseHonorsConflictingArtworkPreferences() async throws {
        let server = try LibraryArtworkServer(images: [
            "library": artworkData(.red), "online": artworkData(.green)
        ])
        defer { server.stop() }
        let port = try await server.start()
        for focusStyle in [CardFocusStyle.highlight, .outlined] {
            let token = UUID().uuidString
            let library = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/library/\(token)"))
            let online = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/online/\(token)"))
            let item = MediaItem(id: token, title: token, kind: .movie, posterURL: library)
            _ = await ArtworkImageCache.shared.image(for: library, variant: .posterCard)
            _ = await ArtworkImageCache.shared.image(for: online, variant: .posterCard)
            try await withCustomFocusBrowse(item: item, online: online, focusStyle: focusStyle) { window, model, preferences in
                for preference in [ArtworkPreference.online, .library, .online] {
                    preferences.artwork = .init(
                        preference: preference == .online ? .library : .online,
                        overrides: [.browse: preference]
                    )
                    try await self.assertBrowseArtwork(
                        in: window, isOnline: preference == .online,
                        name: "real-browse-\(focusStyle)-\(preference)"
                    )
                    XCTAssertEqual(model.item(at: 0), item, "Changing artwork preference must not replace the title.")
                    XCTAssertNil(self.descendant(NativeTVLibraryCell.self, in: window),
                                 "This regression must exercise LibraryGridCell, not the native grid.")
                }
            }
        }
    }

    func testCustomFocusLibraryBrowseFallsBackForMissingOrFailedArtwork() async throws {
        let server = try LibraryArtworkServer(images: [
            "library": artworkData(.red), "online": artworkData(.green),
            "invalid": Data("not an image".utf8)
        ])
        defer { server.stop() }
        let port = try await server.start()
        let cases: [(name: String, library: String?, online: String, preference: ArtworkPreference, isOnline: Bool)] = [
            ("missing-library", nil, "online", .library, true),
            ("failed-library", "missing", "online", .library, true),
            ("failed-online", "library", "missing", .online, false),
            ("invalid-online", "library", "invalid", .online, false)
        ]
        for focusStyle in [CardFocusStyle.highlight, .outlined] {
            for fixture in cases {
                let token = UUID().uuidString
                let library = try fixture.library.map {
                    try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/\($0)/\(token)"))
                }
                let online = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/\(fixture.online)/\(token)"))
                let item = MediaItem(id: token, title: token, kind: .movie, posterURL: library)
                try await withCustomFocusBrowse(
                    item: item, online: online, focusStyle: focusStyle,
                    artwork: .init(
                        preference: fixture.preference == .online ? .library : .online,
                        overrides: [.browse: fixture.preference]
                    )
                ) { window, _, _ in
                    try await self.assertBrowseArtwork(
                        in: window, isOnline: fixture.isOnline,
                        name: "real-browse-\(focusStyle)-\(fixture.name)"
                    )
                    if fixture.preference == .online {
                        XCTAssertGreaterThan(server.requestCount(for: online.path), 0,
                                             "The real grid must attempt the preferred provider image before falling back.")
                    }
                }
            }
        }
    }

    private func withCustomFocusBrowse(
        item: MediaItem,
        online: URL,
        focusStyle: CardFocusStyle,
        artwork: ArtworkSettings = .init(preference: .library, overrides: [.browse: .online]),
        body: (UIWindow, LibraryBrowseViewModel, BrowseArtworkHostedPreferences) async throws -> Void
    ) async throws {
        let providerSettings = MetadataProviderSettingsStore()
        let previousProviders = providerSettings.load()
        providerSettings.save(.default)
        defer { providerSettings.save(previousProviders) }
        let query = MetadataQuery(item)
        for provider in MetadataEnrichmentConfig.defaultBaseOrder {
            await MetadataDiskCache.shared.store(
                online, for: "\(query.cacheKey(for: .poster))|provider:\(provider.rawValue)"
            )
        }
        let suite = "CustomFocusBrowseArtwork.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = LibraryBrowseViewModel(
            provider: BrowseArtworkHostedProvider(mediaItem: item),
            containerID: "library", containerKind: .movie,
            defaults: defaults, initialContentMode: .titles
        )
        await model.loadFirstPage()
        let preferences = BrowseArtworkHostedPreferences(artwork: artwork)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let host = UIHostingController(rootView: BrowseArtworkHostedPage(
            model: model, focusStyle: focusStyle, preferences: preferences
        ))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKeyAndVisible()
        }
        try await body(window, model, preferences)
    }

    private func assertBrowseArtwork(in window: UIWindow, isOnline: Bool, name: String) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        var selectedPixels = 0
        var rejectedPixels = 0
        var image: UIImage?
        repeat {
            try await Task.sleep(for: .milliseconds(100))
            window.layoutIfNeeded()
            let rendered = snapshot(window)
            image = rendered
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.preferredRange = .standard
            let sample = UIGraphicsImageRenderer(size: CGSize(width: 192, height: 108), format: format).image { _ in
                rendered.draw(in: CGRect(x: 0, y: 0, width: 192, height: 108))
            }
            let pixels = try rgba(XCTUnwrap(sample.cgImage))
            let red = stride(from: 0, to: pixels.count, by: 4).filter {
                pixels[$0] > 180 && pixels[$0 + 1] < 80 && pixels[$0 + 2] < 80
            }.count
            let green = stride(from: 0, to: pixels.count, by: 4).filter {
                pixels[$0 + 1] > 180 && pixels[$0] < 80 && pixels[$0 + 2] < 80
            }.count
            selectedPixels = isOnline ? green : red
            rejectedPixels = isOnline ? red : green
            if selectedPixels > 100 && rejectedPixels < 20 { break }
        } while ContinuousClock.now < deadline
        XCTAssertGreaterThan(selectedPixels, 100, "\(name): the real grid must paint the expected poster.")
        XCTAssertLessThan(rejectedPixels, 20, "\(name): do not retain the opposite source's poster.")
        if let image {
            let attachment = XCTAttachment(image: image)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    private func checkSwiftUIBrowseArtwork(cancelLookup: Bool) async throws {
        let server = try LibraryArtworkServer(
            images: ["library": artworkData(.red), "online": artworkData(.green)]
        )
        defer { server.stop() }
        let port = try await server.start()
        let token = UUID().uuidString
        let library = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/library/\(token)"))
        let online = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/online/\(token)"))
        _ = await ArtworkImageCache.shared.image(for: library, variant: .posterCard)
        _ = await ArtworkImageCache.shared.image(for: online, variant: .posterCard)
        var painted: ArtworkReference?
        let resolved = expectation(description: "Preferred poster painted")
        resolved.isInverted = cancelLookup
        let lookupStarted = expectation(description: "Provider lookup started")
        let content = FallbackAsyncImage(
            references: [.remote(library)], variant: .posterCard,
            artworkPolicy: .init(area: .browse, settings: .init(preference: .online)),
            asyncFallbackURL: {
                lookupStarted.fulfill()
                try? await Task.sleep(for: .seconds(1))
                return online
            },
            onResolveReference: { reference in
                if let reference, painted == nil {
                    painted = reference
                    resolved.fulfill()
                }
            },
            pinIdentity: token
        ) { image in
            image.resizable()
        } placeholder: {
            Color.blue
        }
        .frame(width: 200, height: 300)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let host = UIHostingController(rootView: AnyView(content))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        await fulfillment(of: [lookupStarted], timeout: 3)
        if cancelLookup {
            host.rootView = AnyView(EmptyView())
            await fulfillment(of: [resolved], timeout: 1.5)
            XCTAssertNil(painted, "Cancelling the preferred lookup must not turn it into a library-artwork miss.")
        } else {
            await fulfillment(of: [resolved], timeout: 5)
            XCTAssertEqual(painted, .remote(online), "A queued lookup must not pin the already-cached library image.")
        }
    }

    func testMissingAndUnusableProviderPostersStillFallBackToLibrary() async throws {
        let server = try LibraryArtworkServer(images: [
            "library": artworkData(.red),
            "wide": artworkData(.green, size: CGSize(width: 200, height: 100)),
            "invalid": Data("not an image".utf8)
        ])
        defer { server.stop() }
        let port = try await server.start()
        let token = UUID().uuidString
        let library = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/library/\(token)"))
        for key in [nil, "missing", "wide", "invalid"] as [String?] {
            let online = key.flatMap { URL(string: "http://127.0.0.1:\(port)/\($0)/\(token)") }
            let result = await ArtworkFirstPaintResolver.resolve(
                references: [.remote(library)], variant: .posterCard, maxAspectRatio: 0.9,
                asyncOnlineURL: { online }, prefersOnlineArtwork: true
            )
            XCTAssertEqual(result?.reference, .remote(library))
            XCTAssertTrue(try isRed(XCTUnwrap(result?.image), at: CGPoint(x: 10, y: 10)))
        }
    }

    private func artworkData(_ color: UIColor, size: CGSize = CGSize(width: 100, height: 150)) throws -> Data {
        try XCTUnwrap(UIGraphicsImageRenderer(size: size).image {
            color.setFill()
            $0.fill(CGRect(origin: .zero, size: size))
        }.pngData())
    }

    private func checkNativeBrowseArtwork(onlineDelay: TimeInterval) async throws {
        let settings = MetadataProviderSettingsStore()
        let previous = settings.load()
        settings.save(.default)
        defer { settings.save(previous) }
        let server = try LibraryArtworkServer(
            images: ["library": artworkData(.red), "online": artworkData(.green)],
            delays: ["online": onlineDelay]
        )
        defer { server.stop() }
        let port = try await server.start()
        let token = UUID().uuidString
        let library = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/library/\(token)"))
        let online = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/online/\(token)"))
        let item = MediaItem(id: token, title: token, kind: .movie, posterURL: library)
        let query = MetadataQuery(item)
        for provider in MetadataEnrichmentConfig.defaultBaseOrder {
            await MetadataDiskCache.shared.store(
                online, for: "\(query.cacheKey(for: .poster))|provider:\(provider.rawValue)"
            )
        }
        if onlineDelay == 0 {
            _ = await ArtworkImageCache.shared.image(for: online, variant: .posterCard)
        }
        _ = await ArtworkImageCache.shared.image(for: library, variant: .posterCard)
        let cell = NativeTVLibraryCell(frame: CGRect(x: 0, y: 0, width: 220, height: 400))
        defer { cell.prepareForReuse() }
        var environment = EnvironmentValues()
        environment.plozzCardCaptionView = .browse
        for preference in [ArtworkPreference.online, .library, .online] {
            environment.plozzArtworkSettings = .init(preference: preference)
            cell.configure(item: item, spoilerSettings: .default, environment: environment)
            let deadline = ContinuousClock.now + .seconds(3)
            var selected: UIImage?
            while ContinuousClock.now < deadline {
                cell.updateConfiguration(using: cell.configurationState)
                cell.layoutIfNeeded()
                let artwork = descendant(DetailTransitionSourceView.self, in: cell)?.reference?.nativeArtworkView
                if let imageView = artwork as? UIImageView {
                    selected = imageView.image
                } else if let content = artwork as? TVMediaItemContentView {
                    selected = (content.configuration as? TVMediaItemContentConfiguration)?.image
                }
                if let selected {
                    let color = try pixel(selected, at: CGPoint(
                        x: selected.size.width * selected.scale / 2, y: selected.size.height * selected.scale / 2))
                    if color[preference == .library ? 0 : 1] > 180 && color[preference == .library ? 1 : 0] < 80 { break }
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            let image = try XCTUnwrap(selected)
            XCTAssertGreaterThanOrEqual(image.cgImage?.width ?? 0, 100)
            let pixel = try pixel(image, at: CGPoint(x: image.size.width * image.scale / 2, y: image.size.height * image.scale / 2))
            XCTAssertGreaterThan(pixel[preference == .library ? 0 : 1], 180)
            XCTAssertLessThan(pixel[preference == .library ? 1 : 0], 80)
            XCTAssertEqual(cell.item?.id, token)
            let attachment = XCTAttachment(image: image)
            attachment.name = "browse-\(preference)-delay-\(onlineDelay)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    func testArtlessNativeLibraryCellsPaintNamesOnlyWhenCaptionsAreHidden() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let controller = UIViewController()
        controller.view.backgroundColor = .black
        let cell = NativeTVLibraryCell(frame: .zero)
        controller.view.addSubview(cell)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            cell.prepareForReuse()
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        var environment = EnvironmentValues()
        environment.themePalette = .dark
        environment.colorScheme = .dark
        environment.plozzCardStyle = .borderless
        environment.isEnabled = false
        for kind in [MediaItemKind.folder, .movie] {
            for hidden in [true, false] {
                environment.plozzCardCaptionsHidden = hidden
                cell.frame = CGRect(
                    x: 400, y: 200, width: 220,
                    height: NativeTVLibraryCell.height(for: 220, environment: environment)
                )
                var pictures: [[UInt8]] = []
                for title in ["Family", "Travel"] {
                    cell.configure(
                        item: MediaItem(id: title, title: title, kind: kind),
                        spoilerSettings: .default, environment: environment
                    )
                    window.layoutIfNeeded()
                    try await Task.sleep(for: .milliseconds(150))
                    let image = snapshot(window)
                    let artwork = try XCTUnwrap(descendant(DetailTransitionSourceView.self, in: cell)?.reference?.nativeArtworkView)
                    let rect = artwork.convert(artwork.bounds, to: window)
                    let crop = try XCTUnwrap(image.cgImage?.cropping(to: rect))
                    pictures.append(try rgba(crop))
                    XCTAssertEqual(cell.accessibilityLabel, title)
                    let attachment = XCTAttachment(image: UIImage(cgImage: crop))
                    attachment.name = "native-artless-\(kind)-\(hidden)-\(title)"
                    attachment.lifetime = .keepAlways
                    add(attachment)
                }
                XCTAssertEqual(pictures[0] != pictures[1], hidden,
                               "Only caption-free placeholders should paint each item's name inside the artwork.")
            }
            cell.prepareForReuse()
        }
    }

    func testGeneratedLibraryArtworkReachesNativePosterWithoutReplacingFocus() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let data = try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 100, height: 150)).image {
            UIColor.red.setFill()
            $0.fill(CGRect(x: 0, y: 0, width: 100, height: 150))
        }.pngData())
        let server = try LibraryArtworkServer(images: ["poster": data])
        defer { server.stop() }
        let port = try await server.start()
        let provider = LibraryCollageHostedProvider(
            posterURL: try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/poster/\(UUID().uuidString)"))
        )
        let account = Account(id: UUID().uuidString, from: provider.session)
        let library = AggregatedLibrary(
            accountID: account.id, accountName: "Viewer", serverName: "Server",
            providerKind: .jellyfin,
            library: MediaLibrary(id: "movies", title: "Movies", kind: .movie)
        )
        let source = LibraryArtworkSource(
            library: library, account: .init(account: account, provider: provider), scope: "hosted"
        )
        var activations = 0
        let controller = LibraryFocusController()
        let host = UIHostingController(rootView:
            LibraryCardView(
                aggregated: library, subtitle: "Server",
                action: { activations += 1 }, artworkSource: source
            )
            .environment(\.plozzCardFocusStyle, .system)
            .frame(width: 500)
        )
        controller.addChild(host)
        controller.view.addSubview(host.view)
        host.didMove(toParent: controller)
        host.view.frame = CGRect(x: 400, y: 300, width: 600, height: 450)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        let poster = try XCTUnwrap(descendant(NativePosterButton.self, in: window))
        let system = try XCTUnwrap(UIFocusSystem.focusSystem(for: window))
        controller.target = poster
        system.requestFocusUpdate(to: controller)
        system.updateFocusIfNeeded()
        let deadline = ContinuousClock.now + .seconds(8)
        func hasCollage(_ poster: NativePosterButton) throws -> Bool {
            guard let image = poster.image, let pixels = image.cgImage else { return false }
            return try isRed(image, at: CGPoint(x: CGFloat(pixels.width) * 0.5, y: CGFloat(pixels.height) * 0.25))
        }
        while !(try hasCollage(poster)), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(try hasCollage(poster), "The normalized native image must contain the generated collage.")
        XCTAssertEqual(try XCTUnwrap(poster.image).size.width, poster.contentSize.width, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(poster.image).size.height, poster.contentSize.height, accuracy: 1)
        XCTAssertTrue(poster.isFocused, "An asynchronously generated bitmap must not replace the native focus target.")
        poster.sendActions(for: .primaryActionTriggered)
        XCTAssertEqual(activations, 1)
        let artwork = try XCTUnwrap(NativeFocusProjection.artworkFrame(of: poster.artworkView, in: window))
        let image = snapshot(window)
        let badgePixel = try pixel(image, at: CGPoint(
            x: artwork.maxX - artwork.width * 0.08,
            y: artwork.minY + artwork.height * 0.12
        ))
        XCTAssertLessThanOrEqual(abs(Int(badgePixel[2]) - Int(badgePixel[1])), 3,
                                "Provider tint must no longer be drawn over the artwork.")
        let center = try XCTUnwrap(image.cgImage?.cropping(to: CGRect(
            x: artwork.minX + artwork.width * 0.2, y: artwork.minY + artwork.height * 0.35,
            width: artwork.width * 0.6, height: artwork.height * 0.3
        )))
        let centerPixels = try rgba(center)
        XCTAssertFalse(stride(from: 0, to: centerPixels.count, by: 4).contains {
            centerPixels[$0 + 1] > 180 && centerPixels[$0 + 2] > 180
        }, "The red collage must not have a white library title painted over it.")
        let caption = try XCTUnwrap(descendant(SystemPosterCaption.CaptionView.self, in: window))
        XCTAssertEqual(try XCTUnwrap(descendant(UILabel.self, in: caption.title)).text, "Movies")
        let badge = try XCTUnwrap(caption.providerBadge)
        let badgeFrame = try XCTUnwrap(NativeFocusProjection.artworkFrame(of: badge, in: window))
        XCTAssertGreaterThanOrEqual(badgeFrame.minY, artwork.maxY)
        XCTAssertFalse(badge.isDescendant(of: poster))
        let attachment = XCTAttachment(image: image)
        attachment.name = "generated-native-library-collage"
        attachment.lifetime = .keepAlways
        add(attachment)

        let returningCard = ImageRenderer(content:
            LibraryCardArtwork(library: library, source: source)
                .frame(width: 720, height: 405)
        )
        let firstFrame = try XCTUnwrap(returningCard.uiImage)
        XCTAssertTrue(try isRed(firstFrame, at: CGPoint(x: 360, y: 100)),
                      "A returning card must show its resident collage before any async task runs.")

        let returningHost = UIHostingController(rootView:
            LibraryCardView(aggregated: library, subtitle: "Server", action: {}, artworkSource: source)
                .environment(\.plozzCardFocusStyle, .system)
                .frame(width: 500)
        )
        host.view.isHidden = true
        controller.addChild(returningHost)
        controller.view.addSubview(returningHost.view)
        returningHost.didMove(toParent: controller)
        returningHost.view.frame = host.view.frame
        window.layoutIfNeeded()
        _ = snapshot(window)
        let returningPoster = try XCTUnwrap(descendant(NativePosterButton.self, in: returningHost.view))
        XCTAssertTrue(try hasCollage(returningPoster),
                      "The native focus surface must show the cached collage on its first paint.")
    }

    func testLibraryTransportMarksRemainDistinct() throws {
        var rendered: [Data] = []
        for transport in [MediaShareTransportKind.smb, .webDAV, .nfs] {
            let renderer = ImageRenderer(content:
                ProviderBrandMark(provider: .mediaShare, size: 32, mediaShareTransport: transport)
            )
            rendered.append(try XCTUnwrap(renderer.uiImage?.pngData()))
        }
        XCTAssertEqual(Set(rendered).count, 3, "Shared drive marks must retain the actual transport labels.")
    }

    func testNativeLibraryCaptionBadgeLayoutAndReuse() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let metrics = PlozzMetrics(density: .standard)
        func fixture(
            _ name: String, focused: Bool = false, direction: LayoutDirection = .leftToRight,
            provider: ProviderKind = .jellyfin, transport: MediaShareTransportKind? = nil
        ) -> some View {
            SystemPosterCaption(
                title: .content(name), subtitle: "Server", reservesSubtitleSpace: true,
                isFocused: focused, providerKind: provider, mediaShareTransport: transport
            )
            .frame(width: 484)
            .environment(\.plozzMetrics, metrics)
            .environment(\.layoutDirection, direction)
            .environment(\.colorScheme, .dark)
            .environment(\.themePalette, .dark)
            .background(.black)
        }
        let host = UIHostingController(rootView: fixture("Movies"))
        host.view.backgroundColor = .black
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        let longName = String(repeating: "A long library name ", count: 8)
        for direction in [LayoutDirection.leftToRight, .rightToLeft] {
            for name in ["Movies", longName] {
                host.rootView = fixture(name, direction: direction)
                try await Task.sleep(for: .milliseconds(100))
                let caption = try XCTUnwrap(descendant(SystemPosterCaption.CaptionView.self, in: window))
                let badge = try XCTUnwrap(caption.providerBadge)
                let restingFrame = badge.frame
                let height = caption.bounds.height
                XCTAssertEqual(badge.bounds.size, CGSize(
                    width: metrics.cardTitleFontSize, height: metrics.cardTitleFontSize
                ))
                XCTAssertFalse(badge.canBecomeFocused)
                XCTAssertFalse(badge.isUserInteractionEnabled)
                XCTAssertTrue(badge.accessibilityElementsHidden)
                XCTAssertFalse(badge.isDescendant(of: caption.title), "The badge must not move inside the marquee.")
                let title = try XCTUnwrap(descendant(UILabel.self, in: caption.title))
                if direction == .leftToRight {
                    XCTAssertEqual(caption.title.frame.minX - badge.frame.maxX, PlozzTheme.Spacing.small, accuracy: 1)
                } else {
                    XCTAssertEqual(badge.frame.minX - caption.title.frame.maxX, PlozzTheme.Spacing.small, accuracy: 1)
                }
                let start = min(badge.frame.minX, caption.title.frame.minX)
                let end = max(badge.frame.maxX, caption.title.frame.maxX)
                XCTAssertEqual((start + end) / 2, caption.bounds.midX, accuracy: 1,
                               "Center the name and badge together, not the name alone.")
                XCTAssertGreaterThanOrEqual(start, 0)
                XCTAssertLessThanOrEqual(end, caption.bounds.width)
                host.rootView = fixture(name, focused: true, direction: direction)
                try await Task.sleep(for: .milliseconds(250))
                XCTAssertTrue(caption.providerBadge === badge, "Focus must not rebuild the badge.")
                XCTAssertEqual(badge.frame, restingFrame)
                XCTAssertEqual(caption.bounds.height, height)
                if name == longName {
                    XCTAssertGreaterThan(title.bounds.width, caption.title.bounds.width)
                    XCTAssertEqual(title.layer.animation(forKey: "captionMarquee") != nil,
                                   !UIAccessibility.isReduceMotionEnabled)
                } else {
                    XCTAssertNil(title.layer.animation(forKey: "captionMarquee"))
                }
                let attachment = XCTAttachment(image: snapshot(window))
                attachment.name = "library-caption-\(direction)-long-\(name == longName)"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
        var transports: [Data] = []
        for provider in ProviderKind.allCases {
            let kinds: [MediaShareTransportKind?] = provider == .mediaShare ? [.smb, .webDAV, .nfs] : [nil]
            for transport in kinds {
                host.rootView = fixture("Movies", provider: provider, transport: transport)
                try await Task.sleep(for: .milliseconds(100))
                let caption = try XCTUnwrap(descendant(SystemPosterCaption.CaptionView.self, in: window))
                XCTAssertNotNil(caption.providerBadge)
                let image = snapshot(window)
                if provider == .mediaShare { transports.append(try XCTUnwrap(image.pngData())) }
                let attachment = XCTAttachment(image: image)
                attachment.name = "library-caption-\(provider.rawValue)-\(transport?.rawValue ?? "")"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
        XCTAssertEqual(Set(transports).count, 3, "The caption must retain each share's actual transport.")
    }

    func testIPTVBadgeColorIsDistinctFromEveryOtherProviderInAllFocusAppearances() throws {
        for scheme in [ColorScheme.light, .dark] {
            for focused in [false, true] {
                let background: Color = focused
                    ? (scheme == .dark ? .white : .black)
                    : (scheme == .dark ? Color(white: 0.12) : Color(white: 0.94))
                var colors: [ProviderKind: [Int]] = [:]
                for provider in ProviderKind.allCases {
                    let renderer = ImageRenderer(content:
                        ProviderBrandMark(provider: provider, size: 76)
                            .environment(\.settingsRowIsFocused, focused)
                            .environment(\.colorScheme, scheme)
                            .background(background)
                    )
                    renderer.scale = 3
                    let image = try XCTUnwrap(renderer.cgImage)
                    let bytes = try rgba(image)
                    let index = ((image.height / 10) * image.width + image.width / 2) * 4
                    colors[provider] = (0..<3).map { Int(bytes[index + $0]) }
                }
                let iptv = try XCTUnwrap(colors[.iptv])
                for provider in ProviderKind.allCases where provider != .iptv {
                    let other = try XCTUnwrap(colors[provider])
                    let difference = zip(iptv, other).map { abs($0 - $1) }.max() ?? 0
                    XCTAssertGreaterThanOrEqual(
                        difference, 8, "IPTV must remain distinct from \(provider), \(scheme), focused=\(focused)")
                }
                let strip = ImageRenderer(content:
                    HStack(spacing: 24) {
                        ForEach(ProviderKind.allCases, id: \.self) { provider in
                            VStack(spacing: 8) {
                                ProviderBrandMark(provider: provider, size: 76)
                                Text(verbatim: provider.displayName).font(.caption2)
                            }
                        }
                    }
                    .environment(\.settingsRowIsFocused, focused)
                    .environment(\.colorScheme, scheme)
                    .padding(24)
                    .background(background)
                )
                strip.scale = 2
                let attachment = XCTAttachment(image: try XCTUnwrap(strip.uiImage))
                attachment.name = "Distinct IPTV color \(scheme) focused=\(focused)"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }

    func testTransportMarkIsUnclippedAndOpticallyCentered() throws {
        let sizes: [CGFloat] = [32, 52, 76]
        for size in sizes {
            for transport in [MediaShareTransportKind.smb, .webDAV, .nfs, .sftp, .ftp] {
                let renderer = ImageRenderer(content:
                    ProviderBrandMark(
                        provider: .mediaShare, size: size, showsBackground: false,
                        mediaShareTransport: transport
                    )
                )
                renderer.scale = 3
                let image = try XCTUnwrap(renderer.cgImage)
                let pixels = try rgba(image)
                let rows = (0..<image.height).filter { y in
                    (0..<image.width).contains { x in pixels[(y * image.width + x) * 4 + 3] > 32 }
                }
                let top = try XCTUnwrap(rows.first)
                let bottom = image.height - 1 - (try XCTUnwrap(rows.last))
                let details = "\(transport), \(size)pt"
                XCTAssertGreaterThan(top, 3, details)
                XCTAssertGreaterThan(bottom, 3, details)
                XCTAssertLessThanOrEqual(abs(top - bottom), 6, "Balanced top/bottom ink padding: \(details)")
                let breaks = zip(rows, rows.dropFirst()).filter { $0.1 > $0.0 + 1 }
                XCTAssertEqual(breaks.count, 2,
                               "The drive's case, front panel and label must remain separate, unclipped shapes: \(details)")
            }
        }
        let renderer = ImageRenderer(content:
            HStack(spacing: 24) {
                ProviderBrandMark(provider: .mediaShare, size: 76, showsBackground: false, mediaShareTransport: .smb)
                ProviderBrandMark(provider: .mediaShare, size: 76, showsBackground: false, mediaShareTransport: .webDAV)
                ProviderBrandMark(provider: .jellyfin, size: 76, showsBackground: false)
            }
            .padding(24)
            .background(.gray)
        )
        renderer.scale = 2
        let attachment = XCTAttachment(image: try XCTUnwrap(renderer.uiImage))
        attachment.name = "unclipped-balanced-provider-marks"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testLibrariesRowClipsAtNavigationBoundaryInsteadOfContentInset() async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !UIApplication.shared.connectedScenes.contains(where: { $0.activationState == .foregroundActive }),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let controller = LibraryFocusController()
        controller.view.backgroundColor = .black
        window.rootViewController = controller
        let image = try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 320, height: 180)).image {
            UIColor.red.setFill()
            $0.fill(CGRect(x: 0, y: 0, width: 320, height: 180))
        }.pngData())
        let server = try LibraryArtworkServer(images: ["edge": image])
        defer { server.stop() }
        let port = try await server.start()
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/edge/\(UUID().uuidString)"))
        let libraries = (0..<6).map {
            AggregatedLibrary(
                accountID: "fixture", accountName: "Viewer", serverName: "Server",
                providerKind: .jellyfin,
                library: MediaLibrary(id: String($0), title: "Library \($0)", kind: .movie, imageURL: url)
            )
        }
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        for navigation in [NavigationStyle.tabBar, .sidebar, .rail] {
            let pinned = navigation == .rail
            var selected: String?
            let host = UIHostingController(rootView:
                HomeLibrariesRow(libraries: libraries, onSelectLibrary: { selected = $0.id })
                    .environment(\.plozzNavigationStyle, navigation)
                    .environment(\.plozzPinnedSidebarActive, pinned)
                    .environment(\.plozzNavigationContentInset, pinned ? 64 : 0)
                    .environment(\.plozzCardFocusStyle, .system)
                    .environment(\.themePalette, .dark)
            )
            host.safeAreaRegions = []
            controller.addChild(host)
            controller.view.addSubview(host.view)
            host.didMove(toParent: controller)
            host.view.backgroundColor = .clear
            host.view.frame = CGRect(x: 80, y: 250, width: 1760, height: 600)
            host.view.layoutIfNeeded()
            defer {
                host.willMove(toParent: nil)
                host.view.removeFromSuperview()
                host.removeFromParent()
            }
            try await Task.sleep(for: .milliseconds(200))
            let scroll = try XCTUnwrap(descendant(UIScrollView.self, in: host.view))
            let poster = try XCTUnwrap(descendant(NativePosterButton.self, in: host.view))
            let focus = try XCTUnwrap(UIFocusSystem.focusSystem(for: window))
            controller.target = poster
            focus.requestFocusUpdate(to: controller)
            focus.updateFocusIfNeeded()
            try await Task.sleep(for: .milliseconds(700))
            XCTAssertTrue(poster.isFocused)
            var artwork = try XCTUnwrap(NativeFocusProjection.artworkFrame(of: poster.artworkView, in: window))
            let loaded = ContinuousClock.now + .seconds(5)
            while try !isRed(snapshot(window), at: CGPoint(x: artwork.midX, y: artwork.midY)),
                  ContinuousClock.now < loaded {
                try await Task.sleep(for: .milliseconds(100))
                artwork = try XCTUnwrap(NativeFocusProjection.artworkFrame(of: poster.artworkView, in: window))
            }
            XCTAssertTrue(try isRed(snapshot(window), at: CGPoint(x: artwork.minX + 4, y: artwork.midY)),
                          "The focused first library must be whole: \(navigation)")
            poster.sendActions(for: .primaryActionTriggered)
            XCTAssertEqual(selected, "0")

            // A card passing through the page gutter still draws there under
            // native navigation; only the pinned sidebar owns a leading mask.
            let viewport = scroll.convert(scroll.bounds, to: window)
            scroll.setContentOffset(CGPoint(
                x: scroll.contentOffset.x + artwork.minX - (viewport.minX - 40),
                y: scroll.contentOffset.y
            ), animated: false)
            try await Task.sleep(for: .milliseconds(100))
            artwork = try XCTUnwrap(NativeFocusProjection.artworkFrame(of: poster.artworkView, in: window))
            let point = CGPoint(x: viewport.minX - 12, y: artwork.midY)
            XCTAssertGreaterThan(point.x, 0)
            XCTAssertTrue(artwork.contains(point), "The sampled pixel must lie inside real artwork.")
            XCTAssertEqual(try isRed(snapshot(window), at: point), !pinned,
                           "Native rows reach the screen edge; pinned rows stop at their chrome: \(navigation)")
            XCTAssertFalse(scroll.clipsToBounds, "The row must not impose a second content-inset clip.")
        }
    }

    func testLibrariesUseArtworkOnlyNativeFocusAndPreserveCustomCardGeometry() async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !UIApplication.shared.connectedScenes.contains(where: { $0.activationState == .foregroundActive }),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let controller = LibraryFocusController()
        controller.view.backgroundColor = .black
        window.rootViewController = controller
        let other = UIButton(type: .system)
        other.setTitle("Other focus target", for: .normal)
        other.frame = CGRect(x: 200, y: 80, width: 300, height: 60)
        controller.view.addSubview(other)
        controller.target = other
        var images = try [
            "portrait": CGSize(width: 200, height: 300),
            "wide": CGSize(width: 640, height: 180),
            "landscape": CGSize(width: 320, height: 180)
        ].mapValues { size in
            try XCTUnwrap(UIGraphicsImageRenderer(size: size).image {
                UIColor.red.setFill()
                $0.fill(CGRect(origin: .zero, size: size))
            }.pngData())
        }
        let transparentFormat = UIGraphicsImageRendererFormat()
        transparentFormat.scale = 1
        transparentFormat.opaque = false
        images["transparent"] = try XCTUnwrap(UIGraphicsImageRenderer(
            size: CGSize(width: 320, height: 180), format: transparentFormat
        ).image { renderer in
            let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: [UIColor.red.cgColor, UIColor.red.cgColor, UIColor.red.withAlphaComponent(0).cgColor] as CFArray,
                locations: [0, 0.65, 1]
            )!
            renderer.cgContext.drawLinearGradient(
                gradient, start: .zero, end: CGPoint(x: 0, y: 180), options: []
            )
        }.pngData())
        let server = try LibraryArtworkServer(images: images)
        defer { server.stop() }
        let port = try await server.start()
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        var configurations = CardStyle.allCases.flatMap { cardStyle in
            CardFocusStyle.allCases.map { ($0, cardStyle, UIDensity.standard) }
        }
        configurations.append((.system, .framed, .compact))
        for (style, cardStyle, density) in configurations {
            let metrics = PlozzMetrics(density: density)
            for aspect in ["portrait", "wide", "landscape", "transparent"] {
                controller.view.backgroundColor = aspect == "transparent" ? UIColor(white: 0.14, alpha: 1) : .black
                let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/\(aspect)/\(UUID().uuidString)"))
                let synthesized = style == .system && aspect == "landscape"
                let aggregated = AggregatedLibrary(
                    accountID: "fixture", accountName: "Viewer", serverName: "Fixture server",
                    providerKind: aspect == "transparent" ? .emby : .jellyfin,
                    library: MediaLibrary(
                        id: aspect, title: synthesized ? "Untranslated fallback" : "Movies", kind: .movie,
                        synthesizedName: synthesized ? .movies : nil, imageURL: url
                    )
                )
                var activations = 0
                let host = UIHostingController(rootView:
                    ScrollView {
                        VStack(alignment: .leading, spacing: metrics.sectionTitleSpacing) {
                            Text("Libraries").font(.system(size: metrics.sectionHeaderFontSize, weight: .bold))
                            ScrollView(.horizontal, showsIndicators: false) {
                                LazyHStack(spacing: metrics.cardSpacing) {
                                    LibraryCardView(aggregated: aggregated, subtitle: "Fixture server",
                                                    action: { activations += 1 })
                                        .background(LibraryCardFrameProbe())
                                }
                                .padding(.horizontal, PlozzTheme.Metrics.screenPadding)
                                .padding(.vertical, metrics.railShadowClearance)
                            }
                            .padding(.top, metrics.railTopClearanceOffset)
                            .padding(.bottom, metrics.railBottomClearanceOffset)
                        }
                    }
                    .environment(\.plozzMetrics, metrics)
                    .environment(\.plozzCardStyle, cardStyle)
                    .environment(\.plozzCardFocusStyle, style)
                    .environment(\.plozzReduceTransparency, false)
                    .environment(\.themePalette, .dark)
                    .environment(\.colorScheme, .dark)
                )
                host.safeAreaRegions = []
                controller.addChild(host)
                controller.view.addSubview(host.view)
                host.didMove(toParent: controller)
                host.view.backgroundColor = .clear
                host.view.frame = CGRect(x: 100, y: 200, width: 1600, height: 700)
                host.view.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(200))
                let slot = try XCTUnwrap(slotProbe(in: host.view))
                let system = try XCTUnwrap(UIFocusSystem.focusSystem(for: window))
                controller.target = other
                system.requestFocusUpdate(to: controller)
                system.updateFocusIfNeeded()
                if style == .system {
                    try await Task.sleep(for: .milliseconds(350))
                }
                var image = snapshot(window)
                let loadDeadline = ContinuousClock.now + .seconds(5)
                let slotFrame = slot.convert(slot.bounds, to: window)
                let sample = CGPoint(x: slotFrame.midX, y: slotFrame.minY + metrics.cardInset + metrics.landscapeHeight / 2)
                while try !isRed(image, at: sample), ContinuousClock.now < loadDeadline {
                    try await Task.sleep(for: .milliseconds(100))
                    image = snapshot(window)
                }
                guard try isRed(image, at: sample) else {
                    XCTFail("Fixture artwork must finish loading.")
                    return
                }
                XCTAssertEqual(slot.bounds.width, metrics.landscapeCardSlotWidth, accuracy: 1)
                XCTAssertNil(descendant(TVCardView.self, in: host.view),
                             "System Library focus must not encompass the caption in a generic TVCardView.")
                let poster = descendant(NativePosterButton.self, in: host.view)
                let restingImage = poster?.image
                let caption = descendant(SystemPosterCaption.CaptionView.self, in: host.view)
                let captionFrame = try caption.map { try XCTUnwrap(NativeFocusProjection.artworkFrame(of: $0, in: window)) }
                if style == .system {
                    XCTAssertNotNil(poster)
                    XCTAssertNotNil(caption)
                }
                for focused in style == .system ? [false, true] : [false] {
                    if focused {
                        let poster = try XCTUnwrap(poster)
                        controller.target = poster
                        system.requestFocusUpdate(to: controller)
                        system.updateFocusIfNeeded()
                        try await Task.sleep(for: .milliseconds(350))
                        XCTAssertTrue(poster.isFocused, "Keep genuine TVUIKit artwork focus.")
                    }
                    image = snapshot(window)
                    if let poster {
                        XCTAssertTrue(poster.image === restingImage, "Focus must reuse the prepared bitmap.")
                        XCTAssertTrue(poster.artworkView.masksFocusEffectToContents)
                        let width = metrics.landscapeCardSlotWidth - metrics.borderlessCardSideMargin * 2
                        XCTAssertEqual(poster.contentSize.width, width, accuracy: 1)
                        XCTAssertEqual(poster.contentSize.height, width * 9 / 16, accuracy: 1)
                        XCTAssertNil(poster.currentTitle, "The native image must not own a visible caption footer.")
                        XCTAssertEqual(poster.accessibilityLabel, "Movies")
                        XCTAssertEqual(poster.accessibilityValue, "Fixture server")
                        let caption = try XCTUnwrap(caption)
                        XCTAssertFalse(caption.isDescendant(of: poster))
                        XCTAssertFalse(caption.canBecomeFocused)
                        let frame = try XCTUnwrap(NativeFocusProjection.artworkFrame(of: caption, in: window))
                        XCTAssertEqual(frame, try XCTUnwrap(captionFrame), "Native focus must not project the caption slot.")
                        let title = try XCTUnwrap(descendant(UILabel.self, in: caption.title))
                        XCTAssertEqual(title.font.pointSize, metrics.cardTitleFontSize)
                        let artwork = try XCTUnwrap(NativeFocusProjection.artworkFrame(of: poster.artworkView, in: window))
                        let textFrame = try XCTUnwrap(NativeFocusProjection.artworkFrame(of: title, in: window))
                        if !focused {
                            XCTAssertEqual(frame.minY - artwork.maxY, metrics.landscapeCaptionTopSpacing, accuracy: 1,
                                           "Library captions need the landscape gap even before focus.")
                        }
                        XCTAssertGreaterThanOrEqual(textFrame.minY - artwork.maxY, metrics.landscapeCaptionTopSpacing - 1,
                                                    "The caption must keep breathing room below the focused artwork.")
                        let badge = try XCTUnwrap(caption.providerBadge)
                        let badgeFrame = try XCTUnwrap(NativeFocusProjection.artworkFrame(of: badge, in: window))
                        XCTAssertFalse(badge.isDescendant(of: poster))
                        XCTAssertFalse(badge.canBecomeFocused)
                        XCTAssertGreaterThanOrEqual(badgeFrame.minY - artwork.maxY, metrics.landscapeCaptionTopSpacing - 1,
                                                    "The provider mark must retain the caption's artwork clearance.")
                        XCTAssertLessThanOrEqual(badgeFrame.maxX, textFrame.minX)
                        XCTAssertEqual(slot.bounds.width, metrics.landscapeCardSlotWidth, accuracy: 1)
                        XCTAssertTrue(try isRed(image, at: CGPoint(x: artwork.midX, y: artwork.midY)))
                        for x in [artwork.minX + 3, artwork.maxX - 3] {
                            XCTAssertFalse(try isRed(image, at: CGPoint(x: x, y: artwork.minY + 3)),
                                           "Native artwork must keep rounded corners, including transparent covers: \(aspect), focused=\(focused)")
                        }
                        if aspect == "transparent" {
                            let bitmap = try XCTUnwrap(poster.image?.cgImage)
                            let pixels = try rgba(bitmap)
                            XCTAssertLessThan(pixels[((bitmap.height - 1) * bitmap.width + bitmap.width / 2) * 4 + 3], 16,
                                              "Keep the server cover's fading reflection; do not flatten it onto a plate.")
                            if !focused {
                                let bottom = try pixel(image, at: CGPoint(x: artwork.midX, y: artwork.maxY - 3))
                                XCTAssertGreaterThan(bottom[1], 12, "The backdrop must remain visible through the fade.")
                            }
                        }
                        if focused {
                            poster.sendActions(for: .primaryActionTriggered)
                            XCTAssertEqual(activations, 1, "Select must still open the correct Library.")
                        }
                    } else {
                        let surface = slot.convert(slot.bounds, to: window)
                        let framed = cardStyle == .framed
                        let imageWidth = framed ? metrics.landscapeWidth
                            : metrics.landscapeCardSlotWidth - metrics.borderlessCardSideMargin * 2
                        let artwork = CGRect(
                            x: surface.minX + (framed ? metrics.cardInset : metrics.borderlessCardSideMargin),
                            y: surface.minY + (framed ? metrics.cardInset : 0),
                            width: imageWidth,
                            height: framed ? metrics.landscapeHeight : imageWidth * 9 / 16
                        )
                        let details = "\(style), \(cardStyle), \(density), \(aspect)"
                        if framed {
                            XCTAssertFalse(try isRed(image, at: CGPoint(x: artwork.midX, y: surface.minY + 4)),
                                           "Top card inset must remain visible: \(details)")
                            XCTAssertFalse(try isRed(image, at: CGPoint(x: artwork.midX, y: surface.maxY - 4)),
                                           "Artwork must not paint into the bottom card inset: \(details)")
                        }
                        XCTAssertFalse(try isRed(image, at: CGPoint(x: surface.minX + 4, y: artwork.midY)))
                        XCTAssertFalse(try isRed(image, at: CGPoint(x: artwork.midX, y: artwork.maxY + 4)))
                        for x in [artwork.minX + 2, artwork.maxX - 2] {
                            XCTAssertFalse(try isRed(image, at: CGPoint(x: x, y: artwork.minY + 2)),
                                           "Both artwork corners must remain rounded: \(details)")
                        }
                        XCTAssertTrue(try isRed(image, at: CGPoint(x: artwork.midX, y: artwork.midY)))
                    }
                    let attachment = XCTAttachment(image: image)
                    attachment.name = "library-\(cardStyle)-\(style)-\(density)-\(aspect)-focused-\(focused)"
                    attachment.lifetime = .keepAlways
                    add(attachment)
                }
                host.willMove(toParent: nil)
                host.view.removeFromSuperview()
                host.removeFromParent()
                controller.target = other
                system.requestFocusUpdate(to: controller)
                system.updateFocusIfNeeded()
            }
        }
    }

    func testSharedNativePosterPreservesSquareDefaultAndMissingArtworkFocus() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        var activations = 0
        window.rootViewController = UIHostingController(rootView:
            SquareNativePosterFixture(action: { activations += 1 })
                .environment(\.plozzCardFocusStyle, .system)
                .environment(\.locale, Locale(identifier: "en"))
        )
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        let poster = try XCTUnwrap(descendant(NativePosterButton.self, in: window))
        XCTAssertEqual(poster.contentSize, CGSize(width: 320, height: 320),
                       "Existing music callers keep square artwork unless an aspect is supplied.")
        XCTAssertNotNil(poster.image, "A real placeholder must initialize native focus before artwork arrives.")
        XCTAssertEqual(poster.accessibilityLabel, "Movies")
        let caption = try XCTUnwrap(descendant(SystemPosterCaption.CaptionView.self, in: window))
        XCTAssertFalse(caption.isDescendant(of: poster))
        XCTAssertNil(caption.providerBadge, "Music and other unbadged poster callers must remain unchanged.")
        let system = try XCTUnwrap(UIFocusSystem.focusSystem(for: window))
        system.requestFocusUpdate(to: poster)
        system.updateFocusIfNeeded()
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertTrue(poster.isFocused)
        poster.sendActions(for: .primaryActionTriggered)
        XCTAssertEqual(activations, 1)
    }

    private func descendant<T: UIView>(_ type: T.Type, in view: UIView) -> T? {
        if let match = view as? T { return match }
        return view.subviews.lazy.compactMap { self.descendant(type, in: $0) }.first
    }

    private struct SquareNativePosterFixture: View {
        let action: () -> Void
        @PlozzCardFocus private var focused: Bool

        var body: some View {
            NativeArtworkPoster(
                width: 320, title: "Untranslated fallback", subtitle: nil, localizedTitle: "Movies",
                placeholderSymbol: "film.stack.fill", focus: $focused, action: action
            ) {
                FallbackAsyncImage(urls: []) { Color.clear }
            }
        }
    }

    private func slotProbe(in view: UIView) -> LibraryCardSlotView? {
        if let probe = view as? LibraryCardSlotView { return probe }
        return view.subviews.lazy.compactMap { self.slotProbe(in: $0) }.first
    }

    private func snapshot(_ window: UIWindow) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: window.bounds.size, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
    }

    private func isRed(_ image: UIImage, at point: CGPoint) throws -> Bool {
        let pixel = try pixel(image, at: point)
        return pixel[0] > 180 && pixel[1] < 100 && pixel[2] < 100
    }

    private func rgba(_ image: CGImage) throws -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try pixels.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(
                data: bytes.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return pixels
    }

    private func pixel(_ image: UIImage, at point: CGPoint) throws -> [UInt8] {
        let crop = try XCTUnwrap(image.cgImage?.cropping(to: CGRect(x: point.x, y: point.y, width: 1, height: 1)))
        var pixel = [UInt8](repeating: 0, count: 4)
        try pixel.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(
                data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ))
            context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return pixel
    }
}

private struct LibraryCardFrameProbe: UIViewRepresentable {
    func makeUIView(context: Context) -> LibraryCardSlotView { LibraryCardSlotView() }
    func updateUIView(_ uiView: LibraryCardSlotView, context: Context) {}
}

private final class LibraryCardSlotView: UIView {}

@MainActor
@Observable
private final class BrowseArtworkHostedPreferences {
    var artwork: ArtworkSettings

    init(artwork: ArtworkSettings) {
        self.artwork = artwork
    }
}

private struct BrowseArtworkHostedPage: View {
    let model: LibraryBrowseViewModel
    let focusStyle: CardFocusStyle
    let preferences: BrowseArtworkHostedPreferences

    var body: some View {
        LibraryBrowseView(viewModel: model, title: Text("Library"), onSelect: { _ in })
            .environment(\.plozzCardFocusStyle, focusStyle)
            .environment(\.plozzCardStyle, .borderless)
            .environment(\.plozzMetrics, PlozzMetrics(density: .standard))
            .environment(\.plozzCardCaptionSettings, .init(preference: .hide))
            .environment(\.plozzArtworkSettings, preferences.artwork)
            .environment(\.plozzArtworkProviders, .default)
            .environment(\.plozzArtworkArea, .home)
            .environment(\.themePalette, .dark)
            .environment(\.colorScheme, .dark)
            .background(Color.black)
    }
}

private struct BrowseArtworkHostedProvider: MediaProvider {
    let mediaItem: MediaItem
    let kind: ProviderKind = .jellyfin
    let session = UserSession(
        server: MediaServer(
            id: "browse-artwork", name: "Server", baseURL: URL(string: "https://example.invalid")!,
            provider: .jellyfin
        ),
        userID: "viewer", userName: "Viewer", deviceID: "fixture", accessToken: ""
    )
    func libraries() async throws -> [MediaLibrary] { [] }
    func continueWatching(limit: Int) async throws -> [MediaItem] { [] }
    func latest(limit: Int) async throws -> [MediaItem] { [] }
    func item(id: String) async throws -> MediaItem { mediaItem }
    func children(of itemID: String) async throws -> [MediaItem] { [] }
    func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        MediaPage(items: [mediaItem], startIndex: 0, totalCount: 1)
    }
    func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
    func playbackInfo(for itemID: String) async throws -> PlaybackRequest { throw AppError.notFound }
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {}
    func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
}

private struct LibraryCollageHostedProvider: MediaProvider {
    let posterURL: URL
    let kind: ProviderKind = .jellyfin
    let session = UserSession(
        server: MediaServer(
            id: "server", name: "Server", baseURL: URL(string: "https://example.invalid")!,
            provider: .jellyfin
        ),
        userID: "viewer", userName: "Viewer", deviceID: "fixture", accessToken: ""
    )
    func libraries() async throws -> [MediaLibrary] { [] }
    func continueWatching(limit: Int) async throws -> [MediaItem] { [] }
    func latest(limit: Int) async throws -> [MediaItem] { [] }
    func item(id: String) async throws -> MediaItem { throw AppError.notFound }
    func children(of itemID: String) async throws -> [MediaItem] { [] }
    func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        try await Task.sleep(for: .milliseconds(300))
        return MediaPage(
            items: [MediaItem(id: "movie", title: "Movie", kind: .movie, posterURL: posterURL)],
            startIndex: 0, totalCount: 1
        )
    }
    func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
    func playbackInfo(for itemID: String) async throws -> PlaybackRequest { throw AppError.notFound }
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {}
    func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
}

@MainActor
private final class LibraryFocusController: UIViewController {
    weak var target: UIView?
    override var preferredFocusEnvironments: [any UIFocusEnvironment] {
        target.map { [$0] } ?? super.preferredFocusEnvironments
    }
}

final class LibraryArtworkServer: @unchecked Sendable {
    private let listener: NWListener
    private let images: [String: Data]
    private let delays: [String: TimeInterval]
    private let queue = DispatchQueue(label: "NativeLibraryCardHostedTests.artwork")
    private var connections: [NWConnection] = []
    private var requestCounts: [String: Int] = [:]

    init(images: [String: Data], delays: [String: TimeInterval] = [:]) throws {
        self.images = images
        self.delays = delays
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    if let port = listener.port {
                        continuation.resume(returning: port.rawValue)
                    } else {
                        continuation.resume(throwing: URLError(.cannotConnectToHost))
                    }
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { connection.cancel(); return }
                connections.append(connection)
                connection.start(queue: queue)
                receive(connection, request: Data())
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.cancel()
        queue.sync {
            connections.forEach { $0.cancel() }
            connections.removeAll()
        }
    }

    func requestCount(for path: String) -> Int {
        queue.sync { requestCounts[path, default: 0] }
    }

    private func receive(_ connection: NWConnection, request: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, complete, error in
            guard let self, let data, error == nil else { connection.cancel(); return }
            let request = request + data
            guard let header = String(data: request, encoding: .utf8),
                  header.contains("\r\n\r\n") else {
                if complete || request.count > 16_384 {
                    connection.cancel()
                } else {
                    receive(connection, request: request)
                }
                return
            }
            let path = header.split(separator: " ").dropFirst().first ?? ""
            requestCounts[String(path), default: 0] += 1
            let key = path.split(separator: "/").first.map(String.init) ?? ""
            let image = images[key] ?? Data()
            let status = images[key] == nil ? "404 Not Found" : "200 OK"
            let response = Data("HTTP/1.1 \(status)\r\nContent-Type: image/png\r\nContent-Length: \(image.count)\r\nConnection: close\r\n\r\n".utf8) + image
            queue.asyncAfter(deadline: .now() + (delays[key] ?? 0)) {
                connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }
}
#endif
