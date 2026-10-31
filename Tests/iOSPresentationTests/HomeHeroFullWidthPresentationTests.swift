#if os(iOS)
import CoreModels
import CoreUI
import FeatureAuth
import FeatureHomeCore
import SwiftUI
import UIKit
import XCTest
@testable import AppShelliOS

@MainActor
final class HomeHeroFullWidthPresentationTests: XCTestCase {
    func testHeroCompositeSpansHorizontalSafeAreasWithoutMovingForeground() async throws {
        let item = try await artworkItem()
        for (size, sizeClass) in [
            (CGSize(width: 390, height: 844), UserInterfaceSizeClass.compact),
            (CGSize(width: 1024, height: 768), .regular)
        ] {
            for insets in [
                UIEdgeInsets.zero,
                UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 78),
                UIEdgeInsets(top: 0, left: 64, bottom: 0, right: 34)
            ] {
                let pull = PlozziOSHomeHeroPullModel()
                try await withWindow(item: item, size: size, sizeClass: sizeClass, insets: insets, pull: pull) {
                    window, host in
                    for distance in [CGFloat(0), 60] {
                        pull.update(distance)
                        try await waitForHostedLayout(window)
                        let image = snapshot(window, name: "hero-width-\(Int(size.width))-\(Int(insets.left))-\(Int(insets.right))-pull-\(Int(distance))")
                        try assertArtworkAtBothEdges(image)
                        let frames = try HeroTextInk.frames(in: image, terms: ["HERO", "Play"], darkTerms: ["Play"])
                        let safe = window.bounds.inset(by: host.view.safeAreaInsets)
                        for term in ["HERO", "Play"] {
                            let frame = try XCTUnwrap(frames[term], "Missing \(term)")
                            XCTAssertGreaterThanOrEqual(frame.minX, safe.minX)
                            XCTAssertLessThanOrEqual(frame.maxX, safe.maxX)
                        }
                    }
                }
            }
        }
    }

    func testNativeTabChromeKeepsArtworkBehindTheSideRail() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let item = try await artworkItem()
        let size = scene.coordinateSpace.bounds.size
        try await withWindow(
            item: item, size: size, sizeClass: nil, insets: .zero,
            pull: PlozziOSHomeHeroPullModel(), nativeTabs: true
        ) { window, _ in
            try await waitForHostedLayout(window)
            let image = snapshot(window, name: "native-hero-width-\(Int(size.width))x\(Int(size.height))")
            try assertArtworkAtBothEdges(image)
        }
    }

    private func artworkItem() async throws -> MediaItem {
        let url = try XCTUnwrap(URL(string: "https://hero-width.invalid/\(UUID().uuidString).png"))
        let image = UIGraphicsImageRenderer(size: CGSize(width: 900, height: 1200)).image { context in
            UIColor(red: 0.15, green: 0.75, blue: 0.95, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 900, height: 1200))
            UIColor(red: 0.25, green: 0.85, blue: 0.95, alpha: 1).setFill()
            for x in stride(from: 0, to: 900, by: 100) {
                context.fill(CGRect(x: x, y: 0, width: 20, height: 1200))
            }
        }
        let cache = try XCTUnwrap(ArtworkSession.shared.configuration.urlCache)
        let response = try XCTUnwrap(HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "image/png", "Cache-Control": "max-age=86400"]
        ))
        cache.storeCachedResponse(
            CachedURLResponse(response: response, data: try XCTUnwrap(image.pngData())),
            for: URLRequest(url: url)
        )
        let decoded = await ArtworkImageCache.shared.image(for: url, variant: .heroBackdrop)
        XCTAssertNotNil(decoded)
        return MediaItem(
            id: UUID().uuidString, title: "HERO", kind: .movie,
            overview: "Artwork behind the native controls.",
            posterURL: url, backdropURL: url, allowsTitleBasedMetadataMatching: false
        )
    }

    private func withWindow(
        item: MediaItem, size: CGSize, sizeClass: UserInterfaceSizeClass?,
        insets: UIEdgeInsets, pull: PlozziOSHomeHeroPullModel, nativeTabs: Bool = false,
        exercise: (UIWindow, UIHostingController<AnyView>) async throws -> Void
    ) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "HeroWidth-\(UUID().uuidString)"))
        let app = PlozziOSAppModel(
            accountStore: AccountStore(secureStore: InMemorySecureStore()),
            profileStore: ProfileStore(defaults: defaults)
        )
        app.settings.heroBackground.settings.homeTrailerEnabled = false
        let sidebar = PlozziOSSidebarGeometryModel()
        let root = HomeHeroWidthFixture(item: item, pull: pull, nativeTabs: nativeTabs, sidebar: sidebar)
            .environment(app)
            .environment(sidebar)
            .environment(HeroTrailerController())
            .environment(\.themePalette, .dark)
            .environment(\.colorScheme, .dark)
            .environment(\.plozzMetrics, .touch(density: .standard))
            .environment(\.plozziOSHeroContainerHeight, size.height)
            .environment(\.locale, Locale(identifier: "en_US"))
            .environment(\.dynamicTypeSize, .large)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        let host = UIHostingController(rootView: AnyView(root))
        if let sizeClass {
            host.safeAreaRegions = []
            host.rootView = AnyView(root.environment(\.horizontalSizeClass, sizeClass))
        }
        host.additionalSafeAreaInsets = insets
        host.overrideUserInterfaceStyle = .dark
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        try await waitForHostedLayout(window)
        try await exercise(window, host)
    }

    private func snapshot(_ window: UIWindow, name: String) -> UIImage {
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        return image
    }

    private func assertArtworkAtBothEdges(
        _ image: UIImage, file: StaticString = #filePath, line: UInt = #line
    ) throws {
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
        // Below the status controls, above hero text, and outside the rail's buttons.
        for x in [CGFloat(3), image.size.width - 3] {
            let y = image.size.height * 0.32
            let offset = (Int(y * image.scale) * cgImage.width + Int(x * image.scale)) * 4
            XCTAssertGreaterThan(Int(bytes[offset + 2]), 120, "Missing artwork at x=\(x)", file: file, line: line)
            XCTAssertGreaterThan(
                Int(bytes[offset + 2]) - Int(bytes[offset]), 60,
                "The edge must contain the blue artwork, not the page background.", file: file, line: line
            )
        }
    }
}

private struct HomeHeroWidthFixture: View {
    let item: MediaItem
    let pull: PlozziOSHomeHeroPullModel
    let nativeTabs: Bool
    let sidebar: PlozziOSSidebarGeometryModel

    var body: some View {
        if nativeTabs {
            TabView {
                Tab("Home", systemImage: "house") { home }
                Tab("Search", systemImage: "magnifyingglass", role: .search) { Text("Search") }
            }
            .tabViewStyle(.sidebarAdaptable)
            .background {
                PlozziOSHomeSidebarOverlapProbe(enabled: true, geometryModel: sidebar)
                    .frame(width: 0, height: 0)
            }
        } else {
            home
        }
    }

    private var home: some View {
        NavigationStack {
            PlozziOSHomeScrollView(heroActive: true) {
                PlozziOSHomeHeroCarousel(
                    items: [item], autoAdvance: false, autoAdvanceSeconds: 30,
                    onPlay: { _ in }, pullModel: pull
                )
            } rows: {
                Text("Following row")
                Color.clear.frame(height: 1200)
            }
            .background(Color.black.ignoresSafeArea())
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Settings", systemImage: "gearshape") {}
                }
            }
        }
    }
}
#endif
