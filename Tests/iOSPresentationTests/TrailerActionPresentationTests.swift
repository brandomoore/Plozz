#if os(iOS)
import AVFoundation
import CoreModels
import CoreUI
import FeatureHomeCore
import Observation
import SwiftUI
import UIKit
import Vision
import XCTest
@testable import AppShelliOS

@MainActor
final class TrailerActionPresentationTests: XCTestCase {
    func testHomeToDetailRetainsTrailerAcrossSurfaceDisappearance() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let directory = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "Fixtures", withExtension: nil
        )).appendingPathComponent("active-picture-hls")
        let server = try SubtitleFixtureServer(directory: directory)
        defer { server.stop() }
        let port = try await server.start()
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/active-picture.m3u8"))
        let fixture = TrailerHandoffFixture(url: url)
        let host = UIHostingController(rootView: TrailerHandoffRoot(fixture: fixture))
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            fixture.controller.stop()
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        let deadline = ContinuousClock.now + .seconds(15)
        while !(fixture.controller.isPlaying && fixture.controller.player.currentTime().seconds > 0.5),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(fixture.controller.isPlaying)
        let original = try XCTUnwrap(fixture.controller.player.currentItem)
        func layers(in view: UIView) -> [AVPlayerLayer] {
            (view.layer as? AVPlayerLayer).map { [$0] } ?? view.subviews.flatMap { layers(in: $0) }
        }
        let originalLayer = try XCTUnwrap(layers(in: window).first(where: \.isReadyForDisplay))
        let position = fixture.controller.player.currentTime().seconds
        fixture.controller.setMuted(false)
        fixture.controller.handoffToDetail(itemID: fixture.item.id)
        fixture.showsDetail = true
        let handoffDeadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < handoffDeadline {
            XCTAssertTrue(fixture.controller.player.currentItem === original)
            XCTAssertEqual(fixture.controller.player.rate, 1)
            XCTAssertFalse(fixture.controller.isMuted)
            XCTAssertGreaterThanOrEqual(fixture.controller.player.currentTime().seconds, position)
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertGreaterThan(fixture.controller.player.currentTime().seconds, position + 1)
        XCTAssertTrue(fixture.controller.isClaimed(by: .detail, itemID: fixture.item.id))
        XCTAssertTrue(layers(in: window).contains { $0 === originalLayer && $0.isReadyForDisplay })
        host.rootView = TrailerHandoffRoot(fixture: fixture, isVisible: false)
        let departureDeadline = ContinuousClock.now + .seconds(2)
        while fixture.controller.player.currentItem != nil, ContinuousClock.now < departureDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNil(fixture.controller.player.currentItem, "Leaving detail still stops its ambient trailer.")
    }

    func testTrailerLabelRemainsIconOnlyEvenWhenParentRequestsText() {
        for external in [false, true] {
            let trailer = external
                ? MediaItem.youTubeTrailer(videoID: "dQw4w9WgXcQ", title: "Fixture")
                : MediaItem(id: "local", title: "Fixture", kind: .video)
            let view = TrailerActionButtonLabel(trailer: trailer)
                .labelStyle(.titleAndIcon)
            let size = UIHostingController(rootView: view).sizeThatFits(
                in: CGSize(width: 1_024, height: 100)
            )
            XCTAssertLessThan(size.width, 40, "A wide parent must not reveal the accessibility title.")
            XCTAssertLessThan(size.height, 40)
        }
    }

    func testActualDetailHeroNeverShowsTrailerTextOnPhoneOrTablet() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: AnyView(EmptyView()))
        host.safeAreaRegions = []
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        let app = PlozziOSAppModel()
        let item = MediaItem(
            id: "feature", title: "Feature fixture", kind: .movie,
            allowsTitleBasedMetadataMatching: false
        )
        for width in [CGFloat(390), 1_024] {
            window.frame = CGRect(x: 0, y: 0, width: width, height: 500)
            for external in [false, true] {
                let trailer = external
                    ? MediaItem.youTubeTrailer(videoID: "dQw4w9WgXcQ", title: "Fixture")
                    : MediaItem(id: "local", title: "Fixture", kind: .video)
                let presentation = HeroPresentation(item: item, artworkStyle: .landscape, surface: .detail)
                host.rootView = AnyView(
                    PlozziOSDetailHeroForeground(
                        item: item, rootItem: item, playableItem: item,
                        sources: [], selectedSourceAccountID: nil,
                        versions: [], selectedVersionID: nil,
                        onSelectSource: { _ in }, onSelectVersion: { _ in },
                        presentation: presentation, fallbackPresentation: presentation,
                        style: .landscape, actionHandler: TrailerPresentationActions(),
                        onPlay: { _, _ in }, trailerItem: trailer, onPlayTrailer: { _ in }
                    )
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.black)
                    .environment(app)
                    .environment(\.themePalette, .dark)
                    .environment(\.colorScheme, .dark)
                    .environment(\.locale, Locale(identifier: "en_US"))
                )
                window.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(250))
                let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                }
                let attachment = XCTAttachment(image: image)
                attachment.name = "actual-detail-icon-only-\(Int(width))-\(external)"
                attachment.lifetime = .keepAlways
                add(attachment)
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.recognitionLanguages = ["en-US"]
                try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
                let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
                XCTAssertTrue(text.contains("Play"), text)
                XCTAssertFalse(text.localizedCaseInsensitiveContains("YouTube"), text)
                XCTAssertFalse(text.localizedCaseInsensitiveContains("Trailer"), text)
            }
        }
    }

    func testMobileYouTubeHandoffUsesBrowserWhenAppIsUnavailable() async {
        var requests: [URL] = []
        let opener = YouTubeTrailerOpening { url in
            requests.append(url)
            return url.scheme == "https"
        }
        let trailer = MediaItem.youTubeTrailer(videoID: "dQw4w9WgXcQ", title: "Trailer")
        await opener.open(trailer)
        XCTAssertEqual(requests, [trailer.youTubeTrailerAppURL!, trailer.youTubeTrailerWatchURL!])
        XCTAssertFalse(opener.failed)
    }

    func testMobileFailedYouTubeHandoffShowsFailure() async {
        let opener = YouTubeTrailerOpening { _ in false }
        await opener.open(MediaItem.youTubeTrailer(videoID: "dQw4w9WgXcQ", title: "Trailer"))
        XCTAssertTrue(opener.failed)
    }

    func testApprovedIconUsesTransparentCutoutWithoutChangingLayout() throws {
        for dynamicType in [DynamicTypeSize.large, .accessibility3] {
            func render(_ external: Bool) throws -> UIImage {
                let renderer = ImageRenderer(content:
                    TrailerActionIcon(isExternal: external)
                        .foregroundStyle(.white)
                        .padding(12)
                        .environment(\.dynamicTypeSize, dynamicType)
                )
                renderer.scale = 3
                return try XCTUnwrap(renderer.uiImage)
            }
            let local = try render(false)
            let external = try render(true)
            XCTAssertEqual(local.size, external.size, "The arrow must not widen or move the button.")
            let localAlpha = try alpha(local)
            let externalAlpha = try alpha(external)
            XCTAssertEqual(localAlpha.count, externalAlpha.count)
            let removed = zip(localAlpha, externalAlpha).filter { $0 > 240 && $1 < 10 }.count
            XCTAssertGreaterThan(removed, 10, "The clearance must actually remove film pixels, not paint a background.")
            let added = zip(localAlpha, externalAlpha).filter { $0 < 10 && $1 > 240 }.count
            XCTAssertGreaterThan(added, 10, "The external arrow must remain visible.")
        }
    }

    func testTrailerActionsRenderWithActualMobileButtonStyle() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 700, height: 440)
        let host = UIHostingController(rootView: AnyView(EmptyView()))
        host.safeAreaRegions = []
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        for palette in [ThemePalette.dark, .light] {
            for reduced in [false, true] {
                host.rootView = AnyView(
                    VStack(alignment: .leading, spacing: 32) {
                        Text("Trailer actions").font(.title2.bold())
                        row(external: false)
                        row(external: true)
                    }
                    .padding(32)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .foregroundStyle(palette.primaryText)
                    .background(palette.backgroundBase)
                    .environment(\.themePalette, palette)
                    .environment(\.colorScheme, palette.isLight ? .light : .dark)
                    .environment(\.plozzReducePanelGlass, reduced)
                    .environment(\.plozzReduceTransparency, reduced)
                )
                window.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(200))
                let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                }
                let attachment = XCTAttachment(image: image)
                attachment.name = "trailer-actions-\(palette.isLight ? "light" : "dark")-\(reduced ? "reduced" : "glass")"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }

    private func row(external: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(external ? "YouTube trailer" : "Server trailer").font(.subheadline)
            HStack(spacing: 12) {
                Button {} label: { Label("Play", systemImage: "play.fill") }
                    .buttonStyle(PlozziOSHeroActionButtonStyle(kind: .primary))
                Button {} label: {
                    TrailerActionButtonLabel(trailer: external
                        ? .youTubeTrailer(videoID: "dQw4w9WgXcQ", title: "Fixture")
                        : MediaItem(id: "local", title: "Fixture", kind: .video))
                }
                    .buttonStyle(PlozziOSHeroActionButtonStyle(kind: .secondary, circular: true))
                Button {} label: { Image(systemName: "bookmark") }
                    .buttonStyle(PlozziOSHeroActionButtonStyle(kind: .secondary, circular: true))
                Button {} label: { Image(systemName: "checkmark") }
                    .buttonStyle(PlozziOSHeroActionButtonStyle(kind: .secondary, circular: true))
                Button {} label: { Image(systemName: "ellipsis") }
                    .buttonStyle(PlozziOSHeroActionButtonStyle(kind: .secondary, circular: true))
            }
        }
    }

    private func alpha(_ image: UIImage) throws -> [UInt8] {
        let image = try XCTUnwrap(image.cgImage)
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try pixels.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(
                data: bytes.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return stride(from: 3, to: pixels.count, by: 4).map { pixels[$0] }
    }
}

@MainActor @Observable
private final class TrailerHandoffFixture {
    let controller = HeroTrailerController()
    let sidebar = PlozziOSSidebarGeometryModel()
    let settings = HeroBackgroundSettingsModel(store: InMemoryHeroBackgroundSettingsStore(
        HeroBackgroundSettings(homeTrailerEnabled: true, detailMode: .trailer)
    ))
    let item = MediaItem(id: "handoff", title: "Handoff", kind: .movie, allowsTitleBasedMetadataMatching: false)
    let url: URL
    var showsDetail = false

    init(url: URL) { self.url = url }
}

private struct TrailerHandoffRoot: View {
    @Bindable var fixture: TrailerHandoffFixture
    var isVisible = true

    var body: some View {
        if isVisible {
            NavigationStack {
                PlozziOSHeroStage(
                    item: fixture.item,
                    presentation: HeroPresentation(item: fixture.item, artworkStyle: .landscape, surface: .home),
                    style: .landscape, surfaceRole: .home, isActive: !fixture.showsDetail,
                    trailerController: fixture.controller, backgroundSettings: fixture.settings,
                    trailerResolver: { [url = fixture.url] item in
                        HeroTrailerSource(ownerItemID: item.id, trailerItemID: "clip", url: url, duration: 120)
                    }
                ) { EmptyView() }
                .navigationDestination(isPresented: $fixture.showsDetail) {
                    PlozziOSHeroStage(
                        item: fixture.item,
                        presentation: HeroPresentation(item: fixture.item, artworkStyle: .landscape, surface: .detail),
                        style: .landscape, surfaceRole: .detail, isActive: true,
                        trailerController: fixture.controller, backgroundSettings: fixture.settings,
                        trailerResolver: { _ in
                            XCTFail("The handoff must reuse the prepared trailer, not resolve it again.")
                            return nil
                        }
                    ) { EmptyView() }
                }
            }
            .environment(fixture.sidebar)
        }
    }
}

@MainActor
private final class TrailerPresentationActions: MediaItemActionHandling {
    func actions(for item: MediaItem, context: MediaItemActionContext) -> [MediaItemAction] { [] }
    func perform(_ action: MediaItemAction, on item: MediaItem, context: MediaItemActionContext) {}
}
#endif
