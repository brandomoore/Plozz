import CoreModels
@testable import CoreUI
@testable import FeaturePlayback
import SwiftUI
import UIKit
import XCTest

@MainActor
final class PlayerContinueWatchingPresentationTests: XCTestCase {
    func testHostedPresentationPreservesContinueWatchingPreferences() {
        var source = EnvironmentValues()
        source.plozzContinueWatchingPresentation.artworkStyle = .portraitPosters
        source.plozzContinueWatchingPresentation.isShowcase = true
        source.plozzContinueWatchingPlaybackDetails = .progressOnly
        var hosted = EnvironmentValues()
        hosted.copyHostedPresentation(from: source)
        XCTAssertEqual(hosted.plozzContinueWatchingPresentation, source.plozzContinueWatchingPresentation)
        XCTAssertEqual(hosted.plozzContinueWatchingPlaybackDetails, .progressOnly)
    }

    func testHomePreferencesResolveWithoutIntroducingPlayerOverrides() {
        for style in ContinueWatchingArtworkStyle.allCases {
            var presentation = ContinueWatchingPresentation()
            presentation.artworkStyle = style
            for showcase in [false, true] {
                presentation.isShowcase = showcase
                for preference in CardCaptionPreference.allCases {
                    var captions = CardCaptionSettings(preference: preference)
                    XCTAssertEqual(
                        presentation.showsCaptions(captions),
                        style.showsCaptions(settings: captions, isShowcase: showcase)
                    )
                    captions.setOverride(.show, for: .continueWatching)
                    XCTAssertTrue(presentation.showsCaptions(captions))
                    captions.setOverride(.hide, for: .continueWatching)
                    XCTAssertFalse(presentation.showsCaptions(captions))
                }
            }
        }
    }

    func testNativeLayoutMatrixKeepsTheChapterStageHeight() async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !UIApplication.shared.connectedScenes.contains(where: { $0.activationState == .foregroundActive }),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        let cache = try XCTUnwrap(ArtworkSession.shared.configuration.urlCache)
        var urls: [URL] = []
        defer { for url in urls { cache.removeCachedResponse(for: URLRequest(url: url)) } }
        let items = try await makeItems(cache: cache, urls: &urls)
        #if os(tvOS)
        let sizes = [CGSize(width: 1920, height: 1080)]
        #else
        let sizes = [CGSize(width: 1024, height: 768), .init(width: 844, height: 390), .init(width: 390, height: 844)]
        #endif
        for size in sizes {
            #if os(tvOS)
            let metrics = PlayerCardMetrics.tv
            #else
            let metrics = PlayerCardMetrics.resolved(forWidth: size.width, height: size.height)
            #endif
            let model = ContinueWatchingPreviewModel()
            let controls = PlayerControlsModel()
            controls.infoCard.chapters = [
                MediaChapter(start: 0, title: "Opening", imageURL: items[0].backdropURL),
                MediaChapter(start: 360, title: "The journey", imageURL: items[1].backdropURL),
                MediaChapter(start: 720, title: "Arrival", imageURL: items[2].backdropURL),
                MediaChapter(start: 1080, title: "Afterwards", imageURL: items[3].backdropURL)
            ]
            let host = UIHostingController(rootView:
                ContinueWatchingPreview(items: items, model: model, controls: controls, metrics: metrics)
                    .environment(\.colorScheme, .dark)
                    .environment(\.locale, Locale(identifier: "en_US"))
                    .environment(\.plozzArtworkSettings, .init(preference: .library))
            )
            host.safeAreaRegions = []
            window.frame = CGRect(origin: .zero, size: size)
            window.rootViewController = host
            window.makeKeyAndVisible()
            host.view.frame = window.bounds
            try await Task.sleep(for: .milliseconds(300))
            let reference = model.stageFrame
            let transport = model.transportFrame
            let expectedHeight = metrics.isVertical
                ? min(metrics.cardHeight, CGFloat(items.count) * metrics.castRowHeight + CGFloat(items.count - 1) * 8)
                : metrics.cardHeight
            XCTAssertEqual(reference.height, expectedHeight, accuracy: 0.5)
            capture(window, name: "cw-\(Int(size.width))-chapters-reference")

            model.chapters = false
            for style in ContinueWatchingArtworkStyle.allCases {
                model.presentation.artworkStyle = style
                for labels in [true, false] {
                    model.captions = CardCaptionSettings(showsLabels: labels)
                    for details in ContinueWatchingPlaybackDetails.allCases {
                        model.details = details
                        #if os(tvOS)
                        let surfaces = [CardStyle.framed, .borderless]
                        #else
                        let surfaces = [CardStyle.framed]
                        #endif
                        for surface in surfaces {
                            model.cardStyle = surface
                            model.label = "\(style.rawValue) | labels \(labels ? "on" : "off") | \(details.rawValue) | \(surface.rawValue)"
                            try await Task.sleep(for: .milliseconds(250))
                            XCTAssertEqual(model.stageFrame, reference, model.label)
                            XCTAssertEqual(model.transportFrame, transport, model.label)
                            capture(window, name: "cw-\(Int(size.width))-\(style.rawValue)-labels-\(labels)-\(details.rawValue)-\(surface.rawValue)")
                        }
                    }
                }
            }
            #if os(tvOS)
            model.presentation.artworkStyle = .portraitPosters
            model.captions = .init(showsLabels: false)
            model.details = .detailed
            model.cardStyle = .framed
            model.label = "Portrait | detailed | focused | native glass"
            model.target = .continueWatching(items[1].stablePresentationID)
            let focusDeadline = ContinuousClock.now + .seconds(5)
            while model.observedFocus != model.target, ContinuousClock.now < focusDeadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertEqual(model.observedFocus, model.target)
            let focused = try XCTUnwrap(UIFocusSystem.focusSystem(for: window)?.focusedItem)
            XCTAssertGreaterThanOrEqual(focused.frame.height, metrics.cardHeight - 1)
            XCTAssertLessThanOrEqual(focused.frame.height, metrics.cardHeight * 1.10 + 1)
            XCTAssertEqual(model.stageFrame, reference)
            try await Task.sleep(for: .milliseconds(250))
            capture(window, name: "cw-1920-poster-focused")
            model.reducedTransparency = true
            model.label = "Portrait | detailed | reduced transparency"
            try await Task.sleep(for: .milliseconds(250))
            XCTAssertEqual(model.stageFrame, reference)
            capture(window, name: "cw-1920-poster-reduced")
            #endif
        }
    }

    private func capture(_ window: UIWindow, name: String) {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func makeItems(cache: URLCache, urls: inout [URL]) async throws -> [MediaItem] {
        var items: [MediaItem] = []
        for (index, title) in ["Northern Lights", "The Coast", "Desert Skies", "After the Rain"].enumerated() {
            var item = MediaItem(id: "preview-\(index)", title: "The next chapter", kind: .episode)
            item.parentTitle = title
            item.sourceAccountID = index.isMultiple(of: 2) ? "jellyfin-fixture" : "plex-fixture"
            item.seriesID = "series-\(index)"
            item.seasonNumber = index + 1
            item.episodeNumber = index + 3
            item.runtime = index == 3 ? 7_200 : 3_600
            item.resumePosition = Double(index + 1) * 420
            item.playedPercentage = item.resumePosition.map { $0 / (item.runtime ?? 3_600) }
            item.allowsTitleBasedMetadataMatching = false
            for kind in ["poster", "landscape", "thumbnail", "logo"] {
                let url = try XCTUnwrap(URL(string: "https://player-preview.invalid/\(UUID())/\(kind).png"))
                urls.append(url)
                let image = artwork(title: title, index: index, kind: kind)
                let response = try XCTUnwrap(HTTPURLResponse(
                    url: url, statusCode: 200, httpVersion: nil,
                    headerFields: ["Content-Type": "image/png", "Cache-Control": "max-age=86400"]
                ))
                cache.storeCachedResponse(
                    CachedURLResponse(response: response, data: try XCTUnwrap(image.pngData())),
                    for: URLRequest(url: url)
                )
                for variant in [ArtworkImageVariant.posterCard, .landscapeCard] {
                    let loaded = await ArtworkImageCache.shared.image(for: .remote(url), variant: variant)
                    XCTAssertNotNil(loaded)
                }
                switch kind {
                case "poster": item.seriesPosterURL = url
                case "logo": item.logoURL = url
                case "thumbnail": item.posterURL = url
                default:
                    item.backdropURL = url
                    item.heroBackdropURL = url
                    item.fallbackArtworkURL = url
                }
            }
            items.append(item)
        }
        return items
    }

    private func artwork(title: String, index: Int, kind: String) -> UIImage {
        let size = kind == "poster" ? CGSize(width: 400, height: 600)
            : (kind == "logo" ? CGSize(width: 600, height: 130) : CGSize(width: 960, height: 540))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            if kind != "logo" {
                let hue = [0.52, 0.61, 0.06, 0.75][index]
                UIColor(hue: hue, saturation: 0.65, brightness: 0.36, alpha: 1).setFill()
                context.fill(CGRect(origin: .zero, size: size))
                UIColor(hue: hue, saturation: 0.2, brightness: 0.95, alpha: 1).setFill()
                context.cgContext.fillEllipse(in: CGRect(x: size.width * 0.62, y: size.height * 0.1, width: 100, height: 100))
                for band in 0..<4 {
                    let path = UIBezierPath()
                    let y = size.height * (0.40 + Double(band) * 0.14)
                    path.move(to: CGPoint(x: 0, y: y + 75))
                    path.addLine(to: CGPoint(x: size.width * 0.30, y: y - 35))
                    path.addLine(to: CGPoint(x: size.width * 0.65, y: y + 60))
                    path.addLine(to: CGPoint(x: size.width, y: y - 15))
                    path.addLine(to: CGPoint(x: size.width, y: size.height))
                    path.addLine(to: CGPoint(x: 0, y: size.height))
                    path.close()
                    UIColor(hue: hue, saturation: 0.55, brightness: 0.48 - Double(band) * 0.095, alpha: 1).setFill()
                    path.fill()
                }
            }
            if kind == "poster" || kind == "logo" {
                let paragraph = NSMutableParagraphStyle()
                paragraph.alignment = .center
                (title.uppercased() as NSString).draw(
                    in: CGRect(x: 16, y: kind == "poster" ? 48 : 20, width: size.width - 32, height: 150),
                    withAttributes: [
                        .font: UIFont.systemFont(ofSize: kind == "poster" ? 40 : 48, weight: .bold),
                        .foregroundColor: UIColor.white, .paragraphStyle: paragraph
                    ]
                )
            }
        }
    }
}

@MainActor @Observable
private final class ContinueWatchingPreviewModel {
    var presentation = ContinueWatchingPresentation()
    var captions = CardCaptionSettings.default
    var details = ContinueWatchingPlaybackDetails.detailed
    var cardStyle = CardStyle.framed
    var chapters = true
    var reducedTransparency = false
    var label = "Chapters | shared player height reference"
    var stageFrame = CGRect.zero
    var transportFrame = CGRect.zero
    var target: PlayerControls.FocusSlot?
    var observedFocus: PlayerControls.FocusSlot?
}

private struct ContinueWatchingPreview: View {
    let items: [MediaItem]
    let model: ContinueWatchingPreviewModel
    let controls: PlayerControlsModel
    let metrics: PlayerCardMetrics
    @FocusState private var focus: PlayerControls.FocusSlot?

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.isVertical ? 16 : 26) {
            Text(verbatim: model.label).font(.system(size: metrics.captionSize))
                .foregroundStyle(.white.opacity(0.7)).lineLimit(2)
                .frame(height: metrics.captionSize * 3, alignment: .bottomLeading)
            HStack {
                Image(systemName: "play.fill")
                Capsule().fill(.white.opacity(0.35)).frame(height: 4)
                Text(verbatim: "18:42").monospacedDigit()
            }
            .foregroundStyle(.white)
            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { model.transportFrame = $0 }
            HStack(spacing: 24) {
                Text(verbatim: "Info")
                Text(verbatim: "Chapters")
                Button("Continue Watching") {}.focused($focus, equals: .button(.continueWatching))
                    .buttonStyle(.plain)
            }
            .font(metrics.castNameFont)
            .foregroundStyle(.white)
            Group {
                if model.chapters {
                    PlayerChapterPanel(model: controls, spoilerSettings: .default, focus: $focus) { _ in }
                } else {
                    PlayerContinueWatchingPanel(items: items, spoilerSettings: .default, focus: $focus) { _ in }
                }
            }
            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { model.stageFrame = $0 }
        }
        .padding(.horizontal, metrics.isVertical ? 20 : 60)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LinearGradient(
            colors: [Color(red: 0.12, green: 0.19, blue: 0.25), .black],
            startPoint: .topLeading, endPoint: .bottomTrailing
        ))
        .environment(\.playerCardMetrics, metrics)
        .environment(\.plozzCardStyle, model.cardStyle)
        .environment(\.plozzCardCaptionSettings, model.captions)
        .environment(\.plozzContinueWatchingPresentation, model.presentation)
        .environment(\.plozzContinueWatchingPlaybackDetails, model.details)
        .environment(\.plozzReduceTransparency, model.reducedTransparency)
        .onChange(of: model.target) { _, target in focus = target }
        .onChange(of: focus) { _, value in model.observedFocus = value }
    }
}
