import CoreModels
import SwiftUI
import XCTest
import CoreUI
#if os(tvOS)
import Observation
import UIKit
import Vision
#endif

#if os(tvOS)
@MainActor
final class MediaRowEpisodeEntryHostedTests: XCTestCase {
    func testLoadedEpisodesReplaceThePlaceholderWithoutLeavingTheHero() async throws {
        try await assertUnfocusedEpisodeLoad(entranceEnabledBeforeData: false)
    }

    func testReadyPhaseAfterLayoutRevealsEpisodesWithoutNavigation() async throws {
        try await assertUnfocusedEpisodeLoad(entranceEnabledBeforeData: true)
    }

    private func assertUnfocusedEpisodeLoad(entranceEnabledBeforeData: Bool) async throws {
        let image = try await seedImage()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        defer { previous?.makeKeyAndVisible() }
        for style in [CardFocusStyle.highlight, .system] {
            let model = EpisodeEntryFixture()
            model.focusStyle = style
            model.entryEnabled = entranceEnabledBeforeData
            let host = EpisodeEntryHost(model: model)
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
            window.rootViewController = host
            window.makeKeyAndVisible()
            defer {
                window.isHidden = true
                window.rootViewController = nil
            }
            host.view.layoutIfNeeded()
            await waitUntil { model.appeared && host.heroIsFocused }
            model.items = (0..<1000).map {
                MediaItem(id: "episode-\($0)", title: "Episode \($0)", kind: .episode,
                          episodeNumber: $0 + 1, posterURL: image)
            }
            // Item layout, authoritative completion, and entrance focus permission
            // arrive independently; none should need a remote event to settle.
            try await Task.sleep(for: .milliseconds(400))
            model.phase = .ready
            try await Task.sleep(for: .milliseconds(400))
            model.entryEnabled = true
            try await Task.sleep(for: .seconds(1))
            XCTAssertTrue(host.heroIsFocused, "Loading must not take focus away from Play.")
            XCTAssertTrue(model.events.isEmpty, "No remote input or focus handoff is needed to render episodes.")
            let rendered = screenshot(window)
            let text = VNRecognizeTextRequest()
            text.recognitionLevel = .accurate
            text.recognitionLanguages = ["en-US"]
            try VNImageRequestHandler(cgImage: XCTUnwrap(rendered.cgImage)).perform([text])
            XCTAssertFalse(text.results?.contains {
                $0.topCandidates(1).first?.string.contains("Loading episodes") == true
            } == true, "\(style): a loaded row must retire its placeholder without a focus event.")
            _ = try recognizedText("Episode 998", in: rendered)
            capture(window, system: try XCTUnwrap(UIFocusSystem.focusSystem(for: window)),
                    name: "episode-preview-ready-without-navigation-\(style)")
        }
    }

    func testLoadingRowRevealsTheSamePageGradientInItsGutters() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let model = EpisodeEntryFixture()
        let host = EpisodeEntryHost(model: model)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        host.row.view.backgroundColor = .clear
        let background = UIHostingController(rootView: AmbientGradientBackground(
            palette: .dark, tint: [.red, .orange, .purple, .blue]
        ).transaction { $0.disablesAnimations = true })
        host.addChild(background)
        background.view.frame = host.view.bounds
        host.view.insertSubview(background.view, at: 0)
        background.didMove(toParent: host)
        await waitUntil { model.appeared && host.heroIsFocused }
        let image = try await seedImage()
        model.items = (0..<4).map {
            MediaItem(id: "episode-\($0)", title: "Episode \($0)", kind: .episode, posterURL: image)
        }
        for palette in [ThemePalette.dark, .pureBlack, .light] {
            model.palette = palette
            for tint: [Color] in [[.red, .orange, .purple, .blue], [.green, .cyan, .yellow, .mint]] {
                background.rootView = AmbientGradientBackground(palette: palette, tint: tint)
                    .transaction { $0.disablesAnimations = true }
                for phase in [MediaRowEpisodeEntry.Phase.loading, .empty, .failed] {
                    model.phase = phase
                    try await Task.sleep(for: .milliseconds(100))
                    let loading = screenshot(window)
                    host.row.view.isHidden = true
                    let page = screenshot(window)
                    host.row.view.isHidden = false
                    var samples = [CGPoint(x: 10, y: 340), CGPoint(x: 10, y: 480), CGPoint(x: 10, y: 700)]
                    if phase != .loading { samples.append(CGPoint(x: 1_000, y: 400)) }
                    for point in samples {
                        let actual = try pixel(loading, x: Int(point.x), y: Int(point.y))
                        let expected = try pixel(page, x: Int(point.x), y: Int(point.y))
                        for channel in 0..<3 {
                            XCTAssertEqual(Int(actual[channel]), Int(expected[channel]), accuracy: 2,
                                           "\(palette)/\(phase): reveal the page, not a rail-wide fill or hidden episode.")
                        }
                    }
                }
            }
        }
    }

    func testCaptionSamplingDistinguishesAnimationFromAJump() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let host = UIViewController()
        window.rootViewController = host
        let ink = UIView(frame: CGRect(x: 100, y: 100, width: 80, height: 20))
        ink.backgroundColor = .white
        host.view.backgroundColor = .black
        host.view.addSubview(ink)
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        await waitUntil { ink.layer.presentation()?.frame.minY == 100 }
        let region = CGRect(x: 96, y: 96, width: 88, height: 64)
        let start = try titleInkY(in: captionImage(window, region: region))
        UIView.animate(withDuration: 0.18) { ink.frame.origin.y = 116 }
        let animated = try await titleMotion(window, region: region)
        XCTAssertEqual(try XCTUnwrap(animated.last), start + 16, accuracy: 1)
        XCTAssertTrue(animated.contains { $0 > start + 2 && $0 < start + 14 })

        UIView.performWithoutAnimation { ink.frame.origin.y = 100 }
        await waitUntil { ink.layer.presentation()?.frame.minY == 100 }
        UIView.performWithoutAnimation { ink.frame.origin.y = 116 }
        let jumped = try await titleMotion(window, region: region)
        XCTAssertEqual(try XCTUnwrap(jumped.last), start + 16, accuracy: 1)
        XCTAssertFalse(jumped.contains { $0 > start + 2 && $0 < start + 14 },
                       "Sampling must not invent intermediate motion for an unanimated change.")
    }

    func testEpisodeTitleAnimatesDownAndBackWithoutMovingTheRow() async throws {
        try await assertCaptionMotion(loading: false)
    }

    func testLoadingCaptionUsesTheSameFocusMotionAsEpisodes() async throws {
        try await assertCaptionMotion(loading: true)
    }

    func testEpisodeDescriptionsRemainVisibleUntilFocusOnlyIsEnabled() async throws {
        try await assertDescriptionVisibility(reduceMotion: false)
    }

    func testEpisodeDescriptionVisibilityWithReducedMotion() async throws {
        try await assertDescriptionVisibility(reduceMotion: true)
    }

    private func assertDescriptionVisibility(reduceMotion: Bool) async throws {
        let artwork = try await seedImage()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        defer { previous?.makeKeyAndVisible() }
        for style in [CardFocusStyle.highlight, .system] {
            let model = EpisodeEntryFixture()
            model.focusStyle = style
            model.reduceMotion = reduceMotion
            model.resumeTarget = "first"
            model.phase = .ready
            model.items = [
                MediaItem(id: "first", title: "First episode", kind: .episode,
                          overview: "First summary stays visible.", episodeNumber: 1, posterURL: artwork),
                MediaItem(id: "second", title: "Second episode", kind: .episode,
                          overview: "Second summary stays visible.", episodeNumber: 2, posterURL: artwork)
            ]
            let host = EpisodeEntryHost(model: model)
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
            window.rootViewController = host
            window.makeKeyAndVisible()
            defer {
                window.isHidden = true
                window.rootViewController = nil
            }
            host.view.layoutIfNeeded()
            await waitUntil { model.appeared && host.heroIsFocused }
            let system = try XCTUnwrap(UIFocusSystem.focusSystem(for: window))
            func visibleText() async throws -> String {
                try await Task.sleep(for: .milliseconds(500))
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.recognitionLanguages = ["en-US"]
                try VNImageRequestHandler(cgImage: XCTUnwrap(screenshot(window).cgImage)).perform([request])
                return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
            }
            var text = try await visibleText()
            XCTAssertTrue(text.contains("First summary"), text)
            XCTAssertTrue(text.contains("Second summary"), text)
            XCTAssertTrue(host.heroIsFocused)
            capture(window, system: system, name: "episode-descriptions-always-\(style)")

            model.captions.episodeDescriptionsOnFocus = true
            text = try await visibleText()
            XCTAssertFalse(text.contains("summary"), text)
            XCTAssertTrue(text.contains("First episode"), text)
            host.prefersRow = true
            system.requestFocusUpdate(to: host)
            system.updateFocusIfNeeded()
            await waitUntil { model.events.last == "first" }
            text = try await visibleText()
            XCTAssertTrue(text.contains("First summary"), text)
            XCTAssertFalse(text.contains("Second summary"), text)
            host.prefersRow = false
            system.requestFocusUpdate(to: host)
            system.updateFocusIfNeeded()
            await waitUntil { host.heroIsFocused }
            text = try await visibleText()
            XCTAssertFalse(text.contains("summary"), text)

            model.captions.episodeDescriptionsOnFocus = false
            text = try await visibleText()
            XCTAssertTrue(text.contains("First summary"), text)
            XCTAssertTrue(text.contains("Second summary"), text)
            model.captions.setOverride(.hide, for: .episodes)
            text = try await visibleText()
            XCTAssertFalse(text.contains("summary"), text)
            XCTAssertFalse(text.contains("First episode"), text)
            model.captions.setOverride(.show, for: .episodes)
            model.spoilers = SpoilerSettings(isEnabled: true, mode: .placeholder)
            text = try await visibleText()
            XCTAssertFalse(text.contains("summary"), text)
            XCTAssertFalse(text.contains("First episode"), text)
        }
    }

    private func assertCaptionMotion(loading: Bool) async throws {
        let artwork = try await seedImage()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        defer { previous?.makeKeyAndVisible() }
        for style in CardFocusStyle.allCases {
            let model = EpisodeEntryFixture()
            model.focusStyle = style
            model.captions.episodeDescriptionsOnFocus = true
            model.resumeTarget = "episode-motion"
            var episode = MediaItem(
                id: model.resumeTarget, title: "The Hidden Room", kind: .episode,
                episodeNumber: 4, posterURL: artwork
            )
            episode.overview = "A secret behind the door."
            model.items = loading ? [] : [episode]
            model.phase = loading ? .loading : .ready
            let host = EpisodeEntryHost(model: model)
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
            window.rootViewController = host
            host.view.backgroundColor = .black
            host.row.view.backgroundColor = .clear
            window.makeKeyAndVisible()
            defer {
                window.isHidden = true
                window.rootViewController = nil
            }
            host.view.layoutIfNeeded()
            await waitUntil { model.appeared && host.heroIsFocused }
            try await Task.sleep(for: .milliseconds(400))
            let before = screenshot(window)
            let title = try recognizedText(loading ? "Loading episodes" : "The Hidden Room", in: before)
            let push = PlozzMetrics.standard.focusCaptionPush
            let region = CGRect(
                x: title.minX - 2, y: title.minY - 2,
                width: title.width + 4, height: title.height + push + 4
            )
            let rowFrame = host.row.view.frame
            let initialY = try titleInkY(in: captionImage(window, region: region))
            let system = try XCTUnwrap(UIFocusSystem.focusSystem(for: window))
            host.prefersRow = true
            system.requestFocusUpdate(to: host)
            system.updateFocusIfNeeded()
            let entering = try await titleMotion(window, region: region)
            XCTAssertFalse(host.heroIsFocused)
            XCTAssertTrue(model.events.contains(loading ? "placeholder" : episode.id))
            let focusedY = try XCTUnwrap(entering.last)
            XCTAssertEqual(focusedY - initialY, reduceMotion ? 0 : push, accuracy: 2,
                           "\(style): the title itself must move down by the reserved clearance.")
            if !loading {
                _ = try recognizedText("A secret behind the door", in: screenshot(window))
            }
            capture(window, system: system, name: "episode-caption-focused-\(style)-\(loading)-\(reduceMotion)")

            host.prefersRow = false
            system.requestFocusUpdate(to: host)
            system.updateFocusIfNeeded()
            let leaving = try await titleMotion(window, region: region)
            XCTAssertTrue(host.heroIsFocused)
            XCTAssertEqual(try XCTUnwrap(leaving.last), initialY, accuracy: 2)
            XCTAssertEqual(host.row.view.frame, rowFrame, "Caption movement must not shift or resize the rail.")
            if reduceMotion {
                XCTAssertTrue((entering + leaving).allSatisfy { abs($0 - initialY) <= 2 },
                              "\(style): Reduce Motion must keep the title stationary.")
            } else {
                for samples in [entering, leaving] {
                    XCTAssertTrue(samples.contains { $0 > initialY + 2 && $0 < focusedY - 2 },
                                  "\(style): title movement must animate, not jump between endpoints: \(samples)")
                }
            }
            let attachment = XCTAttachment(string: "initial=\(initialY)\nentering=\(entering)\nleaving=\(leaving)")
            attachment.name = "episode-title-motion-\(style)-\(loading)-\(reduceMotion)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    private func recognizedText(_ value: String, in image: UIImage) throws -> CGRect {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
        let observation = try XCTUnwrap(request.results?.first {
            $0.topCandidates(1).first?.string.contains(value) == true
        }, "Missing rendered text: \(value)")
        let bounds = observation.boundingBox
        return CGRect(
            x: bounds.minX * image.size.width, y: (1 - bounds.maxY) * image.size.height,
            width: bounds.width * image.size.width, height: bounds.height * image.size.height
        )
    }

    private func captionImage(_ window: UIWindow, region: CGRect) throws -> UIImage {
        let presentation = try XCTUnwrap(window.layer.presentation())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        // Sample composited pixels without asking UIKit to snapshot/layout the whole hierarchy.
        return UIGraphicsImageRenderer(size: region.size, format: format).image { context in
            context.cgContext.translateBy(x: -region.minX, y: -region.minY)
            presentation.render(in: context.cgContext)
        }
    }

    private func titleMotion(_ window: UIWindow, region: CGRect) async throws -> [CGFloat] {
        var positions: [CGFloat] = []
        let deadline = ContinuousClock.now + .milliseconds(650)
        repeat {
            positions.append(try titleInkY(in: captionImage(window, region: region)))
            try await Task.sleep(for: .milliseconds(10))
        } while ContinuousClock.now < deadline
        return positions
    }

    private func titleInkY(in image: UIImage) throws -> CGFloat {
        let cgImage = try XCTUnwrap(image.cgImage)
        var bytes = [UInt8](repeating: 0, count: cgImage.width * cgImage.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(
                data: buffer.baseAddress, width: cgImage.width, height: cgImage.height,
                bitsPerComponent: 8, bytesPerRow: cgImage.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        }
        let firstRow = (0..<cgImage.height).first { y in
            (0..<cgImage.width).filter { x in
                let index = (y * cgImage.width + x) * 4
                return bytes[index] > 220 && bytes[index + 1] > 220 && bytes[index + 2] > 220
            }.count >= 3
        }
        return CGFloat(try XCTUnwrap(firstRow, "The episode title must remain rendered during focus changes."))
    }

    func testDetailEpisodeLabelsHonorPresetsAndOverrides() async throws {
        let image = try await seedImage()
        let episode = MediaItem(
            id: "episode-label-fixture", title: "The Hidden Room", kind: .episode,
            episodeNumber: 4, posterURL: image
        )
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        for style in [CardFocusStyle.system, .highlight] {
            for (preference, override, visible) in [
                (CardCaptionPreference.recommended, CardCaptionOverride.automatic, true),
                (.show, .automatic, true), (.hide, .automatic, false),
                (.hide, .show, true), (.show, .hide, false),
            ] {
                var settings = CardCaptionSettings(preference: preference)
                settings.setOverride(override, for: .episodes)
                let host = UIHostingController(
                    rootView:
                        EpisodeColumnCard(item: episode, action: {})
                        .environment(\.plozzCardCaptionView, .episodes)
                        .environment(\.plozzCardCaptionSettings, settings)
                        .environment(\.plozzCardFocusStyle, style)
                        .environment(\.themePalette, .dark)
                        .preferredColorScheme(.dark)
                )
                window.rootViewController = host
                window.makeKeyAndVisible()
                window.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(400))
                let rendered = screenshot(window)
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.recognitionLanguages = ["en-US"]
                try VNImageRequestHandler(cgImage: XCTUnwrap(rendered.cgImage)).perform([request])
                let copy = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(
                    separator: " ")
                XCTAssertEqual(
                    copy.contains("The Hidden Room"), visible, "\(style) / \(preference) / \(override): \(copy)")
                XCTAssertEqual(
                    copy.contains("E4"), visible, "\(style): the episode designation belongs to the caption.")
                let attachment = XCTAttachment(image: rendered)
                attachment.name = "detail-episode-labels-\(style)-\(preference)-\(override)"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }

    func testContinueWatchingCaptionsHonorPresetsAndHomeOverrides() async throws {
        let image = try await seedImage(variants: ArtworkImageVariant.allCases)
        let item = MediaItem(
            id: "series-caption-fixture", title: "Moonrise", kind: .movie,
            backdropURL: image
        )
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        for style in [CardFocusStyle.system, .highlight] {
            for cardStyle in CardStyle.allCases {
                for (preference, override, visible) in [
                    (CardCaptionPreference.recommended, CardCaptionOverride.automatic, false),
                    (.show, .automatic, true), (.hide, .automatic, false),
                    (.recommended, .show, true), (.show, .hide, false), (.hide, .show, true),
                ] {
                    var settings = CardCaptionSettings(preference: preference)
                    settings.setOverride(override, for: .home)
                    let host = UIHostingController(
                        rootView:
                            PosterCardView(
                                item: item, style: .landscape, showsSeriesArtwork: true,
                                enablesAsyncArtworkFallback: false, action: {}
                            )
                            .frame(width: 500)
                            .environment(\.plozzCardCaptionView, .home)
                            .environment(\.plozzCardCaptionSettings, settings)
                            .environment(\.plozzCardFocusStyle, style)
                            .environment(\.plozzCardStyle, cardStyle)
                            .environment(\.themePalette, .dark)
                            .preferredColorScheme(.dark)
                    )
                    window.rootViewController = host
                    window.makeKeyAndVisible()
                    window.layoutIfNeeded()
                    try await Task.sleep(for: .milliseconds(500))
                    let rendered = screenshot(window)
                    let request = VNRecognizeTextRequest()
                    request.recognitionLevel = .accurate
                    request.recognitionLanguages = ["en-US"]
                    try VNImageRequestHandler(cgImage: XCTUnwrap(rendered.cgImage)).perform([request])
                    let titles = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                        .filter { $0.localizedCaseInsensitiveContains("Moonrise") }
                    XCTAssertEqual(
                        titles.count, visible ? 2 : 1,
                        "\(style) / \(cardStyle) / \(preference) / \(override): \(titles)")
                    let attachment = XCTAttachment(image: rendered)
                    attachment.name = "series-caption-\(style)-\(cardStyle)-\(preference)-\(override)"
                    attachment.lifetime = .keepAlways
                    add(attachment)
                }
            }
        }
    }

    func testEntranceGateKeepsTheEpisodePreviewOutOfFocusUntilEnabled() async throws {
        let image = try await seedImage()
        let model = EpisodeEntryFixture()
        model.items = [MediaItem(id: "episode-998", title: "Episode", kind: .episode, posterURL: image)]
        model.phase = .ready
        model.entryEnabled = false
        let host = EpisodeEntryHost(model: model)
        await waitUntil { UIApplication.shared.connectedScenes.contains { $0.activationState == .foregroundActive } }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        await waitUntil { model.appeared && host.heroIsFocused }
        let height = host.row.view.bounds.height
        let system = try XCTUnwrap(UIFocusSystem.focusSystem(for: window))
        host.prefersRow = true
        system.requestFocusUpdate(to: host)
        system.updateFocusIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(host.heroIsFocused)
        XCTAssertTrue(model.events.isEmpty)
        model.entryEnabled = true
        host.row.view.layoutIfNeeded()
        system.requestFocusUpdate(to: host)
        system.updateFocusIfNeeded()
        await waitUntil { model.events.contains("episode-998") }
        XCTAssertEqual(host.row.view.bounds.height, height, accuracy: 0.5)
    }

    func testFocusedLoadingCardKeepsItsLeadingOverflow() async throws {
        await waitUntil { UIApplication.shared.connectedScenes.contains { $0.activationState == .foregroundActive } }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        for style in CardFocusStyle.allCases {
            let model = EpisodeEntryFixture()
            model.focusStyle = style
            let host = EpisodeEntryHost(model: model)
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
            window.rootViewController = host
            window.makeKeyAndVisible()
            defer {
                window.isHidden = true
                window.rootViewController = nil
            }
            host.view.layoutIfNeeded()
            await waitUntil { host.row.view.window != nil && model.appeared && host.heroIsFocused }
            let before = screenshot(window)
            let system = try XCTUnwrap(UIFocusSystem.focusSystem(for: window))
            host.prefersRow = true
            system.requestFocusUpdate(to: host)
            system.updateFocusIfNeeded()
            await waitUntil { model.events.contains("placeholder") }
            // Wait for rendered overflow, not merely a FocusState callback.
            let rowFrame = host.row.view.convert(host.row.view.bounds, to: window)
            let x = Int(rowFrame.minX + host.row.view.safeAreaInsets.left + PlozzTheme.Metrics.screenPadding - 4)
            let y = Int(rowFrame.minY + EpisodeColumnCard.artworkSize.height / 2)
            XCTAssertGreaterThanOrEqual(x, 0)
            let unfocusedPixel = try pixel(before, x: x, y: y)
            var overflowVisible = false
            let deadline = ContinuousClock.now + .seconds(3)
            while !overflowVisible, ContinuousClock.now < deadline {
                let focusedPixel = try pixel(screenshot(window), x: x, y: y)
                overflowVisible = zip(focusedPixel.prefix(3), unfocusedPixel.prefix(3))
                    .contains { abs(Int($0.0) - Int($0.1)) > 3 }
                if !overflowVisible { try await Task.sleep(for: .milliseconds(30)) }
            }
            XCTAssertTrue(overflowVisible, "Focused \(style) thumbnail was clipped at the row's leading edge")
            capture(window, system: system, name: "episode-placeholder-overflow-\(style)")
        }
    }

    func testFocusedLoadingSlotHandsOffToTheFarEpisodeAfterDataArrives() async throws {
        try await assertEpisodeHandoff(focusStyle: .highlight)
    }

    func testHiddenPinnedSidebarDoesNotClipEpisodesAtTheContentInset() async throws {
        let image = try await seedImage()
        await waitUntil { UIApplication.shared.connectedScenes.contains { $0.activationState == .foregroundActive } }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        defer { previous?.makeKeyAndVisible() }

        for style in CardFocusStyle.allCases {
            let model = EpisodeEntryFixture()
            model.focusStyle = style
            model.pinnedSidebarActive = true
            model.resumeTarget = "episode-0"
            model.items = (0..<20).map {
                MediaItem(
                    id: "episode-\($0)", title: "Episode \($0)", kind: .episode,
                    episodeNumber: $0 + 1, posterURL: image
                )
            }
            model.phase = .ready
            let host = EpisodeEntryHost(model: model)
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
            window.rootViewController = host
            host.view.backgroundColor = .black
            host.row.view.backgroundColor = .clear
            window.makeKeyAndVisible()
            defer {
                window.isHidden = true
                window.rootViewController = nil
            }
            host.view.layoutIfNeeded()
            await waitUntil { model.appeared && host.heroIsFocused }
            let system = try XCTUnwrap(UIFocusSystem.focusSystem(for: window))
            host.prefersRow = true
            system.requestFocusUpdate(to: host)
            system.updateFocusIfNeeded()
            await waitUntil { model.events.contains("episode-0") }
            XCTAssertFalse(host.heroIsFocused)
            XCTAssertNotNil(system.focusedItem)
            let rowFrame = host.row.view.convert(host.row.view.bounds, to: window)
            let insetEdge = rowFrame.minX + host.row.view.safeAreaInsets.left
            let y = Int(rowFrame.minY + EpisodeColumnCard.artworkSize.height / 2)
            XCTAssertGreaterThan(insetEdge, 10, "This fixture must exercise an inset row viewport.")
            try await assertRedPixel(
                in: window, x: Int(insetEdge) - 4, y: y,
                message: "Focused \(style) episode must extend into the empty page gutter."
            )
            capture(window, system: system, name: "episode-focused-page-gutter-\(style)")

            host.prefersRow = false
            system.requestFocusUpdate(to: host)
            system.updateFocusIfNeeded()
            await waitUntil { host.heroIsFocused }
            let scroll = try XCTUnwrap(horizontalScroll(in: host.row.view))
            scroll.setContentOffset(
                CGPoint(x: scroll.contentOffset.x + 240, y: scroll.contentOffset.y),
                animated: false
            )
            try await assertRedPixel(
                in: window, x: 2, y: y,
                message: "A scrolling \(style) episode must remain visible up to the physical screen edge."
            )
            capture(window, system: system, name: "episode-at-screen-edge-\(style)")

            let offset = scroll.contentOffset
            let unobscured = screenshot(window)
            model.navigationInset = 64
            try await assertRedPixel(
                in: window, x: Int(insetEdge) + 2, y: y, present: false,
                message: "The visible sidebar must dim scrolling \(style) artwork under its icons."
            )
            let underSidebar = screenshot(window)
            for x in [2, Int(insetEdge) + 2] {
                let original = try pixel(unobscured, x: x, y: y)
                let faint = try pixel(underSidebar, x: x, y: y)
                XCTAssertGreaterThan(original[0], 150, "Sample actual artwork, including at the physical screen edge.")
                XCTAssertEqual(Double(faint[0]), Double(original[0]) * 0.1, accuracy: 3,
                               "Retain 10% of \(style) artwork beneath the pinned sidebar.")
            }
            for offset in [12, 16, 20, 30, 42, 46, 50, 54, 58, 64] {
                let x = Int(insetEdge) + offset
                let original = try pixel(unobscured, x: x, y: y)
                let faded = try pixel(underSidebar, x: x, y: y)
                // The 48pt feather starts at 16pt and is fully opaque at 64pt.
                let t = max(0, min(1, (Double(offset - 16) + 0.5) / 48))
                let opacity = 0.1 + 0.9 * t * t * (3 - 2 * t)
                XCTAssertGreaterThan(original[0], 150)
                XCTAssertEqual(Double(faded[0]), Double(original[0]) * opacity, accuracy: 3,
                               "Keep the \(style) feather 48pt wide, starting at 16pt with its opaque edge at 64pt.")
            }
            try await assertRedPixel(
                in: window, x: Int(insetEdge) + 64, y: y,
                message: "The visible sidebar must keep \(style) artwork opaque past its feather."
            )
            XCTAssertTrue(horizontalScroll(in: host.row.view) === scroll)
            model.navigationInset = 0
            try await assertRedPixel(
                in: window, x: 2, y: y,
                message: "Hiding the sidebar again must restore edge-to-edge \(style) artwork."
            )
            XCTAssertTrue(horizontalScroll(in: host.row.view) === scroll)
            XCTAssertEqual(scroll.contentOffset.x, offset.x, accuracy: 0.5)
            XCTAssertEqual(scroll.contentOffset.y, offset.y, accuracy: 0.5)
        }
    }

    private func horizontalScroll(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView, scroll.contentSize.width > scroll.bounds.width {
            return scroll
        }
        return view.subviews.lazy.compactMap { self.horizontalScroll(in: $0) }.first
    }

    private func assertRedPixel(
        in window: UIWindow, x: Int, y: Int, present: Bool = true, message: String
    ) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        var matches = false
        while !matches, ContinuousClock.now < deadline {
            let sample = try pixel(screenshot(window), x: x, y: y)
            let isRed = sample[0] > 150 && sample[1] < 100 && sample[2] < 100
            matches = isRed == present
            if !matches { try await Task.sleep(for: .milliseconds(30)) }
        }
        XCTAssertTrue(matches, message)
    }

    func testSystemFocusHandsOffAndRestoresTheBrowsedEpisode() async throws {
        try await assertEpisodeHandoff(focusStyle: .system)
    }

    func testReenteringEpisodesKeepsTheBrowsedCardInPlace() async throws {
        let image = try await seedImage()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        defer { previous?.makeKeyAndVisible() }
        for style in CardFocusStyle.allCases {
            let model = EpisodeEntryFixture()
            model.focusStyle = style
            model.resumeTarget = "episode-0"
            model.items = (0..<20).map {
                MediaItem(id: "episode-\($0)", title: "Episode \($0)", kind: .episode,
                          episodeNumber: $0 + 1, posterURL: image)
            }
            model.phase = .ready
            let host = EpisodeEntryHost(model: model)
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
            window.rootViewController = host
            window.makeKeyAndVisible()
            defer {
                window.isHidden = true
                window.rootViewController = nil
            }
            host.view.layoutIfNeeded()
            await waitUntil { model.appeared && host.heroIsFocused }
            let system = try XCTUnwrap(UIFocusSystem.focusSystem(for: window))
            host.prefersRow = true
            system.requestFocusUpdate(to: host)
            system.updateFocusIfNeeded()
            await waitUntil { model.events.last == "episode-0" }
            let scroll = try XCTUnwrap(horizontalScroll(in: host.row.view))
            await waitUntil { self.neighbor(of: system.focusedItem, in: host.row.view, toLeft: false) != nil }
            let next = try XCTUnwrap(neighbor(of: system.focusedItem, in: host.row.view, toLeft: false))
            host.preferredItem = next
            system.requestFocusUpdate(to: host)
            system.updateFocusIfNeeded()
            await waitUntil { system.focusedItem.map(ObjectIdentifier.init) == ObjectIdentifier(next) }
            await waitUntil { model.events.last?.hasPrefix("episode-") == true && model.events.last != "episode-0" }
            let browsedID = try XCTUnwrap(model.events.last)
            try await waitForScrollToSettle(scroll)
            let originalOffset = scroll.contentOffset.x

            for _ in 0..<3 {
                host.preferredItem = nil
                host.prefersRow = false
                system.requestFocusUpdate(to: host)
                system.updateFocusIfNeeded()
                await waitUntil { host.heroIsFocused }
                model.active = true
                model.resetToken += 1
                try await Task.sleep(for: .milliseconds(400))
                XCTAssertEqual(scroll.contentOffset.x, originalOffset, accuracy: 1,
                               "\(style): leaving a row must not leading-align an already-visible episode.")
                let reports = model.events.count
                host.prefersRow = true
                system.requestFocusUpdate(to: host)
                system.updateFocusIfNeeded()
                await waitUntil { model.events.count > reports && model.events.last == browsedID }
                XCTAssertEqual(scroll.contentOffset.x, originalOffset, accuracy: 1)
            }
            capture(window, system: system, name: "episode-reentry-position-\(style)")
        }
    }

    private func assertEpisodeHandoff(focusStyle: CardFocusStyle) async throws {
        let settingsStore = MetadataProviderSettingsStore()
        let original = settingsStore.load()
        var local = original
        local.preferOnlineArtwork = false
        settingsStore.save(local)
        defer { settingsStore.save(original) }
        let imageURL = try await seedImage()
        let model = EpisodeEntryFixture()
        model.focusStyle = focusStyle
        let host = EpisodeEntryHost(model: model)
        await waitUntil { UIApplication.shared.connectedScenes.contains { $0.activationState == .foregroundActive } }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        host.view.layoutIfNeeded()
        await waitUntil { host.row.view.window != nil && model.appeared }
        window.layoutIfNeeded()
        await Task.yield()
        let system = try XCTUnwrap(UIFocusSystem.focusSystem(for: window))
        host.prefersRow = true
        system.requestFocusUpdate(to: host)
        system.updateFocusIfNeeded()
        await waitUntil { model.events.contains("placeholder") }
        capture(window, system: system, name: "episode-entry-loading")
        let loadingFocus = try XCTUnwrap(system.focusedItem)
        XCTAssertFalse(model.events.contains("episode-0"))
        model.items = (0..<1000).map { (number: Int) in
            MediaItem(
                id: "episode-\(number)", title: "Episode \(number)", kind: .episode,
                seasonNumber: 20, episodeNumber: number, posterURL: imageURL
            )
        }
        model.phase = .ready
        host.view.layoutIfNeeded()
        await waitUntil { model.events.contains("episode-998") }
        await waitUntil {
            system.focusedItem.map { ObjectIdentifier($0) != ObjectIdentifier(loadingFocus) } == true
        }
        capture(window, system: system, name: "episode-entry-loaded")
        XCTAssertEqual(model.events.filter { $0.hasPrefix("episode-") }, ["episode-998"])

        // Browse a different real card, return to the hero, and change the server's
        // resume target. Re-entry must preserve the viewer's browse position.
        await waitUntil { self.neighbor(of: system.focusedItem, in: host.row.view, toLeft: true) != nil }
        let browsed = try XCTUnwrap(neighbor(of: system.focusedItem, in: host.row.view, toLeft: true))
        let beforeBrowsing = model.events.count
        host.preferredItem = browsed
        system.requestFocusUpdate(to: host)
        system.updateFocusIfNeeded()
        await waitUntil {
            model.events.count > beforeBrowsing
                && model.events.last?.hasPrefix("episode-") == true
                && model.events.last != "episode-998"
        }
        let browsedID = try XCTUnwrap(model.events.last)
        XCTAssertNotEqual(browsedID, "episode-900")
        host.preferredItem = nil
        host.prefersRow = false
        model.active = true
        system.requestFocusUpdate(to: host)
        system.updateFocusIfNeeded()
        await waitUntil { host.heroIsFocused }
        model.resumeTarget = "episode-900"
        host.view.layoutIfNeeded()
        let reports = model.events.count
        host.prefersRow = true
        system.requestFocusUpdate(to: host)
        system.updateFocusIfNeeded()
        await waitUntil { model.events.count > reports && model.events.last == browsedID }
        capture(window, system: system, name: "episode-entry-remembered")
    }

    private func neighbor(
        of focused: (any UIFocusItem)?, in root: UIView, toLeft: Bool
    ) -> (any UIFocusItem)? {
        guard let focused, let current = frame(focused, in: root) else { return nil }
        var seen = Set<ObjectIdentifier>()
        func items(_ view: UIView) -> [any UIFocusItem] {
            let own = view.focusItemContainer?.focusItems(in: view.bounds) ?? []
            return own + view.subviews.flatMap(items)
        }
        return items(root).compactMap { item -> ((any UIFocusItem), CGRect)? in
            guard seen.insert(ObjectIdentifier(item)).inserted,
                  item.canBecomeFocused, let rect = frame(item, in: root),
                  rect.width > 300, rect.width < 800,
                  toLeft ? rect.midX < current.midX - 20 : rect.midX > current.midX + 20 else { return nil }
            return (item, rect)
        }.min { abs($0.1.midX - current.midX) < abs($1.1.midX - current.midX) }?.0
    }

    private func waitForScrollToSettle(_ scroll: UIScrollView) async throws {
        let deadline = ContinuousClock.now + .seconds(4)
        var previous = scroll.contentOffset
        var stableSamples = 0
        while stableSamples < 10, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(25))
            let current = scroll.contentOffset
            stableSamples = abs(current.x - previous.x) < 0.1 && abs(current.y - previous.y) < 0.1
                ? stableSamples + 1 : 0
            previous = current
        }
        XCTAssertEqual(stableSamples, 10, "The native scroll must settle before measuring re-entry.")
    }

    private func frame(_ item: any UIFocusItem, in root: UIView) -> CGRect? {
        if let view = item as? UIView { return view.convert(view.bounds, to: root) }
        var parent = item.parentFocusEnvironment
        while let environment = parent {
            if let container = environment.focusItemContainer {
                let space: any UICoordinateSpace = root
                return space.convert(item.frame, from: container.coordinateSpace)
            }
            parent = environment.parentFocusEnvironment
        }
        return nil
    }

    private func capture(_ window: UIWindow, system: UIFocusSystem, name: String) {
        let image = screenshot(window)
        let picture = XCTAttachment(image: image)
        picture.name = name
        picture.lifetime = .keepAlways
        add(picture)
        func describe(_ view: UIView, depth: Int = 0) -> String {
            guard depth < 12 else { return "" }
            let line = "\(String(repeating: " ", count: depth))\(type(of: view)) frame=\(view.frame) alpha=\(view.alpha) hidden=\(view.isHidden) focusable=\(view.canBecomeFocused)\n"
            return line + view.subviews.map { describe($0, depth: depth + 1) }.joined()
        }
        let tree = XCTAttachment(string: "Focused: \(String(describing: system.focusedItem))\n" + describe(window))
        tree.name = "\(name)-hierarchy"
        tree.lifetime = .keepAlways
        add(tree)
    }

    private func screenshot(_ window: UIWindow) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
    }

    private func pixel(_ image: UIImage, x: Int, y: Int) throws -> [UInt8] {
        let cgImage = try XCTUnwrap(image.cgImage)
        let cropped = try XCTUnwrap(cgImage.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)))
        var bytes = [UInt8](repeating: 0, count: 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(
                data: buffer.baseAddress, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(cropped, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return bytes
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(8)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), "Native hosted episode entry did not reach the expected destination")
    }

    private func seedImage(variants: [ArtworkImageVariant] = [.landscapeCard]) async throws -> URL {
        let url = URL(string: "https://episode-entry.example.test/\(UUID()).png")!
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 9), format: format).image {
            UIColor.red.setFill()
            $0.fill(CGRect(x: 0, y: 0, width: 16, height: 9))
        }
        let data = try XCTUnwrap(image.pngData())
        let cache = try XCTUnwrap(ArtworkSession.shared.configuration.urlCache)
        for variant in variants {
            let requestURL = variant.requestURL(for: url)
            let response = try XCTUnwrap(HTTPURLResponse(
                url: requestURL, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "image/png", "Cache-Control": "max-age=3600"]
            ))
            cache.storeCachedResponse(CachedURLResponse(response: response, data: data),
                                      for: URLRequest(url: requestURL))
            let decoded = await ArtworkImageCache.shared.image(for: url, variant: variant)
            _ = try XCTUnwrap(decoded)
            cache.removeCachedResponse(for: URLRequest(url: requestURL))
        }
        return url
    }
}

@MainActor
@Observable
private final class EpisodeEntryFixture {
    var items: [MediaItem] = []
    var phase = MediaRowEpisodeEntry.Phase.loading
    var active = true
    var resetToken = 0
    var entryEnabled = true
    var resumeTarget = "episode-998"
    var focusStyle = CardFocusStyle.highlight
    var palette = ThemePalette.dark
    var pinnedSidebarActive = false
    var navigationInset: CGFloat = 0
    var captions = CardCaptionSettings.default
    var spoilers = SpoilerSettings.default
    var reduceMotion = UIAccessibility.isReduceMotionEnabled
    @ObservationIgnored var appeared = false
    @ObservationIgnored var events: [String] = []
}

private struct EpisodeEntryFixtureView: View {
    let model: EpisodeEntryFixture
    var body: some View {
        MediaRowView(
            title: nil, items: model.items, presentation: .episodeColumn,
            spoilerSettings: model.spoilers,
            initialScrollID: model.resumeTarget, defaultFocusID: model.resumeTarget,
            focusResetToken: model.resetToken,
            onFocusEntered: { model.active = false },
            onFocusChange: { if let item = $0 { model.events.append(item.id) } },
            episodeEntry: MediaRowEpisodeEntry(
                phase: model.phase, isActive: model.active, isEnabled: model.entryEnabled,
                onPlaceholderFocus: {
                    model.events.append("placeholder")
                    model.active = false
                }
            ),
            onSelect: { _ in }
        )
        .frame(height: 520)
        .environment(\.plozzCardFocusStyle, model.focusStyle)
        .environment(\.themePalette, model.palette)
        .environment(\.plozzCardCaptionView, .episodes)
        .environment(\.plozzCardCaptionSettings, model.captions)
        .environment(\._accessibilityReduceMotion, model.reduceMotion)
        .preferredColorScheme(.dark)
        .environment(\.plozzPinnedSidebarActive, model.pinnedSidebarActive)
        .environment(\.plozzNavigationContentInset, model.navigationInset)
        .onAppear { model.appeared = true }
    }
}

@MainActor
private final class EpisodeEntryHost: UIViewController {
    let row: UIHostingController<EpisodeEntryFixtureView>
    private let hero = UIButton(type: .system)
    var prefersRow = false
    var preferredItem: (any UIFocusEnvironment)?
    var heroIsFocused: Bool { hero.isFocused }

    init(model: EpisodeEntryFixture) {
        row = UIHostingController(rootView: EpisodeEntryFixtureView(model: model))
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var preferredFocusEnvironments: [any UIFocusEnvironment] {
        if let preferredItem { return [preferredItem] }
        return prefersRow ? [row] : [hero]
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        hero.setTitle("Play", for: .normal)
        hero.frame = CGRect(x: 100, y: 100, width: 200, height: 60)
        view.addSubview(hero)
        addChild(row)
        row.view.frame = CGRect(x: 0, y: 300, width: 1920, height: 520)
        view.addSubview(row.view)
        row.didMove(toParent: self)
    }
}
#endif
