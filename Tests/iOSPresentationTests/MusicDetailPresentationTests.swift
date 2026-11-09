#if os(iOS)
import CoreModels
import CoreUI
@testable import FeatureMusic
import SwiftUI
import UIKit
import XCTest

@MainActor
final class MusicDetailPresentationTests: XCTestCase {
    func testNativeNavigationHasNoDarkSeamAboveTheHero() async throws {
        let url = URL(string: "https://music-detail.invalid/\(UUID().uuidString).png")!
        let artwork = UIGraphicsImageRenderer(size: CGSize(width: 48, height: 48)).image { context in
            UIColor(red: 0.1, green: 0.6, blue: 0.7, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 48, height: 48))
        }
        let response = try XCTUnwrap(HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "image/png", "Cache-Control": "max-age=3600"]
        ))
        let cache = try XCTUnwrap(ArtworkSession.shared.configuration.urlCache)
        cache.storeCachedResponse(
            CachedURLResponse(response: response, data: try XCTUnwrap(artwork.pngData())),
            for: URLRequest(url: url)
        )
        defer { cache.removeCachedResponse(for: URLRequest(url: url)) }
        let loaded = await ArtworkImageCache.shared.image(for: url, variant: .heroBackdrop)
        XCTAssertNotNil(loaded)

        for size in [CGSize(width: 390, height: 844), CGSize(width: 834, height: 1_194)] {
            for artist in [false, true] {
                let page = NavigationStack(path: .constant([0])) {
                    Text("Music")
                        .navigationDestination(for: Int.self) { _ in
                            if artist {
                                MobileMusicArtistDetail(
                                    artist: MusicArtist(id: "artist", name: "Artist", artworkURL: url),
                                    albums: [], onSelectAlbum: { _ in }
                                )
                            } else {
                                MobileMusicAlbumDetail(
                                    album: MusicAlbum(id: "album", title: "Album", artworkURL: url),
                                    tracks: [], nowPlayingTrack: nil, isPlaying: false,
                                    onPlay: {}, onShuffle: {}, onPlayTrack: { _ in }
                                )
                            }
                        }
                }
                .environment(\.themePalette, .light)
                .tint(.blue)
                try await mount(page, size: size, name: "Navigation seam \(Int(size.width)) artist \(artist)") { host, window in
                    let bar = try XCTUnwrap(self.navigationBar(in: host.view))
                    let barFrame = bar.convert(bar.bounds, to: window)
                    let boundary = barFrame.maxY
                    func capture() -> UIImage {
                        UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                        }
                    }
                    var image = capture()
                    var below = try self.pixel(in: image, at: CGPoint(x: size.width - 12, y: boundary + 3))
                    let deadline = Date().addingTimeInterval(2)
                    while below[2] <= below[0] + 0.05 && Date() < deadline {
                        try await Task.sleep(for: .milliseconds(20))
                        image = capture()
                        below = try self.pixel(in: image, at: CGPoint(x: size.width - 12, y: boundary + 3))
                    }
                    let above = try self.pixel(in: image, at: CGPoint(x: size.width - 12, y: boundary - 3))
                    XCTAssertGreaterThan(below[2], below[0] + 0.05, "Measure the resolved cyan hero, not an empty navigation transition")
                    for channel in 0..<3 {
                        XCTAssertEqual(above[channel], below[channel], accuracy: 0.06,
                                       "The native navigation edge must continue the hero, not expose the deep page base")
                    }
                    if !artist && size.width < 700 {
                        let middle = try self.pixel(in: image, at: CGPoint(x: size.width - 12, y: barFrame.midY))
                        for channel in 0..<3 {
                            XCTAssertEqual(middle[channel], below[channel], accuracy: 0.04,
                                           "Compact album headers must not acquire a second navigation scrim")
                        }
                    }
                }
            }
        }
    }

    func testArtworkPaletteKeepsWhiteTextLegible() throws {
        for color in [UIColor.red, .green, .blue, .yellow, .white, .black, .gray] {
            let image = UIGraphicsImageRenderer(size: CGSize(width: 48, height: 48)).image { context in
                color.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 48, height: 48))
            }
            let palette = MusicDetailColors(image: image)
            for background in [palette.hero, palette.deep] {
                var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                XCTAssertTrue(UIColor(background).getRed(&r, green: &g, blue: &b, alpha: &a))
                func linear(_ value: CGFloat) -> Double {
                    let value = Double(value)
                    return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
                }
                let luminance = 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
                XCTAssertGreaterThanOrEqual(1.05 / (luminance + 0.05), 4.5)
                let secondaryLuminance = 0.2126 * linear(0.8 + r * 0.2)
                    + 0.7152 * linear(0.8 + g * 0.2) + 0.0722 * linear(0.8 + b * 0.2)
                XCTAssertGreaterThanOrEqual((secondaryLuminance + 0.05) / (luminance + 0.05), 4.5)
            }
        }
    }

    func testAlbumLayoutsRemainVerticallyScrollableAtLargeTextSizes() async throws {
        let tracks = (1...24).map {
            MusicTrack(id: "\($0)", title: "A long song title that should remain readable \($0)",
                       trackNumber: $0, duration: 230, sourceAccountID: "account")
        }
        let album = MusicAlbum(id: "album", title: "A Long Album Title for an Evening by the Sea",
                               artistName: "An Artist With a Longer Name", year: 2026,
                               trackCount: tracks.count, totalDuration: 5_520, sourceAccountID: "account")
        for size in [CGSize(width: 390, height: 844), CGSize(width: 834, height: 1_194)] {
            for typeSize in [DynamicTypeSize.large, .accessibility3] {
                let view = MobileMusicAlbumDetail(
                    album: album, tracks: tracks, nowPlayingTrack: tracks[0], isPlaying: false,
                    onPlay: {}, onShuffle: {}, onPlayTrack: { _ in }
                )
                .environment(\.themePalette, .light)
                .environment(\.dynamicTypeSize, typeSize)
                try await mount(view, size: size, name: "Album \(Int(size.width)) \(typeSize)") { host, window in
                    let scroll = try XCTUnwrap(self.scrollViews(in: host.view).first)
                    XCTAssertGreaterThan(scroll.contentSize.height, scroll.bounds.height)
                    XCTAssertLessThanOrEqual(scroll.contentSize.width, scroll.bounds.width + 1,
                                             "Text must wrap rather than cause horizontal overflow")
                    scroll.setContentOffset(
                        CGPoint(x: 0, y: max(0, scroll.contentSize.height - scroll.bounds.height)), animated: false
                    )
                    host.view.layoutIfNeeded()
                    self.attach(window, name: "Album final rows \(Int(size.width)) \(typeSize)")
                }
            }
        }
    }

    func testArtistLayoutsAndPureBlackMissingArtwork() async throws {
        let artist = MusicArtist(id: "artist", name: "Artist Without Artwork",
                                 genres: ["Alternative"], sourceAccountID: "account")
        let albums = (1...8).map {
            MusicAlbum(id: "\($0)", title: "Album \($0)", year: 2026, sourceAccountID: "account")
        }
        for size in [CGSize(width: 390, height: 844), CGSize(width: 834, height: 1_194)] {
            for palette in [ThemePalette.dark, .pureBlack] {
                let view = MobileMusicArtistDetail(artist: artist, albums: albums, onSelectAlbum: { _ in })
                    .environment(\.themePalette, palette)
                try await mount(view, size: size, name: "Artist \(Int(size.width)) black \(palette == .pureBlack)") { host, _ in
                    let scroll = try XCTUnwrap(self.scrollViews(in: host.view).first)
                    XCTAssertLessThanOrEqual(scroll.contentSize.width, scroll.bounds.width + 1)
                    XCTAssertGreaterThan(scroll.contentSize.height, 400, "The hero must not collapse on a short page")
                }
            }
        }
    }

    private func mount<Content: View>(
        _ content: Content, size: CGSize, name: String,
        inspect: (UIHostingController<Content>, UIWindow) async throws -> Void
    ) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        let host = UIHostingController(rootView: content)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        try await Task.sleep(for: .milliseconds(200))
        host.view.layoutIfNeeded()
        XCTAssertEqual(host.view.bounds.width, size.width, accuracy: 1)
        attach(window, name: name)
        try await inspect(host, window)
    }

    private func scrollViews(in view: UIView) -> [UIScrollView] {
        (view as? UIScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews(in: $0) }
    }

    private func navigationBar(in view: UIView) -> UINavigationBar? {
        if let bar = view as? UINavigationBar { return bar }
        return view.subviews.lazy.compactMap { self.navigationBar(in: $0) }.first
    }

    private func pixel(in image: UIImage, at point: CGPoint) throws -> [Double] {
        let source = try XCTUnwrap(image.cgImage)
        let crop = try XCTUnwrap(source.cropping(to: CGRect(
            x: point.x * image.scale, y: point.y * image.scale, width: 1, height: 1
        )))
        var pixel = [UInt8](repeating: 0, count: 4)
        try pixel.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(
                data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return pixel.prefix(3).map { Double($0) / 255 }
    }

    private func attach(_ window: UIWindow, name: String) {
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
#endif
