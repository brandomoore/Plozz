import AVFoundation
import CoreImage
import CoreModels
@testable import CoreUI
@testable import FeaturePlayback
#if os(iOS)
@testable import AppShelliOS
#endif
import SwiftUI
import UIKit
import Vision
import XCTest

@MainActor
final class PlayerSongLayoutPreviewTests: XCTestCase {
    func testSongServiceChooserShowsReadableNativeServiceRows() async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !UIApplication.shared.connectedScenes.contains(where: { $0.activationState == .foregroundActive }),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        defer { previous?.makeKeyAndVisible() }
        let song = SongMatch(
            title: "Six Days (feat. Mos Def) [Remix]", artist: "DJ Shadow", artworkURL: nil,
            appleMusicURL: URL(string: "https://music.apple.com/album/example?i=123")
        )
        for (name, palette, reduced) in [
            ("dark", ThemePalette.dark, false), ("light", .light, false), ("opaque", .pureBlack, true)
        ] {
            let window = UIWindow(windowScene: scene)
            window.overrideUserInterfaceStyle = palette.isLight ? .light : .dark
            let host = UIHostingController(rootView: SongServiceSheetPreview(song: song)
                .environment(\.themePalette, palette)
                .environment(\.colorScheme, palette.isLight ? .light : .dark)
                .environment(\.plozzReduceTransparency, reduced)
                .environment(\.plozzReducePanelGlass, reduced)
                .environment(\.locale, Locale(identifier: "en_US")))
            window.rootViewController = host
            window.makeKeyAndVisible()
            defer {
                host.dismiss(animated: false)
                window.isHidden = true
                window.rootViewController = nil
            }
            let presentationDeadline = ContinuousClock.now + .seconds(5)
            while host.presentedViewController == nil, ContinuousClock.now < presentationDeadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertNotNil(host.presentedViewController)
            try await Task.sleep(for: .milliseconds(700))
            window.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = "song-service-picker-\(name)"
            attachment.lifetime = .keepAlways
            add(attachment)
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["en-US"]
            try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
            let observations = request.results ?? []
            let text = observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
            for label in ["Open song", "Six Days", "DJ Shadow", "Apple Music", "Search Spotify", "Search YouTube"] {
                XCTAssertTrue(text.contains(label), "\(name): keep \(label) visible and readable: \(text)")
                let frame = try XCTUnwrap(observations.first {
                    $0.topCandidates(1).first?.string.contains(label) == true
                }?.boundingBox)
                try assertSongTextContrast(in: XCTUnwrap(image.cgImage), normalizedFrame: frame,
                                          message: "\(name): \(label)")
            }
            let serviceFrames = try ["Apple Music", "Search Spotify", "Search YouTube"].map { title in
                try XCTUnwrap(observations.first { $0.topCandidates(1).first?.string.contains(title) == true }?.boundingBox)
            }
            XCTAssertGreaterThan(serviceFrames[0].minY, serviceFrames[1].maxY)
            XCTAssertGreaterThan(serviceFrames[1].minY, serviceFrames[2].maxY,
                                 "Each service needs a separate full-width row, not adjacent inline links.")
        }
    }

    func testSongServiceRowsWrapForLargeTextWithoutAnAppleMusicLink() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        defer { previous?.makeKeyAndVisible() }
        let song = SongMatch(title: "A long song title with a remix and featured performers",
                             artist: "An artist with a long name", artworkURL: nil, appleMusicURL: nil)
        XCTAssertEqual(SongServiceLink.links(for: song).map(\.service), [.spotify, .youtube])
        for size in [DynamicTypeSize.large, .accessibility2] {
            #if os(tvOS)
            let width: CGFloat = 740
            #else
            let width: CGFloat = 320
            #endif
            let window = UIWindow(windowScene: scene)
            window.overrideUserInterfaceStyle = .dark
            let host = UIHostingController(rootView:
                SongServiceChooserContent(song: song, phoneLink: nil, select: { _ in })
                    .frame(width: width)
                    .padding(24)
                    .background(Color.black)
                    .environment(\.colorScheme, .dark)
                    .environment(\.themePalette, .dark)
                    .environment(\.dynamicTypeSize, size)
                    .environment(\.locale, Locale(identifier: "en_US"))
            )
            host.safeAreaRegions = []
            window.rootViewController = host
            window.makeKeyAndVisible()
            defer { window.isHidden = true; window.rootViewController = nil }
            let fitted = host.sizeThatFits(in: CGSize(width: width + 48, height: .greatestFiniteMagnitude))
            window.frame = CGRect(origin: .zero, size: fitted)
            host.view.frame = window.bounds
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(500))
            let captured = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
            }
            let image = try XCTUnwrap(captured.cgImage)
            let attachment = XCTAttachment(image: captured)
            attachment.name = "song-service-picker-wrapping-\(size)"
            attachment.lifetime = .keepAlways
            add(attachment)
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["en-US"]
            try VNImageRequestHandler(cgImage: image).perform([request])
            let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: " ").replacingOccurrences(of: "- ", with: "")
            XCTAssertTrue(text.contains(song.title), text)
            XCTAssertTrue(text.contains(try XCTUnwrap(song.artist)), text)
            XCTAssertTrue(text.contains("Search Spotify"), text)
            XCTAssertTrue(text.contains("Search YouTube"), text)
        }
    }

    private func assertSongTextContrast(in image: CGImage, normalizedFrame: CGRect, message: String) throws {
        let rect = CGRect(x: normalizedFrame.minX * CGFloat(image.width),
                          y: normalizedFrame.minY * CGFloat(image.height),
                          width: normalizedFrame.width * CGFloat(image.width),
                          height: normalizedFrame.height * CGFloat(image.height)).integral
        let width = Int(rect.width)
        let height = Int(rect.height)
        XCTAssertGreaterThan(width * height, 0)
        guard width * height > 0 else { return }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes {
            CIContext().render(CIImage(cgImage: image), toBitmap: $0.baseAddress!, rowBytes: width * 4,
                               bounds: rect, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        }
        func linear(_ byte: UInt8) -> Double {
            let value = Double(byte) / 255
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        let luminances = stride(from: 0, to: pixels.count, by: 4).map {
            0.2126 * linear(pixels[$0]) + 0.7152 * linear(pixels[$0 + 1]) + 0.0722 * linear(pixels[$0 + 2])
        }.sorted()
        let contrast = (luminances[luminances.count * 95 / 100] + 0.05)
            / (luminances[luminances.count * 5 / 100] + 0.05)
        XCTAssertGreaterThanOrEqual(contrast, 3, message)
    }

    func testLinkedSongCardMatchesPanelSurfaceAndCorners() async throws {
        let presentationDeadline = ContinuousClock.now + .seconds(5)
        while !UIApplication.shared.connectedScenes.contains(where: { $0.activationState == .foregroundActive }),
              ContinuousClock.now < presentationDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let host = SongPreviewFocusHost(rootView: AnyView(EmptyView()))
        window.rootViewController = host
        window.makeKeyAndVisible()
        window.frame = CGRect(x: 0, y: 0, width: 1400, height: 800)
        host.view.frame = window.bounds
        defer {
            host.target = nil
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }

        for (appearance, reducedGlass, reducedTransparency) in [
            ("glass", false, false),
            ("reduced-glass", true, false),
            ("reduced-transparency", false, true)
        ] {
            let probe = SongSurfaceProbe()
            host.target = nil
            host.rootView = AnyView(SongSurfaceHarness(probe: probe)
                .environment(\.playerCardMetrics, .tv)
                .environment(\.plozzReducePanelGlass, reducedGlass)
                .environment(\.plozzReduceTransparency, reducedTransparency)
                .environment(\.colorScheme, .dark)
                .environment(\.themePalette, .dark)
                .id(appearance))
            window.layoutIfNeeded()
            let deadline = ContinuousClock.now + .seconds(3)
            while probe.frames.count < 3, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            let reference = try XCTUnwrap(probe.frames["reference"])
            let linked = try XCTUnwrap(probe.frames["linked"])
            XCTAssertEqual(reference.size, linked.size)

            #if os(tvOS)
            func focusTarget(in bounds: CGRect) async throws -> any UIFocusItem {
                let point = CGPoint(x: bounds.midX, y: bounds.midY)
                func target() -> (any UIFocusItem)? { nativeFocusItems(in: window).first {
                    NativeFocusRegion.frame(of: $0, in: host.view)?.contains(point) == true
                } }
                let deadline = ContinuousClock.now + .seconds(3)
                while target() == nil, ContinuousClock.now < deadline {
                    window.layoutIfNeeded()
                    try await Task.sleep(for: .milliseconds(20))
                }
                return try XCTUnwrap(target(), "No native focus item at \(bounds).")
            }
            func focus(_ target: any UIFocusItem) async throws {
                host.target = target
                host.setNeedsFocusUpdate()
                host.updateFocusIfNeeded()
                let deadline = ContinuousClock.now + .seconds(3)
                while UIFocusSystem.focusSystem(for: window)?.focusedItem !== target,
                      ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(20))
                }
                XCTAssertTrue(UIFocusSystem.focusSystem(for: window)?.focusedItem === target)
            }
            let parked = try await focusTarget(in: XCTUnwrap(probe.frames["park"]))
            try await focus(parked)
            #endif
            try await Task.sleep(for: .milliseconds(600))
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
                XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = "song-panel-surface-\(appearance)"
            attachment.lifetime = .keepAlways
            add(attachment)

            for name in ["reference", "linked"] {
                let frame = try XCTUnwrap(probe.frames[name])
                let artwork = try XCTUnwrap(probe.artworkFrames[name])
                XCTAssertEqual(artwork.minX - frame.minX, PlayerCardMetrics.tv.contentPadding, accuracy: 1,
                               "The native button must not add another horizontal inset; \(name), \(appearance).")
                XCTAssertEqual(artwork.minY - frame.minY, PlayerCardMetrics.tv.contentPadding, accuracy: 1)
                XCTAssertEqual(frame.maxY - artwork.maxY, PlayerCardMetrics.tv.contentPadding, accuracy: 1)
                try assertCompleteSongText(in: image, frame: frame)
            }

            let source = CIImage(cgImage: try XCTUnwrap(image.cgImage))
            let context = CIContext()
            func pixel(_ source: CIImage, _ frame: CGRect, _ point: CGPoint) -> [UInt8] {
                var bytes = [UInt8](repeating: 0, count: 4)
                bytes.withUnsafeMutableBytes {
                    context.render(source, toBitmap: $0.baseAddress!, rowBytes: 4,
                                   bounds: CGRect(x: frame.minX + point.x,
                                                  y: window.bounds.height - frame.minY - point.y - 1,
                                                  width: 1, height: 1),
                                   format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
                }
                return bytes
            }
            for point in [
                CGPoint(x: 450, y: 20), CGPoint(x: 450, y: 230),
                CGPoint(x: 3, y: 3), CGPoint(x: 14, y: 14),
                CGPoint(x: 26, y: 8), CGPoint(x: 8, y: 26),
                CGPoint(x: linked.width - 14, y: linked.height - 14)
            ] {
                let expected = pixel(source, reference, point), actual = pixel(source, linked, point)
                for channel in 0..<3 {
                    // Native glass edge lighting varies slightly with screen position.
                    XCTAssertEqual(Double(actual[channel]), Double(expected[channel]), accuracy: 16,
                                   "Linked card must retain the panel surface and corners at \(point); appearance=\(appearance).")
                }
            }
            #if os(tvOS)
            try await focus(focusTarget(in: linked))
            try await Task.sleep(for: .milliseconds(300))
            let focusedImage = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
                XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
            }
            let focusedAttachment = XCTAttachment(image: focusedImage)
            focusedAttachment.name = "song-panel-focused-\(appearance)"
            focusedAttachment.lifetime = .keepAlways
            add(focusedAttachment)
            let focusedSource = CIImage(cgImage: try XCTUnwrap(focusedImage.cgImage))
            let focusDifference = [
                CGPoint(x: 450, y: 20), CGPoint(x: linked.width / 2, y: -5)
            ].flatMap { point in
                let before = pixel(source, linked, point), after = pixel(focusedSource, linked, point)
                return (0..<3).map { abs(Int(after[$0]) - Int(before[$0])) }
            }.max() ?? 0
            XCTAssertGreaterThan(focusDifference, 24, "Native focus must be visible, not just assigned.")
            try await focus(parked)
            #endif
        }
    }

    func testSongTextWrapsAtMobileCardWidths() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: AnyView(EmptyView()))
        window.rootViewController = host
        window.makeKeyAndVisible()
        window.frame = CGRect(x: 0, y: 0, width: 1400, height: 800)
        host.view.frame = window.bounds
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }

        for metrics in [PlayerCardMetrics.horizontalWide, .verticalNarrow] {
            let probe = SongSurfaceProbe()
            host.rootView = AnyView(SongSurfaceHarness(probe: probe, metrics: metrics)
                .environment(\.colorScheme, .dark)
                .environment(\.themePalette, .dark))
            window.layoutIfNeeded()
            let deadline = ContinuousClock.now + .seconds(3)
            while probe.frames.count < 3, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            try await Task.sleep(for: .milliseconds(600))
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
                XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = "song-wrapping-\(metrics.isVertical ? "phone" : "tablet")"
            attachment.lifetime = .keepAlways
            add(attachment)
            for name in ["reference", "linked"] {
                try assertCompleteSongText(in: image, frame: XCTUnwrap(probe.frames[name]))
            }
        }
    }

    private func assertCompleteSongText(in image: UIImage, frame: CGRect) throws {
        let card = try XCTUnwrap(image.cgImage?.cropping(to: frame))
        let recognition = VNRecognizeTextRequest()
        recognition.recognitionLevel = .accurate
        recognition.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(cgImage: card).perform([recognition])
        let text = (recognition.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
        XCTAssertTrue(text.contains("Wembley Stadium"), text)
        XCTAssertTrue(text.contains("Festival Orchestra"), text)
        XCTAssertTrue(text.contains("Electric Light Orchestra and friends"), text)
        XCTAssertFalse(text.contains("…") || text.contains("..."), text)
        let lineStarts = (recognition.results ?? []).map { $0.boundingBox.minX * frame.width }
        if let leading = lineStarts.min() {
            for start in lineStarts {
                // Vision estimates ink bounds, which vary with glyphs and font weight.
                XCTAssertEqual(start, leading, accuracy: 6, "Wrapped lines must stay leading-aligned: \(text)")
            }
        }
    }

    func testInfoUsesAllSpaceUnlessSongCardIsVisible() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let song = SongMatch(title: "Synthetic cue", artist: nil, artworkURL: nil, appleMusicURL: nil)

        for (metrics, width) in [
            (PlayerCardMetrics.tv, CGFloat(1800)),
            (.horizontalWide, 1200),
            (.verticalNarrow, 360)
        ] {
            let probe = SongLayoutProbe()
            let window = UIWindow(windowScene: scene)
            let host = UIHostingController(rootView: SongLayoutHarness(probe: probe, metrics: metrics, width: width))
            window.rootViewController = host
            window.makeKeyAndVisible()
            window.frame = CGRect(x: 0, y: 0, width: width, height: 800)
            host.view.frame = window.bounds
            defer {
                window.isHidden = true
                window.rootViewController = nil
                previous?.makeKeyAndVisible()
            }

            func waitForLayout(_ condition: () -> Bool) async throws {
                let deadline = ContinuousClock.now + .seconds(3)
                while !condition(), ContinuousClock.now < deadline {
                    window.layoutIfNeeded()
                    try await Task.sleep(for: .milliseconds(20))
                }
                XCTAssertTrue(condition(), "Info: \(probe.infoBounds), layout: \(probe.layoutBounds)")
            }
            func isFullSize() -> Bool {
                abs(probe.infoBounds.width - width) < 1 && abs(probe.layoutBounds.height - 100) < 1
            }
            func isShowingSong() -> Bool {
                metrics.isVertical
                    ? probe.layoutBounds.height > 200 && abs(probe.infoBounds.width - width) < 1
                    : probe.infoBounds.width > 0 && probe.infoBounds.width < width - 100
            }

            try await waitForLayout(isFullSize)
            XCTAssertEqual(probe.appearances, 1)

            probe.state = .found(song)
            try await waitForLayout(isShowingSong)
            probe.state = .idle
            try await waitForLayout(isFullSize)

            probe.state = .found(song)
            try await waitForLayout(isShowingSong)
            probe.enabled = false
            try await waitForLayout(isFullSize)
            probe.enabled = true
            try await waitForLayout(isShowingSong)
            probe.state = .idle
            try await waitForLayout(isFullSize)

            XCTAssertEqual(probe.appearances, 1, "Song transitions must not remount the Info card.")
            XCTAssertEqual(probe.disappearances, 0)
        }
    }

    func testPerformanceSongCardHidden() async throws {
        try await measureSongCard(visible: false)
    }

    func testPerformanceSongCardVisible() async throws {
        try await measureSongCard(visible: true)
    }

    private func measureSongCard(visible: Bool) async throws {
        try PerformanceProbe.requireEnabled()
        weak var observedPlayer: PlayerViewModel?
        weak var observedEngine: NativeVideoEngine?
        try await runSongCard(visible: visible) { player, engine in
            observedPlayer = player
            observedEngine = engine
        }
        let deadline = ContinuousClock.now + .seconds(5)
        while observedPlayer != nil || observedEngine != nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertNil(observedPlayer, "Unmounting the complete player must release its view model.")
        XCTAssertNil(observedEngine, "Unmounting the complete player must release its native engine.")
    }

    private func runSongCard(
        visible: Bool, trackLifetime: (PlayerViewModel, NativeVideoEngine) -> Void
    ) async throws {
        let fixtures = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Fixtures", withExtension: nil))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer {
            do { try FileManager.default.removeItem(at: directory) }
            catch { XCTFail("Could not remove song-card fixture directory: \(error)") }
        }
        try FileManager.default.copyItem(
            at: fixtures.appendingPathComponent("glow-hd.mp4"), to: directory.appendingPathComponent("film.mp4")
        )
        let artwork = UIGraphicsImageRenderer(size: CGSize(width: 512, height: 512)).image { context in
            UIColor(red: 0.1, green: 0.8, blue: 0.9, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 512, height: 512))
        }
        let data = try XCTUnwrap(artwork.jpegData(compressionQuality: 0.9))
        try data.write(to: directory.appendingPathComponent("album.jpg"))
        try data.write(to: directory.appendingPathComponent("still.jpg"))
        let server = try SubtitleFixtureServer(directory: directory)
        defer { server.stop() }
        let port = try await server.start()
        let origin = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)"))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let engine = NativeVideoEngine()
        var settings = PlaybackSettings.default
        settings.identifySongs = false
        let player = PlayerViewModel(
            provider: SongPreviewProvider(origin: origin), itemID: "song-performance",
            playbackSettings: settings, engineFactory: EngineFactory(makeNative: { _ in engine })
        )
        trackLifetime(player, engine)
        let model = player.controls
        let probe = SongArtworkProbe()
        let song = SongMatch(title: "Synthetic cue", artist: "Performance fixture",
                             artworkURL: origin.appendingPathComponent("album.jpg"), appleMusicURL: nil)
        PlayerScreenshotHook.pendingPanel = .info
        window.rootViewController = UIHostingController(rootView:
            SongPreviewPlayer(engine: engine, player: player)
                .environment(\.colorScheme, .dark)
                .environment(\.themePalette, .dark)
                .onPreferenceChange(PlayerSongArtworkBounds.self) { probe.bounds = $0 }
        )
        window.makeKeyAndVisible()
        defer {
            engine.stop()
            model.songRecognition.heard(nil)
            PlayerScreenshotHook.pendingPanel = nil
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        do {
            await player.load()
            let deadline = ContinuousClock.now + .seconds(20)
            while !engine.hasPresentedVideoFrame, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(50))
            }
            XCTAssertTrue(engine.hasPresentedVideoFrame)
            model.controlsVisible = true
            model.infoCard.headline = "Synthetic playback"
            model.infoCard.overview = "A stable description for the complete player controls workload."
            model.infoCard.artworkURLs = [origin.appendingPathComponent("still.jpg")]
            model.infoCard.artworkItem = nil
            model.songRecognition.isAvailable = true
            model.songRecognition.heard(visible ? song : nil)
            if visible {
                let artworkDeadline = ContinuousClock.now + .seconds(10)
                while !songArtworkLoaded(in: window, bounds: probe.bounds[.song]),
                      ContinuousClock.now < artworkDeadline {
                    try await Task.sleep(for: .milliseconds(100))
                }
                XCTAssertTrue(songArtworkLoaded(in: window, bounds: probe.bounds[.song]),
                              "Measure decoded artwork, not a placeholder.")
            }
            let scenario = "song-card-\(visible ? "visible" : "hidden")"
            try await PerformanceProbe.measure(self, scenario: scenario) {
                let start = engine.currentTime
                for _ in 0..<12 {
                    model.songRecognition.heard(visible ? song : nil)
                    try await Task.sleep(for: .milliseconds(250))
                }
                XCTAssertGreaterThan(engine.currentTime - start, 2.3)
                XCTAssertEqual(probe.bounds[.song] != nil, visible)
                return ["playbackMilliseconds": max(0, Int((engine.currentTime - start) * 1000)),
                        "acceptedReports": 12, "songVisible": visible ? 1 : 0]
            }
            await player.stop()
        } catch {
            await player.stop()
            throw error
        }
    }

    private func songArtworkLoaded(in window: UIWindow, bounds: CGRect?) -> Bool {
        guard let bounds else { return false }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1), format: format).image { _ in
            window.drawHierarchy(in: window.bounds.offsetBy(dx: -bounds.midX, dy: -bounds.midY),
                                 afterScreenUpdates: true)
        }
        guard let image = image.cgImage else { return false }
        var pixel = [UInt8](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes { bytes in
            CIContext().render(CIImage(cgImage: image), toBitmap: bytes.baseAddress!, rowBytes: 4,
                               bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                               format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        }
        return pixel[0] < 80 && pixel[1] > 150 && pixel[2] > 170
    }

    func testSongCardUsesSharedArtworkHeight() {
        XCTAssertEqual(PlayerSongCard.artworkSize(for: .tv), PlayerCardMetrics.tv.contentHeight)
        XCTAssertEqual(PlayerSongCard.artworkSize(for: .horizontalWide), PlayerCardMetrics.horizontalWide.contentHeight)
        XCTAssertEqual(PlayerSongCard.artworkSize(for: .verticalNarrow), 112)
        XCTAssertFalse(PlayerControlsModel().songRecognition.isAvailable)
    }

    func testWidePlayerTypographyUsesTouchScaleWithoutChangingTV() {
        XCTAssertEqual(PlayerCardMetrics.tv.titleSize, 34)
        XCTAssertEqual(PlayerCardMetrics.tv.bodySize, 25)
        XCTAssertEqual(PlayerCardMetrics.tv.captionSize, 22)
        #if os(iOS)
        let wide = PlayerCardMetrics.resolved(forWidth: 1376, height: 1032)
        XCTAssertEqual(wide.titleSize, 24)
        XCTAssertEqual(wide.bodySize, 17)
        XCTAssertEqual(wide.captionSize, 14)
        XCTAssertEqual(wide.contentHeight, 208)
        XCTAssertEqual(wide.contentPadding, 16)

        let phone = PlayerCardMetrics.resolved(forWidth: 402, height: 874)
        XCTAssertEqual(phone.titleSize, 17)
        XCTAssertEqual(phone.bodySize, 13)
        XCTAssertEqual(phone.captionSize, 11)

        let middle = PlayerCardMetrics.resolved(forWidth: 900, height: 600)
        XCTAssertEqual(middle.titleSize, 20)
        XCTAssertEqual(middle.bodySize, 14)
        XCTAssertEqual(middle.captionSize, 12)
        #endif
    }

    func testCaptureSeparateCardOverNativePlayback() async throws {
        let path = ProcessInfo.processInfo.environment["PLOZZ_SONG_PREVIEW_DIRECTORY"]
        try XCTSkipIf(path == nil, "Opt-in visual comparison requires a local directory containing film.mp4, still.jpg and album.jpg.")
        let directory = URL(fileURLWithPath: try XCTUnwrap(path), isDirectory: true)
        let server = try SubtitleFixtureServer(directory: directory)
        defer { server.stop() }
        let port = try await server.start()
        let origin = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)"))
        let deadline = ContinuousClock.now + .seconds(10)
        while !UIApplication.shared.connectedScenes.contains(where: { $0.activationState == .foregroundActive }),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let engine = NativeVideoEngine()
        let provider = SongPreviewProvider(origin: origin)
        let player = PlayerViewModel(
            provider: provider, itemID: "song-preview",
            engineFactory: EngineFactory(makeNative: { _ in engine })
        )
        defer {
            engine.stop()
            PlayerScreenshotHook.pendingPanel = nil
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        let model = player.controls
        var size = scene.coordinateSpace.bounds.size
        #if os(iOS)
        if UIDevice.current.userInterfaceIdiom == .pad {
            // Like the adaptive-panel fixtures, host a wide native viewport
            // without changing the simulator user's iPad windowing preferences.
            size = CGSize(width: max(size.width, size.height), height: min(size.width, size.height))
        }
        #endif
        window.frame = CGRect(origin: .zero, size: size)
        window.overrideUserInterfaceStyle = .dark
        let song = SongMatch(
            title: "It's Raining Vengeance", artist: "Michael Giacchino",
            artworkURL: origin.appendingPathComponent("album.jpg"),
            appleMusicURL: URL(string: "https://music.apple.com/")
        )
        do {
            PlayerScreenshotHook.pendingPanel = .info
            let probe = SongArtworkProbe()
            let host = SongPreviewFocusHost(rootView:
                SongPreviewPlayer(engine: engine, player: player)
                    .environment(\.colorScheme, .dark)
                    .environment(\.locale, Locale(identifier: "en_US"))
                    .environment(\.themePalette, .dark)
                    .onPreferenceChange(PlayerSongArtworkBounds.self) { probe.bounds = $0 }
            )
            window.rootViewController = host
            window.makeKeyAndVisible()
            window.frame = CGRect(origin: .zero, size: size)
            host.view.frame = window.bounds
            do {
                await player.load()
                let videoDeadline = ContinuousClock.now + .seconds(20)
                while !engine.hasPresentedVideoFrame, ContinuousClock.now < videoDeadline {
                    try await Task.sleep(for: .milliseconds(50))
                }
                XCTAssertTrue(engine.hasPresentedVideoFrame, "The comparison must contain decoded video, not a backdrop mock.")
                engine.play()
                let start = engine.currentTime
                try await Task.sleep(for: .milliseconds(300))
                XCTAssertGreaterThan(engine.currentTime, start)
            }
            await engine.seek(to: 2)
            engine.pause()
            model.controlsVisible = true
            model.infoCard.headline = "Tears of Steel"
            model.infoCard.overview = "In a future Amsterdam, a group of scientists and soldiers gather in the Oude Kerk to recreate a pivotal moment from the past and rescue the world from destructive robots."
            model.infoCard.runtimeLabel = "12m"
            model.infoCard.releaseLabel = "2012"
            model.infoCard.artworkURLs = [origin.appendingPathComponent("still.jpg")]
            model.infoCard.artworkItem = nil
            model.songRecognition.state = .found(song)
            model.songRecognition.isAvailable = true
            try await Task.sleep(for: .seconds(2))
            window.layoutIfNeeded()
            #if os(tvOS)
            // This fixture mounts PlayerControls without the container that releases entry focus gating.
            model.controlBar.settled = true
            try await Task.sleep(for: .milliseconds(100))
            window.layoutIfNeeded()
            #endif
            do {
                let artwork = try XCTUnwrap(probe.bounds[.song])
                XCTAssertEqual(artwork.width, artwork.height, accuracy: 1)
                if let infoArtwork = probe.bounds[.info] {
                    XCTAssertEqual(artwork.height, infoArtwork.height, accuracy: 1)
                    XCTAssertEqual(artwork.minY, infoArtwork.minY, accuracy: 1)
                    XCTAssertEqual(artwork.maxY, infoArtwork.maxY, accuracy: 1)
                } else {
                    XCTAssertEqual(artwork.height, 112, accuracy: 1)
                }
            }
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
                XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
            }
            let recognition = VNRecognizeTextRequest()
            recognition.recognitionLevel = .accurate
            recognition.recognitionLanguages = ["en-US"]
            try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([recognition])
            let text = (recognition.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
            XCTAssertTrue(text.contains("Tears of Steel"), text)
            XCTAssertTrue(text.contains("Raining Vengeance"), text)
            XCTAssertTrue(text.contains("Giacchino"), text)
            let attachment = XCTAttachment(image: image)
            attachment.name = "separate-\(Int(size.width))x\(Int(size.height))"
            attachment.lifetime = .keepAlways
            add(attachment)
            let infoBounds = probe.bounds[.info]
            #if os(tvOS)
            let artwork = try XCTUnwrap(probe.bounds[.song])
            let point = CGPoint(x: artwork.midX, y: artwork.midY)
            let items = nativeFocusItems(in: window)
            let card = try XCTUnwrap(items.first {
                NativeFocusRegion.frame(of: $0, in: host.view)?.contains(point) == true
            }, "No native song target at \(point); candidates: \(items.compactMap { NativeFocusRegion.frame(of: $0, in: host.view) })")
            host.target = card
            host.setNeedsFocusUpdate()
            host.updateFocusIfNeeded()
            let focusDeadline = ContinuousClock.now + .seconds(3)
            while UIFocusSystem.focusSystem(for: window)?.focusedItem !== card,
                  ContinuousClock.now < focusDeadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertTrue(UIFocusSystem.focusSystem(for: window)?.focusedItem === card)
            try await Task.sleep(for: .milliseconds(300))
            let focusedImage = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
                XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
            }
            let focusedAttachment = XCTAttachment(image: focusedImage)
            focusedAttachment.name = "separate-focused-\(Int(size.width))x\(Int(size.height))"
            focusedAttachment.lifetime = .keepAlways
            add(focusedAttachment)
            host.target = nil
            #endif
            model.songRecognition.state = .idle
            try await Task.sleep(for: .milliseconds(400))
            window.layoutIfNeeded()
            XCTAssertEqual(probe.bounds[.info], infoBounds, "Song expiry must not move Info artwork or actions.")
            #if os(tvOS)
            let focused = try XCTUnwrap(UIFocusSystem.focusSystem(for: window)?.focusedItem)
            XCTAssertFalse(focused === card, "An expired song must release native focus.")
            #endif
        }
        await player.stop()
    }

    #if os(tvOS)
    private func nativeFocusItems(in window: UIWindow) -> [any UIFocusItem] {
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
    #endif
}

private struct SongServiceSheetPreview: View {
    let song: SongMatch
    @State private var isPresented = false

    var body: some View {
        Color.gray.opacity(0.2)
            .ignoresSafeArea()
            .plozzSheet(isPresented: $isPresented, style: SongServiceChooser.presentationStyle) {
                SongServiceChooser(song: song)
            }
            .task { isPresented = true }
    }
}

@MainActor
private final class SongPreviewFocusHost<Content: View>: UIHostingController<Content> {
    var target: (any UIFocusEnvironment)?
    override var preferredFocusEnvironments: [any UIFocusEnvironment] {
        target.map { [$0] } ?? super.preferredFocusEnvironments
    }
}

@MainActor
private final class SongArtworkProbe {
    var bounds: [PlayerSongArtworkBounds.Role: CGRect] = [:]
}

@MainActor
private final class SongSurfaceProbe {
    var frames: [String: CGRect] = [:]
    var artworkFrames: [String: CGRect] = [:]
}

private struct SongSurfaceHarness: View {
    let probe: SongSurfaceProbe
    var metrics: PlayerCardMetrics = .tv
    @FocusState private var focus: PlayerControls.FocusSlot?

    var body: some View {
        ZStack {
            Color(red: 0.1, green: 0.35, blue: 0.55).ignoresSafeArea()
            VStack(spacing: 100) {
                HStack(spacing: 60) {
                    card(linked: false)
                    card(linked: true)
                }
                Button("Park focus") {}
                    .frame(width: 220, height: 60)
                    .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) {
                        probe.frames["park"] = $0
                    }
            }
        }
        .environment(\.playerCardMetrics, metrics)
    }

    private func card(linked: Bool) -> some View {
        let artSize = PlayerSongCard.artworkSize(for: metrics)
        let width = metrics.isVertical ? 360 : artSize * 2 + metrics.columnSpacing + metrics.contentPadding * 2
        return PlayerSongCard(
            song: SongMatch(
                title: "Mr. Blue Sky (Live at Wembley Stadium with the Festival Orchestra)",
                artist: "Electric Light Orchestra and friends", artworkURL: nil,
                appleMusicURL: linked ? URL(string: "https://music.apple.com/") : nil
            ),
            focus: $focus, onSelect: {}
        )
        .frame(width: width, height: artSize + metrics.contentPadding * 2)
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) {
            probe.frames[linked ? "linked" : "reference"] = $0
        }
        .onPreferenceChange(PlayerSongArtworkBounds.self) {
            probe.artworkFrames[linked ? "linked" : "reference"] = $0[.song]
        }
    }
}

@MainActor @Observable
private final class SongLayoutProbe {
    var enabled = true
    var state: SongIDState = .idle
    var infoBounds = CGRect.zero
    var layoutBounds = CGRect.zero
    var appearances = 0
    var disappearances = 0
}

private struct SongLayoutHarness: View {
    let probe: SongLayoutProbe
    let metrics: PlayerCardMetrics
    let width: CGFloat
    @FocusState private var focus: PlayerControls.FocusSlot?

    var body: some View {
        PlayerSongLayout(enabled: probe.enabled, state: probe.state, focus: $focus) {
            Color.gray
                .frame(height: 100)
                .frame(maxWidth: .infinity)
                .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { probe.infoBounds = $0 }
                .onAppear { probe.appearances += 1 }
                .onDisappear { probe.disappearances += 1 }
        }
        .environment(\.playerCardMetrics, metrics)
        .frame(width: width)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { probe.layoutBounds = $0 }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct SongPreviewPlayer: View {
    let engine: NativeVideoEngine
    let player: PlayerViewModel

    var body: some View {
        ZStack {
            VideoSurfaceContainer(engine: engine).ignoresSafeArea()
            #if os(tvOS)
            PlayerControls(
                model: player.controls, player: player, palette: .dark,
                actions: .init(), onExitToSurface: {}
            )
            #else
            PlozziOSPlayerControlsOverlay(
                viewModel: player, keyboardActions: PlozziOSPlayerKeyboardActions(),
                hasVersions: false, versionsPresented: false,
                onShowVersions: {}, onClose: {}
            )
            #endif
        }
        .background(.black)
        .playerPlatformAppearance()
    }
}

private struct SongPreviewProvider: MediaProvider {
    let origin: URL
    let kind = ProviderKind.jellyfin
    let session = UserSession(
        server: .init(id: "preview", name: "Preview", baseURL: URL(string: "https://fixture.invalid")!, provider: .jellyfin),
        userID: "viewer", userName: "Viewer", deviceID: "preview", accessToken: "fixture"
    )
    func libraries() async throws -> [MediaLibrary] { [] }
    func continueWatching(limit: Int) async throws -> [MediaItem] { [] }
    func latest(limit: Int) async throws -> [MediaItem] { [] }
    func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage { throw AppError.notFound }
    func item(id: String) async throws -> MediaItem {
        MediaItem(id: id, title: "Tears of Steel", kind: .movie, runtime: 24, allowsTitleBasedMetadataMatching: false)
    }
    func children(of itemID: String) async throws -> [MediaItem] { [] }
    func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
    func playbackInfo(for itemID: String) async throws -> PlaybackRequest {
        PlaybackRequest(item: try await item(id: itemID), streamURL: origin.appendingPathComponent("film.mp4"))
    }
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {}
    func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { origin.appendingPathComponent("still.jpg") }
}
