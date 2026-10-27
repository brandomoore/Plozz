#if os(iOS)
import AVFoundation
import CoreModels
import CoreUI
import EnginePlozzigen
import FeatureLiveTVCore
@testable import FeatureLiveTV
@testable import FeaturePlayback
import Observation
import SwiftUI
import UIKit
import XCTest

@MainActor
final class LiveTVPreviewPresentationTests: XCTestCase {
    func testPerformanceLightVideoPreview() async throws {
        try await measurePreview(scenario: "mobile-video-glow", filename: "live-continuity.mp4", enabled: true)
    }

    func testPerformanceHDVideoGlow() async throws {
        try await measurePreview(scenario: "mobile-video-glow-hd", filename: "glow-hd.mp4", enabled: true)
    }

    func testPerformanceHDVideoWithoutGlow() async throws {
        try await measurePreview(scenario: "mobile-video-glow-hd-disabled", filename: "glow-hd.mp4", enabled: false)
    }

    private func measurePreview(scenario: String, filename: String, enabled: Bool) async throws {
        try PerformanceProbe.requireEnabled()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let host = UIViewController()
        host.view.backgroundColor = .white
        window.rootViewController = host
        window.makeKeyAndVisible()
        let engine = NativeVideoEngine(startsMuted: true)
        let video = VideoPresentationView(frame: CGRect(
            x: 0, y: 120, width: window.bounds.width, height: window.bounds.width * 9 / 16))
        host.view.addSubview(video)
        video.attach(engine)
        defer {
            video.updateReflection(height: 0)
            video.removeFromSuperview()
            engine.stop()
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        let folder = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Fixtures", withExtension: nil))
        await engine.load(request: PlaybackRequest(
            item: MediaItem(id: "preview-performance", title: "Synthetic video", kind: .movie),
            streamURL: folder.appendingPathComponent(filename)
        ), startPosition: 0)
        let deadline = ContinuousClock.now + .seconds(10)
        while !engine.hasPresentedVideoFrame, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(engine.hasPresentedVideoFrame)
        video.updateReflection(height: enabled ? 200 : 0, topHeight: enabled ? 100 : 0, lightAppearance: true)
        try await settle(window)
        try await Task.sleep(for: .seconds(2))
        let player = try XCTUnwrap(engine.nowPlayingPlayer)
        let output = engine.makeVideoOutputView()
        if filename == "glow-hd.mp4", enabled { XCTAssertGreaterThan(video.previewColorSampleCount, 0) }
        try await PerformanceProbe.measure(self, scenario: scenario) {
            let start = engine.currentTime
            let samples = video.previewColorSampleCount
            try await Task.sleep(for: .milliseconds(2300))
            XCTAssertGreaterThan(engine.currentTime - start, 1.8, "A frozen player is not a performance pass.")
            XCTAssertTrue(engine.hasPresentedVideoFrame)
            XCTAssertTrue(engine.nowPlayingPlayer === player)
            XCTAssertTrue(engine.makeVideoOutputView() === output)
            XCTAssertTrue(output.isDescendant(of: video))
            if filename == "glow-hd.mp4" {
                if enabled {
                    XCTAssertGreaterThan(video.previewColorSampleCount, samples)
                    XCTAssertLessThanOrEqual(video.previewColorSampleCount - samples, 5)
                } else {
                    XCTAssertFalse(video.isPreviewColorSampling)
                }
            }
            return ["players": 1, "visiblePreviews": 1, "windowMilliseconds": 2300]
        }
    }

    func testPreviewRespectsEitherVerticalBarWithoutMirroringItsInset() {
        for leading in [false, true] {
            let insets = EdgeInsets(
                top: 24, leading: leading ? 96 : 0,
                bottom: 20, trailing: leading ? 0 : 96
            )
            let layout = PrototypePreviewLayout(
                size: CGSize(width: 640, height: 800), safeAreaInsets: insets,
                showsVideoPreview: true, toolbarControlsBottom: 24
            )
            XCTAssertEqual(layout.sidebarWidth, 0)
            XCTAssertEqual(layout.videoFrame.minX, 0)
            XCTAssertEqual(layout.videoFrame.maxX, 640)
            XCTAssertEqual(layout.videoFrame.minY, 32)
            XCTAssertEqual(layout.contentFrame.minX, leading ? 0 : 16)
            XCTAssertEqual(layout.contentFrame.maxX, leading ? 624 : 640)
            XCTAssertEqual(layout.guideSideBleed, 0)
            XCTAssertEqual(layout.videoLeadingReflectionWidth, leading ? 96 : 0)
            XCTAssertEqual(layout.videoTrailingReflectionWidth, leading ? 0 : 96)
        }
    }

    func testPreviewSitsBelowToolbarAndLeavesRoomForTheGuide() {
        for size in [CGSize(width: 393, height: 700), CGSize(width: 852, height: 320),
                     CGSize(width: 834, height: 1000), CGSize(width: 1194, height: 700)] {
            let insets = EdgeInsets(top: 100, leading: 0, bottom: 34, trailing: 0)
            let collapsed = PrototypePreviewLayout(size: size, safeAreaInsets: insets)
            let playing = PrototypePreviewLayout(size: size, safeAreaInsets: insets, showsVideoPreview: true)
            XCTAssertEqual(collapsed.heroHeight, 0)
            XCTAssertEqual(playing.videoFrame.minY, playing.contentFrame.minY + 8)
            XCTAssertEqual(playing.videoFrame.maxX, playing.bounds.maxX)
            if playing.sidebarWidth > 0 {
                XCTAssertEqual(playing.videoFrame.minX,
                               playing.contentFrame.minX + playing.sidebarWidth
                                   + PrototypeLayout.sectionGap - playing.guideLeadingExtension)
            } else {
                XCTAssertEqual(playing.videoFrame.width, playing.bounds.width)
            }
            XCTAssertEqual(playing.contentFrame.minY + playing.heroHeight, playing.videoFrame.maxY)
            XCTAssertLessThanOrEqual(playing.videoFrame.height, playing.bounds.height * 0.48)
            XCTAssertGreaterThan(playing.heroHeight, 80)
            XCTAssertEqual(playing.guideWidth, collapsed.guideWidth)
            XCTAssertEqual(playing.contentFrame, collapsed.contentFrame)
            let searching = PrototypePreviewLayout(
                size: size, safeAreaInsets: insets, isSearching: true, showsVideoPreview: true)
            XCTAssertEqual(searching.heroHeight, 0)
            let measured = PrototypePreviewLayout(
                size: size, safeAreaInsets: insets, showsVideoPreview: true, toolbarControlsBottom: -14)
            XCTAssertEqual(measured.videoFrame.minY, -6, "Keep an 8 pt gap below the actual toolbar controls.")
            XCTAssertEqual(searching.videoReflectionHeight, 0)
            XCTAssertEqual(collapsed.videoReflectionHeight, 0)
            XCTAssertEqual(collapsed.videoTopReflectionHeight, 0)
            XCTAssertEqual(searching.videoTopReflectionHeight, 0)
            XCTAssertGreaterThan(playing.videoReflectionHeight, 0)
            XCTAssertEqual(playing.videoTopReflectionHeight,
                           min(playing.videoFrame.height, playing.videoFrame.minY - playing.bounds.minY))
            XCTAssertLessThanOrEqual(playing.videoReflectionHeight, playing.videoFrame.height)
        }
    }

    func testNativeVideoRetunePresentsFramesOnItsExistingSurface() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let host = UIViewController()
        window.rootViewController = host
        window.makeKeyAndVisible()
        let engine = NativeVideoEngine(startsMuted: true)
        let video = VideoPresentationView(frame: CGRect(x: 0, y: 100, width: 380, height: 214))
        host.view.addSubview(video)
        defer {
            engine.stop()
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        let folder = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Fixtures", withExtension: nil))
        video.attach(engine)
        let surface = engine.makeVideoOutputView()
        for _ in 0..<2 {
            await engine.load(request: PlaybackRequest(
                item: MediaItem(id: "retune", title: "Synthetic video", kind: .movie),
                streamURL: folder.appendingPathComponent("live-continuity.mp4")
            ), startPosition: 0)
            video.attach(engine)
            try await settle(window)
            let deadline = ContinuousClock.now + .seconds(10)
            while !engine.hasPresentedVideoFrame, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertTrue(engine.hasPresentedVideoFrame)
            XCTAssertTrue(engine.makeVideoOutputView() === surface)
            video.updateReflection(height: 180, topHeight: 100)
            try await settle(window)
            video.updateReflection(height: 0, topHeight: 0)
        }
    }

    func testNativeVideoReflectionRetainsSurfaceAndPlayer() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let host = UIViewController()
        host.view.backgroundColor = .black
        window.rootViewController = host
        window.makeKeyAndVisible()
        let engine = NativeVideoEngine(startsMuted: true)
        let video = VideoPresentationView(frame: CGRect(
            x: 0, y: 100, width: window.bounds.width, height: window.bounds.width * 9 / 16))
        host.view.addSubview(video)
        video.attach(engine)
        defer {
            engine.stop()
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        let folder = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Fixtures", withExtension: nil))
        await engine.load(request: PlaybackRequest(
            item: MediaItem(id: "reflection", title: "Synthetic video", kind: .movie),
            streamURL: folder.appendingPathComponent("live-continuity.mp4")
        ), startPosition: 0)
        let deadline = ContinuousClock.now + .seconds(10)
        while !engine.hasPresentedVideoFrame, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(engine.hasPresentedVideoFrame)
        engine.pause()
        try await settle(window)
        let player = try XCTUnwrap(engine.nowPlayingPlayer)
        let output = engine.makeVideoOutputView()
        let originalHost = try XCTUnwrap(output.superview)
        video.updateReflection(height: video.bounds.height)
        try await settle(window)
        XCTAssertTrue(engine.nowPlayingPlayer === player)
        XCTAssertTrue(engine.makeVideoOutputView() === output)
        XCTAssertTrue(output.isDescendant(of: video))
        XCTAssertFalse(video.clipsToBounds)
        let compositor = try XCTUnwrap(video.subviews.first)
        let fade = try XCTUnwrap(compositor.layer.mask as? CAGradientLayer)
        XCTAssertGreaterThan(fade.frame.height, video.bounds.height)
        XCTAssertEqual((fade.colors as? [CGColor])?.last?.alpha, 0,
                       "The reflection and blur must disappear into the actual guide background.")
        let colors = try XCTUnwrap(fade.colors as? [CGColor])
        let locations = try XCTUnwrap(fade.locations).map { CGFloat($0.doubleValue) }
        XCTAssertEqual(colors.count, locations.count)
        XCTAssertEqual(colors[1].alpha, 1, "Keep full intensity at the start of the reflection.")
        let samples: [(CGFloat, CGFloat)] = [(0.25, 0.6), (0.75, 0.1)]
        for (fraction, maximumAlpha) in samples {
            let position = (video.bounds.height + (fade.frame.height - video.bounds.height) * fraction)
                / fade.frame.height
            let upper = try XCTUnwrap(locations.firstIndex { $0 > position })
            let lower = upper - 1
            let progress = (position - locations[lower]) / (locations[upper] - locations[lower])
            let alpha = colors[lower].alpha + (colors[upper].alpha - colors[lower].alpha) * progress
            XCTAssertLessThan(alpha, maximumAlpha, "Fade early, leaving only a faint final quarter.")
        }
        XCTAssertTrue(compositor.subviews.contains { $0 is UIVisualEffectView },
                      "The same transparency mask must cover the blur, not only the video replica.")
        let originalFrame = output.convert(output.bounds, to: video)
        video.updateReflection(height: video.bounds.height, topHeight: 100)
        try await settle(window)
        let twoSidedFade = try XCTUnwrap(compositor.layer.mask as? CAGradientLayer)
        let twoSidedColors = try XCTUnwrap(twoSidedFade.colors as? [CGColor])
        XCTAssertEqual(twoSidedColors.first?.alpha, 0)
        XCTAssertEqual(twoSidedColors.last?.alpha, 0)
        XCTAssertEqual(compositor.frame.minY, -100)
        XCTAssertEqual(output.convert(output.bounds, to: video), originalFrame,
                       "Adding an upper reflection must not move or resize the original video.")
        XCTAssertTrue(output.superview === originalHost)
        XCTAssertEqual(compositor.subviews.filter { $0 is UIVisualEffectView && !$0.isHidden }.count, 1)
        video.frame.size = CGSize(width: 600, height: 200)
        video.updateReflection(height: 120, topHeight: 40, leftWidth: 60, rightWidth: 80, previewCornerRadius: 16)
        try await settle(window)
        XCTAssertEqual(compositor.frame, CGRect(x: -60, y: -40, width: 740, height: 360))
        XCTAssertTrue(output.superview === originalHost)
        XCTAssertTrue(engine.nowPlayingPlayer === player)
        let picture = try XCTUnwrap(video.videoRect)
        let roundedCrop = try XCTUnwrap(originalHost.layer.mask as? CAShapeLayer)
        let picturePath = try XCTUnwrap(roundedCrop.path)
        XCTAssertEqual(picturePath.boundingBoxOfPath, picture)
        XCTAssertFalse(picturePath.contains(CGPoint(x: picture.minX + 1, y: picture.minY + 1)))
        XCTAssertTrue(picturePath.contains(CGPoint(x: picture.midX, y: picture.midY)))
        let verticalFade = try XCTUnwrap(compositor.layer.mask as? CAGradientLayer)
        let sideFade = try XCTUnwrap(verticalFade.mask as? CAGradientLayer)
        let sideColors = try XCTUnwrap(sideFade.colors as? [CGColor])
        XCTAssertEqual(sideColors.first?.alpha, 0)
        XCTAssertEqual(sideColors.last?.alpha, 0)
        let blur = try XCTUnwrap(compositor.subviews.compactMap { $0 as? UIVisualEffectView }.first)
        let blurMask = try XCTUnwrap(blur.layer.mask as? CAShapeLayer)
        XCTAssertEqual(blurMask.fillRule, .evenOdd)
        let center = video.convert(CGPoint(x: picture.midX, y: picture.midY), to: blur)
        XCTAssertFalse(try XCTUnwrap(blurMask.path).contains(center, using: .evenOdd),
                       "Keep the original video sharp; only its surroundings receive blur.")

        for light in [true, false] {
            let previousEffect = blur.effect
            video.updateReflection(
                height: 120, topHeight: 40, leftWidth: 60, rightWidth: 80,
                previewCornerRadius: 16, lightAppearance: light
            )
            try await settle(window)
            XCTAssertNotNil(blur.effect as? UIBlurEffect)
            XCTAssertFalse(blur.effect === previousEffect)
            XCTAssertEqual(blur.contentView.backgroundColor?.cgColor.alpha ?? 0, 0)
            let fadeColors = try XCTUnwrap(verticalFade.colors as? [CGColor])
            XCTAssertEqual(fadeColors[2].alpha, light ? 0.4 : 0.16, accuracy: 0.001,
                           "Light-page colors need a longer fade, not an extra white wash.")
            var replica = try XCTUnwrap(compositor.subviews.first)
            for _ in 0..<4 {
                let layer = try XCTUnwrap(replica.layer as? CAReplicatorLayer)
                XCTAssertEqual(layer.instanceAlphaOffset, 0, accuracy: 0.001)
                if light { XCTAssertEqual(layer.instanceCount, 1, "Light glow does not replicate video.") }
                replica = try XCTUnwrap(replica.subviews.first)
            }
            XCTAssertTrue(replica === originalHost)
            XCTAssertEqual(originalHost.alpha, 1, "Light mode must not wash out the playing picture.")
            XCTAssertTrue(output.superview === originalHost)
            XCTAssertTrue(engine.nowPlayingPlayer === player)
            XCTAssertEqual(video.videoRect, picture)
            XCTAssertEqual(try XCTUnwrap(blurMask.path).boundingBoxOfPath, blur.bounds)
        }

        video.updateReflection(height: 0, previewCornerRadius: 16)
        try await settle(window)
        XCTAssertTrue(blur.isHidden, "Reduce Transparency keeps the rounded picture without any reflection blur.")
        XCTAssertNil(compositor.layer.mask)
        XCTAssertNotNil(originalHost.layer.mask)
        video.updateReflection(height: 0)
        try await settle(window)
        XCTAssertTrue(output.superview === originalHost, "Fullscreen must not reparent the playing surface.")
        XCTAssertTrue(video.clipsToBounds)
        XCTAssertNil(compositor.layer.mask)
        XCTAssertNil(originalHost.layer.mask, "Fullscreen restores the unmasked native video surface.")
        XCTAssertTrue(engine.nowPlayingPlayer === player)
        for size in [CGSize(width: 874, height: 402), CGSize(width: 402, height: 874)] {
            video.frame.size = size
            try await settle(window)
            XCTAssertTrue(output.superview === originalHost)
            XCTAssertTrue(engine.nowPlayingPlayer === player)
            XCTAssertEqual(output.bounds.size, size)
        }
    }

    func testGlowFadesInOutAndRetargetsFromItsVisibleColors() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
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
        let reflection = VideoPresentationView.VideoPreviewReflectionView(frame: window.bounds)
        reflection.videoSize = CGSize(width: 320, height: 180)
        reflection.picture = CGRect(origin: .zero, size: reflection.videoSize)
        reflection.insets = UIEdgeInsets(top: 100, left: 0, bottom: 100, right: 0)
        reflection.lightAppearance = true
        host.view.addSubview(reflection)
        try await settle(window)
        let gradient = try XCTUnwrap(reflection.layer.sublayers?.compactMap { $0 as? CAGradientLayer }.first)
        let red = Array(repeating: SIMD4<Float>(1, 0.6, 0.6, 0.9), count: 3)
        let blue = Array(repeating: SIMD4<Float>(0.6, 0.6, 1, 0.9), count: 3)

        reflection.updateColors(red)
        if UIAccessibility.isReduceMotionEnabled {
            XCTAssertNil(gradient.animation(forKey: "colors"))
            reflection.updateColors([])
            XCTAssertNil(gradient.colors)
            return
        }
        let fadeIn = try XCTUnwrap(gradient.animation(forKey: "colors") as? CABasicAnimation)
        XCTAssertTrue(try XCTUnwrap(fadeIn.fromValue as? [CGColor]).allSatisfy { $0.alpha == 0 })
        XCTAssertTrue(try XCTUnwrap(fadeIn.toValue as? [CGColor]).allSatisfy { $0.alpha > 0.8 })
        XCTAssertEqual(fadeIn.duration, 0.6, accuracy: 0.001)
        try await Task.sleep(for: .milliseconds(750))
        reflection.updateColors([])
        let fadeOut = try XCTUnwrap(gradient.animation(forKey: "colors") as? CABasicAnimation)
        let start = try XCTUnwrap(fadeOut.fromValue as? [CGColor])
        XCTAssertTrue(start.allSatisfy { $0.alpha > 0.8 })
        XCTAssertTrue(try XCTUnwrap(fadeOut.toValue as? [CGColor]).allSatisfy { $0.alpha == 0 })
        try await Task.sleep(for: .milliseconds(150))
        reflection.updateColors([])
        let repeatedClear = try XCTUnwrap(gradient.animation(forKey: "colors") as? CABasicAnimation)
        XCTAssertEqual(repeatedClear.fromValue as? [CGColor], start, "Repeated loading updates must not restart the fade.")
        let visible = try XCTUnwrap(gradient.presentation()?.colors as? [CGColor])
        XCTAssertTrue(visible.allSatisfy { $0.alpha > 0 && $0.alpha < 0.9 })
        reflection.updateColors(blue)
        let interrupted = try XCTUnwrap(gradient.animation(forKey: "colors") as? CABasicAnimation)
        XCTAssertEqual(interrupted.fromValue as? [CGColor], visible, "The next channel must start at the visible colors.")
        XCTAssertEqual(interrupted.toValue as? [CGColor], gradient.colors as? [CGColor])
        reflection.updateColors([], animated: false)
        XCTAssertNil(gradient.colors)
        XCTAssertNil(gradient.animation(forKey: "colors"))
        reflection.updateColors(blue)
        let returning = try XCTUnwrap(gradient.animation(forKey: "colors") as? CABasicAnimation)
        XCTAssertTrue(try XCTUnwrap(returning.fromValue as? [CGColor]).allSatisfy { $0.alpha == 0 })
    }

    func testDarkReflectionFadesWithoutFadingThePicture() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
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
        let reflection = VideoPresentationView.VideoPreviewReflectionView(frame: window.bounds)
        reflection.videoSize = CGSize(width: 320, height: 180)
        reflection.picture = CGRect(origin: .zero, size: reflection.videoSize)
        reflection.insets = UIEdgeInsets(top: 100, left: 0, bottom: 100, right: 0)
        host.view.addSubview(reflection)
        try await settle(window)
        let visibility = try XCTUnwrap(reflection.layer.mask?.mask?.mask)
        let surroundings = try XCTUnwrap(visibility.sublayers?.first)
        let picture = try XCTUnwrap(visibility.sublayers?.last as? CAShapeLayer)
        XCTAssertEqual(surroundings.opacity, 0)
        XCTAssertEqual(picture.opacity, 1)
        XCTAssertEqual(picture.fillColor?.alpha, 1)
        XCTAssertEqual(picture.path?.boundingBoxOfPath, CGRect(x: 0, y: 100, width: 320, height: 180))
        reflection.updateDarkReflection(isActive: true)
        XCTAssertEqual(surroundings.opacity, 1)
        if UIAccessibility.isReduceMotionEnabled {
            XCTAssertNil(surroundings.animation(forKey: "visibility"))
        } else {
            let fadeIn = try XCTUnwrap(surroundings.animation(forKey: "visibility") as? CABasicAnimation)
            XCTAssertEqual(fadeIn.fromValue as? Float, 0)
            XCTAssertEqual(fadeIn.toValue as? Float, 1)
            XCTAssertEqual(fadeIn.duration, 0.6, accuracy: 0.001)
            try await Task.sleep(for: .milliseconds(750))
            reflection.updateDarkReflection(isActive: false)
            let fadeOut = try XCTUnwrap(surroundings.animation(forKey: "visibility") as? CABasicAnimation)
            XCTAssertEqual(fadeOut.toValue as? Float, 0)
            try await Task.sleep(for: .milliseconds(150))
            let visible = try XCTUnwrap(surroundings.presentation()?.opacity)
            XCTAssertGreaterThan(visible, 0)
            XCTAssertLessThan(visible, 1)
            reflection.updateDarkReflection(isActive: true)
            let interrupted = try XCTUnwrap(surroundings.animation(forKey: "visibility") as? CABasicAnimation)
            XCTAssertEqual(interrupted.fromValue as? Float, visible)
        }
        XCTAssertEqual(picture.opacity, 1)
        XCTAssertNil(picture.animationKeys())
        XCTAssertEqual(reflection.source.alpha, 1)
        reflection.updateDarkReflection(isActive: false, animated: false)
        XCTAssertEqual(surroundings.opacity, 0)
        XCTAssertNil(surroundings.animationKeys())
    }

        func testGlowPreservesDimHuesWithoutDarkeningNeutralFootage() {
            func palette(_ red: UInt8, _ green: UInt8, _ blue: UInt8) -> [SIMD4<Float>] {
                let pixel: [UInt8] = [red, green, blue, 255]
                let pixels = Array(repeating: pixel, count: 24 * 14).flatMap { $0 }
                return VideoPreviewColorWorker.palette(pixels)
            }
            let bright = palette(240, 24, 8)
            let dim = palette(30, 3, 1)
            XCTAssertEqual(bright.count, 3)
            for (a, b) in zip(bright, dim) {
                XCTAssertEqual(a.x, b.x, accuracy: 0.01)
                XCTAssertEqual(a.y, b.y, accuracy: 0.01)
                XCTAssertEqual(a.z, b.z, accuracy: 0.01)
                XCTAssertGreaterThan(b.x, b.y + 0.3)
                XCTAssertGreaterThan(min(b.x, b.y, b.z), 0.5)
                XCTAssertGreaterThan(b.w, 0.8)
            }
            for gray: UInt8 in [0, 16, 128, 255] {
                XCTAssertTrue(palette(gray, gray, gray).allSatisfy { $0.w == 0 })
            }
        }

        func testGlowSamplesBothDecodersAndReleasesItsOutput() async throws {
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let previous = scene.windows.first(where: \.isKeyWindow)
            let window = UIWindow(windowScene: scene)
            let host = UIViewController()
            host.view.backgroundColor = .white
            window.rootViewController = host
            window.makeKeyAndVisible()
            defer {
                window.isHidden = true
                window.rootViewController = nil
                previous?.makeKeyAndVisible()
            }
            let folder = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Fixtures", withExtension: nil))
            let engines: [(any VideoEngine, String)] = [
                (NativeVideoEngine(startsMuted: true), "live-continuity-dim.mp4"),
                (try PlozzigenVideoEngine(), "glow-software.mkv"),
                (LibraryLiveChannelEngine(engine: try PlozzigenVideoEngine()), "glow-software.mkv"),
            ]
            for (engine, filename) in engines {
                let video = VideoPresentationView(frame: CGRect(x: 0, y: 100, width: 380, height: 214))
                host.view.addSubview(video)
                video.attach(engine)
                defer { video.removeFromSuperview(); engine.stop() }
                XCTAssertFalse(engine.hasPresentedVideoFrame)
                XCTAssertNil(engine.previewVideoFrame())
                await engine.load(
                    request: PlaybackRequest(
                        item: MediaItem(id: filename, title: "Synthetic dim video", kind: .movie),
                        streamURL: folder.appendingPathComponent(filename)
                    ), startPosition: 0)
                let deadline = ContinuousClock.now + .seconds(12)
                while !engine.hasPresentedVideoFrame, ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(20))
                }
                XCTAssertTrue(engine.hasPresentedVideoFrame, filename)
                if let adapter = engine as? LibraryLiveChannelEngine {
                    XCTAssertTrue(adapter.underlyingEngine.hasPresentedVideoFrame)
                    XCTAssertEqual(adapter.previewFrameGeneration, adapter.underlyingEngine.previewFrameGeneration)
                }
                let item = engine.nowPlayingPlayer?.currentItem
                let originalOutputs = item?.outputs.count
                if filename.hasSuffix("mkv") {
                    XCTAssertNil(item, "Exercise the software path, not the remux/native path.")
                    XCTAssertNotNil(engine.previewVideoFrame())
                    XCTAssertNotNil(engine.previewFrameGeneration)
                } else {
                    XCTAssertNotNil(item, "Exercise the native output path.")
                }
                video.updateReflection(height: 180, topHeight: 80, lightAppearance: true)
                try await settle(window)
                let sampleDeadline = ContinuousClock.now + .seconds(5)
                while video.previewColorSampleCount == 0, ContinuousClock.now < sampleDeadline {
                    try await Task.sleep(for: .milliseconds(20))
                }
                XCTAssertGreaterThan(video.previewColorSampleCount, 0, filename)
                let gradient = try XCTUnwrap(
                    video.subviews.first?.layer.sublayers?
                        .compactMap { $0 as? CAGradientLayer }.first)
                let colors = try XCTUnwrap(gradient.colors as? [CGColor])
                XCTAssertEqual(colors.count, 3)
                XCTAssertTrue(colors.contains { $0.alpha > 0.5 }, "Dim decoded footage must still yield visible color.")
                if !UIAccessibility.isReduceMotionEnabled {
                    let fade = try XCTUnwrap(gradient.animation(forKey: "colors") as? CABasicAnimation)
                    let start = try XCTUnwrap(fade.fromValue as? [CGColor])
                    let end = try XCTUnwrap(fade.toValue as? [CGColor])
                    XCTAssertEqual(start.count, colors.count)
                    XCTAssertTrue(start.allSatisfy { $0.alpha == 0 }, "The first palette must fade in from transparent.")
                    XCTAssertEqual(end, colors)
                    XCTAssertEqual(fade.duration, 0.6, accuracy: 0.001)
                } else {
                    XCTAssertNil(gradient.animation(forKey: "colors"))
                }
                engine.pause()
                try await Task.sleep(for: .milliseconds(700))
                let pausedCount = video.previewColorSampleCount
                try await Task.sleep(for: .milliseconds(1100))
                XCTAssertEqual(video.previewColorSampleCount, pausedCount, "Paused frames must not keep converting.")
                let glowBounds = gradient.frame
                video.updateReflection(height: 180, topHeight: 80, lightAppearance: true, isActive: false)
                XCTAssertFalse(video.isPreviewColorSampling)
                XCTAssertEqual(gradient.frame, glowBounds, "Channel changes retain the area needed to fade out.")
                if !UIAccessibility.isReduceMotionEnabled {
                    let fade = try XCTUnwrap(gradient.animation(forKey: "colors") as? CABasicAnimation)
                    XCTAssertTrue(try XCTUnwrap(fade.toValue as? [CGColor]).allSatisfy { $0.alpha == 0 })
                }
                if let item { XCTAssertEqual(item.outputs.count, originalOutputs) }
                let stoppedCount = video.previewColorSampleCount
                try await Task.sleep(for: .milliseconds(600))
                XCTAssertEqual(video.previewColorSampleCount, stoppedCount)
                video.updateReflection(height: 0)
                XCTAssertNil(gradient.colors)
                XCTAssertNil(gradient.animation(forKey: "colors"), "Leaving the inline presentation cancels its fade.")
                video.updateReflection(height: 180, lightAppearance: true)
                NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
                XCTAssertFalse(video.isPreviewColorSampling)
                video.updateReflection(height: 181, lightAppearance: true)
                XCTAssertFalse(video.isPreviewColorSampling, "A late layout update must not restart background work.")
                NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
                XCTAssertTrue(video.isPreviewColorSampling)
                video.removeFromSuperview()
                XCTAssertFalse(video.isPreviewColorSampling)
                engine.stop()
                XCTAssertFalse(engine.hasPresentedVideoFrame)
                XCTAssertNil(engine.previewVideoFrame())
                XCTAssertNil(engine.previewFrameGeneration)
                if let adapter = engine as? LibraryLiveChannelEngine {
                    await adapter.drainTransport()
                }
            }
        }

    func testSidebarRemainsInteractiveBesidePreviewInBothLayoutDirections() {
        let bounds = CGRect(x: 0, y: 0, width: 1_024, height: 768)
        for trailing in [false, true] {
            let path = PrototypeGuideHitRegion(top: 300, sidebarWidth: 240, sidebarOnTrailing: trailing)
                .path(in: bounds)
            XCTAssertTrue(path.contains(CGPoint(x: trailing ? 900 : 100, y: 100)))
            XCTAssertFalse(path.contains(CGPoint(x: 500, y: 100)), "Preview taps must reach player controls.")
            XCTAssertTrue(path.contains(CGPoint(x: 500, y: 500)))
        }
    }

    func testOpeningPreviewResizesExistingGuideWithoutChangingScrollOffset() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let state = PreviewState()
        let host = UIHostingController(rootView: PreviewGuideFixture(state: state))
        host.safeAreaRegions = []
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        for size in [CGSize(width: 393, height: 700), CGSize(width: 834, height: 700)] {
            state.showsPreview = false
            window.frame = CGRect(origin: .zero, size: size)
            host.view.frame = window.bounds
            try await settle(window)
            let scrolling = scrollViews(window).filter {
                $0.contentSize.height > $0.bounds.height + 400
            }
            let scroll = try XCTUnwrap(scrolling.max { $0.bounds.width < $1.bounds.width })
            let sidebar = scrolling.first { $0 !== scroll }
            if size.width > 700 { XCTAssertNotNil(sidebar) }
            sidebar?.setContentOffset(CGPoint(x: 0, y: 91), animated: false)
            scroll.setContentOffset(CGPoint(x: 0, y: 367), animated: false)
            try await settle(window)
            let offset = scroll.contentOffset
            let before = scroll.convert(scroll.bounds, to: window)
            let sidebarFrame = sidebar.map { $0.convert($0.bounds, to: window) }
            state.showsPreview = true
            try await settle(window)
            XCTAssertTrue(scrollViews(window).contains { $0 === scroll }, "Keep the original guide scroll view.")
            XCTAssertEqual(scroll.contentOffset.y, offset.y, accuracy: 1, "Keep partial-row position, not just a row ID.")
            let after = scroll.convert(scroll.bounds, to: window)
            XCTAssertGreaterThan(after.minY, before.minY + 100)
            XCTAssertEqual(after.maxY, before.maxY, accuracy: 1)
            XCTAssertEqual(after.width, before.width, accuracy: 1)
            if let sidebar {
                XCTAssertTrue(scrollViews(window).contains { $0 === sidebar })
                XCTAssertEqual(sidebar.convert(sidebar.bounds, to: window), sidebarFrame)
                XCTAssertEqual(sidebar.contentOffset.y, 91, accuracy: 1)
            }
            state.showsPreview = false
            try await settle(window)
            XCTAssertEqual(scroll.contentOffset.y, offset.y, accuracy: 1)
        }
    }

    private func settle(_ window: UIWindow) async throws {
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(350))
        window.layoutIfNeeded()
    }

    private func scrollViews(_ view: UIView) -> [UIScrollView] {
        (view as? UIScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
    }
}

@MainActor @Observable
private final class PreviewState {
    var showsPreview = false
}

private struct PreviewGuideFixture: View {
    let state: PreviewState
    @State private var model = LiveTVPrototypeModel()
    @State private var imports = LiveTVPrototypeImportModel(configuration: .empty)
    @State private var selectedID: String?
    @State private var selectedRowID: LiveTVGuideRowID?
    @State private var active = false
    @State private var focusedProgram: LiveTVPrototypeProgram?
    @State private var hasFocus = false
    @State private var offset: TimeInterval = 0
    @State private var time = Date()
    @State private var timeline: CGFloat = 0

    var body: some View {
        GeometryReader { geometry in
            let layout = PrototypePreviewLayout(size: geometry.size, showsVideoPreview: state.showsPreview)
            PrototypeGuidePlacement(frame: layout.contentFrame, canvasWidth: geometry.size.width) {
                PrototypeBrowseLayout(layout: layout) {
                    Color.clear.frame(height: layout.heroHeight).allowsHitTesting(false)
                } sidebar: {
                    ScrollView {
                        LazyVStack {
                            ForEach(0..<50) { index in
                                Text("Category \(index)").frame(height: 44)
                            }
                        }
                    }
                } guide: {
                    PrototypeBrowser(
                        model: model, imports: imports, selectedID: $selectedID, selectedRowID: $selectedRowID,
                        railActive: $active, focusedProgram: $focusedProgram, hasFocus: $hasFocus,
                        topRequest: 0, nowRequest: 0, guideOffset: $offset, timeAnchor: $time,
                        timelineOffset: $timeline, restoreFocusRequest: 0, isPresented: true,
                        isRestoringFocus: false, restoresPlaybackFocus: false, watchOrigin: nil,
                        focusRestored: { _ in }, tune: { _ in }, details: { _ in },
                        openControls: {}, openSources: {}, openGuideTime: {}, openToolbar: nil,
                        isLoading: false, loadFailed: false, reload: {}
                    )
                }
            }
        }
    }
}
#endif
