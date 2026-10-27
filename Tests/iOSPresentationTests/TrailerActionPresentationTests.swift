#if os(iOS)
import CoreModels
import CoreUI
import FeatureHomeCore
import SwiftUI
import UIKit
import Vision
import XCTest
@testable import AppShelliOS

@MainActor
final class TrailerActionPresentationTests: XCTestCase {
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

@MainActor
private final class TrailerPresentationActions: MediaItemActionHandling {
    func actions(for item: MediaItem, context: MediaItemActionContext) -> [MediaItemAction] { [] }
    func perform(_ action: MediaItemAction, on item: MediaItem, context: MediaItemActionContext) {}
}
#endif
