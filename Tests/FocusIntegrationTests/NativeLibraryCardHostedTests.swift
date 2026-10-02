#if os(tvOS)
import CoreModels
@testable import CoreUI
@testable import FeatureHome
import Network
import SwiftUI
import TVUIKit
import UIKit
import XCTest

@MainActor
final class NativeLibraryCardHostedTests: XCTestCase {
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
        let poster = try XCTUnwrap(descendant(TVPosterView.self, in: window))
        let system = try XCTUnwrap(UIFocusSystem.focusSystem(for: window))
        controller.target = poster
        system.requestFocusUpdate(to: controller)
        system.updateFocusIfNeeded()
        let deadline = ContinuousClock.now + .seconds(8)
        while poster.image?.cgImage?.width != 720, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(poster.image?.cgImage?.width, 720)
        XCTAssertEqual(poster.image?.cgImage?.height, 405)
        XCTAssertTrue(poster.isFocused, "An asynchronously generated bitmap must not replace the native focus target.")
        poster.sendActions(for: .primaryActionTriggered)
        XCTAssertEqual(activations, 1)
        let artwork = try XCTUnwrap(NativeFocusProjection.artworkFrame(of: poster.imageView, in: window))
        let image = snapshot(window)
        XCTAssertFalse(try isRed(image, at: CGPoint(
            x: artwork.maxX - artwork.width * 0.08,
            y: artwork.minY + artwork.height * 0.12
        )), "The branded corner badge must be drawn over the bitmap, inside native artwork.")
        let attachment = XCTAttachment(image: image)
        attachment.name = "generated-native-library-collage"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testLibraryTransportMarksRemainDistinct() throws {
        var rendered: [Data] = []
        for transport in [MediaShareTransportKind.smb, .webDAV, .nfs] {
            let library = AggregatedLibrary(
                accountID: "share", accountName: "Viewer", serverName: "Server",
                providerKind: .mediaShare, transportKind: transport,
                library: MediaLibrary(id: "movies", title: "Movies", kind: .movie)
            )
            let renderer = ImageRenderer(content:
                LibraryArtworkOverlay(library: library).frame(width: 720, height: 405)
            )
            rendered.append(try XCTUnwrap(renderer.uiImage?.pngData()))
        }
        XCTAssertEqual(Set(rendered).count, 3, "Shared drive marks must retain the actual transport labels.")
    }

    func testLibraryBadgePositionDoesNotDependOnServerCover() throws {
        var badges: [Data] = []
        let covers: [URL?] = [nil, URL(string: "https://example.invalid/custom.jpg")]
        for cover in covers {
            let library = AggregatedLibrary(
                accountID: "account", accountName: "Viewer", serverName: "Server",
                providerKind: .jellyfin,
                library: MediaLibrary(id: "movies", title: "Movies", kind: .movie, imageURL: cover)
            )
            let renderer = ImageRenderer(content:
                LibraryArtworkOverlay(library: library)
                    .frame(width: 720, height: 405)
                    .background(.red)
            )
            renderer.scale = 1
            let image = try XCTUnwrap(renderer.uiImage)
            let corner = try XCTUnwrap(image.cgImage?.cropping(to:
                CGRect(x: 580, y: 20, width: 140, height: 140)
            ))
            badges.append(try XCTUnwrap(UIImage(cgImage: corner).pngData()))
            XCTAssertFalse(try isRed(image, at: CGPoint(x: 640, y: 75)),
                           "Both cover types must put the badge in the top-right corner.")
            XCTAssertTrue(try isRed(image, at: CGPoint(x: 65, y: 75)),
                          "The badge must not fall back to the GeometryReader's top-left origin.")
        }
        XCTAssertEqual(badges[0], badges[1])
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
            let poster = try XCTUnwrap(descendant(TVPosterView.self, in: host.view))
            let focus = try XCTUnwrap(UIFocusSystem.focusSystem(for: window))
            controller.target = poster
            focus.requestFocusUpdate(to: controller)
            focus.updateFocusIfNeeded()
            try await Task.sleep(for: .milliseconds(700))
            XCTAssertTrue(poster.isFocused)
            var artwork = try XCTUnwrap(NativeFocusProjection.artworkFrame(of: poster.imageView, in: window))
            let loaded = ContinuousClock.now + .seconds(5)
            while try !isRed(snapshot(window), at: CGPoint(x: artwork.midX, y: artwork.midY)),
                  ContinuousClock.now < loaded {
                try await Task.sleep(for: .milliseconds(100))
                artwork = try XCTUnwrap(NativeFocusProjection.artworkFrame(of: poster.imageView, in: window))
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
            artwork = try XCTUnwrap(NativeFocusProjection.artworkFrame(of: poster.imageView, in: window))
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
        let images = try [
            "portrait": CGSize(width: 200, height: 300),
            "wide": CGSize(width: 640, height: 180),
            "landscape": CGSize(width: 320, height: 180)
        ].mapValues { size in
            try XCTUnwrap(UIGraphicsImageRenderer(size: size).image {
                UIColor.red.setFill()
                $0.fill(CGRect(origin: .zero, size: size))
            }.pngData())
        }
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
            for aspect in ["portrait", "wide", "landscape"] {
                let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/\(aspect)/\(UUID().uuidString)"))
                let synthesized = style == .system && aspect == "landscape"
                let aggregated = AggregatedLibrary(
                    accountID: "fixture", accountName: "Viewer", serverName: "Fixture server",
                    providerKind: .jellyfin,
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
                let poster = descendant(TVPosterView.self, in: host.view)
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
                        let width = metrics.landscapeCardSlotWidth - metrics.borderlessCardSideMargin * 2
                        XCTAssertEqual(poster.contentSize.width, width, accuracy: 1)
                        XCTAssertEqual(poster.contentSize.height, width * 9 / 16, accuracy: 1)
                        XCTAssertNil(poster.title, "The native image must not own a visible caption footer.")
                        XCTAssertEqual(poster.accessibilityLabel, "Movies")
                        XCTAssertEqual(poster.accessibilityValue, "Fixture server")
                        let caption = try XCTUnwrap(caption)
                        XCTAssertFalse(caption.isDescendant(of: poster))
                        XCTAssertFalse(caption.canBecomeFocused)
                        let frame = try XCTUnwrap(NativeFocusProjection.artworkFrame(of: caption, in: window))
                        XCTAssertEqual(frame, try XCTUnwrap(captionFrame), "Native focus must not project the caption slot.")
                        let title = try XCTUnwrap(descendant(UILabel.self, in: caption.title))
                        XCTAssertEqual(title.font.pointSize, metrics.cardTitleFontSize)
                        let artwork = try XCTUnwrap(NativeFocusProjection.artworkFrame(of: poster.imageView, in: window))
                        let textFrame = try XCTUnwrap(NativeFocusProjection.artworkFrame(of: title, in: window))
                        XCTAssertGreaterThanOrEqual(textFrame.minY, artwork.maxY,
                                                    "The caption must remain below the artwork's focused footprint.")
                        XCTAssertEqual(slot.bounds.width, metrics.landscapeCardSlotWidth, accuracy: 1)
                        XCTAssertTrue(try isRed(image, at: CGPoint(x: artwork.midX, y: artwork.midY)))
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
        let poster = try XCTUnwrap(descendant(TVPosterView.self, in: window))
        XCTAssertEqual(poster.contentSize, CGSize(width: 320, height: 320),
                       "Existing music callers keep square artwork unless an aspect is supplied.")
        XCTAssertNotNil(poster.image, "A real placeholder must initialize native focus before artwork arrives.")
        XCTAssertEqual(poster.accessibilityLabel, "Movies")
        let caption = try XCTUnwrap(descendant(SystemPosterCaption.CaptionView.self, in: window))
        XCTAssertFalse(caption.isDescendant(of: poster))
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
        return pixel[0] > 180 && pixel[1] < 100 && pixel[2] < 100
    }
}

private struct LibraryCardFrameProbe: UIViewRepresentable {
    func makeUIView(context: Context) -> LibraryCardSlotView { LibraryCardSlotView() }
    func updateUIView(_ uiView: LibraryCardSlotView, context: Context) {}
}

private final class LibraryCardSlotView: UIView {}

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

private final class LibraryArtworkServer: @unchecked Sendable {
    private let listener: NWListener
    private let images: [String: Data]
    private let queue = DispatchQueue(label: "NativeLibraryCardHostedTests.artwork")
    private var connections: [NWConnection] = []

    init(images: [String: Data]) throws {
        self.images = images
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
            let key = path.split(separator: "/").first.map(String.init) ?? ""
            let image = images[key] ?? Data()
            let status = images[key] == nil ? "404 Not Found" : "200 OK"
            let response = Data("HTTP/1.1 \(status)\r\nContent-Type: image/png\r\nContent-Length: \(image.count)\r\nConnection: close\r\n\r\n".utf8) + image
            connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}
#endif
