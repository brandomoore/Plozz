#if os(iOS)
import CoreModels
import CoreUI
@testable import FeatureMusic
import SwiftUI
import UIKit
import XCTest

@MainActor
final class MusicDetailPresentationTests: XCTestCase {
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
        inspect: (UIHostingController<Content>, UIWindow) throws -> Void
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
        try inspect(host, window)
    }

    private func scrollViews(in view: UIView) -> [UIScrollView] {
        (view as? UIScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews(in: $0) }
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
