#if os(tvOS)
import CoreModels
@testable import CoreUI
@testable import FeatureHome
import MetadataKit
import Network
import SwiftUI
import TVUIKit
import UIKit
import XCTest

@MainActor
final class NativeLibraryCardHostedTests: XCTestCase {
    private var savedProviders = MetadataProviderSettings.default

    override func setUp() async throws {
        try await super.setUp()
        let store = MetadataProviderSettingsStore()
        savedProviders = store.load()
        store.save(.init(orderMode: .custom, disabledOrder: MetadataEnrichmentConfig.defaultBaseOrder.map(\.rawValue)))
    }

    override func tearDown() async throws {
        MetadataProviderSettingsStore().save(savedProviders)
        try await super.tearDown()
    }

    func testNativeBrowseChangesBetweenOnlineAndLibraryPixelsWithoutChangingTheItem() async throws {
        let settings = MetadataProviderSettingsStore()
        let previous = settings.load()
        settings.save(.default)
        defer { settings.save(previous) }
        func data(_ color: UIColor) throws -> Data {
            try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 100, height: 150)).image {
                color.setFill()
                $0.fill(CGRect(x: 0, y: 0, width: 100, height: 150))
            }.pngData())
        }
        let server = try LibraryArtworkServer(images: ["library": data(.red), "online": data(.green)])
        defer { server.stop() }
        let port = try await server.start()
        let token = UUID().uuidString
        let library = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/library/\(token)"))
        let online = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/online/\(token)"))
        let item = MediaItem(id: token, title: token, kind: .movie, posterURL: library)
        let query = MetadataQuery(item)
        for provider in MetadataEnrichmentConfig.defaultBaseOrder {
            await MetadataDiskCache.shared.store(
                online, for: "\(query.cacheKey(for: .poster))|provider:\(provider.rawValue)"
            )
        }
        _ = await ArtworkImageCache.shared.image(for: online, variant: .posterCard)
        _ = await ArtworkImageCache.shared.image(for: library, variant: .posterCard)
        let cell = NativeTVLibraryCell(frame: CGRect(x: 0, y: 0, width: 220, height: 400))
        defer { cell.prepareForReuse() }
        var environment = EnvironmentValues()
        environment.plozzCardCaptionView = .browse
        for preference in [ArtworkPreference.online, .library, .online] {
            environment.plozzArtworkSettings = .init(preference: preference)
            cell.configure(item: item, spoilerSettings: .default, environment: environment)
            let deadline = ContinuousClock.now + .seconds(3)
            var selected: UIImage?
            while ContinuousClock.now < deadline {
                cell.updateConfiguration(using: cell.configurationState)
                let content = cell.contentView as? TVMediaItemContentView
                selected = (content?.configuration as? TVMediaItemContentConfiguration)?.image
                if let selected, selected.cgImage?.width ?? 0 >= 100 { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            let image = try XCTUnwrap(selected)
            XCTAssertGreaterThanOrEqual(image.cgImage?.width ?? 0, 100)
            let pixel = try pixel(image, at: CGPoint(x: 10, y: 10))
            XCTAssertGreaterThan(pixel[preference == .library ? 0 : 1], 180)
            XCTAssertLessThan(pixel[preference == .library ? 1 : 0], 80)
            XCTAssertEqual(cell.item?.id, token)
        }
    }

    func testArtlessNativeLibraryCellsPaintNamesOnlyWhenCaptionsAreHidden() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let controller = UIViewController()
        controller.view.backgroundColor = .black
        let cell = NativeTVLibraryCell(frame: .zero)
        controller.view.addSubview(cell)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            cell.prepareForReuse()
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        var environment = EnvironmentValues()
        environment.themePalette = .dark
        environment.colorScheme = .dark
        environment.plozzCardStyle = .borderless
        environment.isEnabled = false
        for kind in [MediaItemKind.folder, .movie] {
            for hidden in [true, false] {
                environment.plozzCardCaptionsHidden = hidden
                cell.frame = CGRect(
                    x: 400, y: 200, width: 220,
                    height: NativeTVLibraryCell.height(for: 220, environment: environment)
                )
                var pictures: [[UInt8]] = []
                for title in ["Family", "Travel"] {
                    cell.configure(
                        item: MediaItem(id: title, title: title, kind: kind),
                        spoilerSettings: .default, environment: environment
                    )
                    window.layoutIfNeeded()
                    try await Task.sleep(for: .milliseconds(150))
                    let image = snapshot(window)
                    let rect = cell.contentView.convert(cell.contentView.bounds, to: window)
                    let crop = try XCTUnwrap(image.cgImage?.cropping(to: rect))
                    pictures.append(try rgba(crop))
                    XCTAssertEqual(cell.accessibilityLabel, title)
                    let attachment = XCTAttachment(image: UIImage(cgImage: crop))
                    attachment.name = "native-artless-\(kind)-\(hidden)-\(title)"
                    attachment.lifetime = .keepAlways
                    add(attachment)
                }
                XCTAssertEqual(pictures[0] != pictures[1], hidden,
                               "Only caption-free placeholders should paint each item's name inside the artwork.")
            }
            cell.prepareForReuse()
        }
    }

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
        let badgePixel = try pixel(image, at: CGPoint(
            x: artwork.maxX - artwork.width * 0.08,
            y: artwork.minY + artwork.height * 0.12
        ))
        XCTAssertLessThanOrEqual(abs(Int(badgePixel[2]) - Int(badgePixel[1])), 3,
                                "Provider tint must no longer be drawn over the artwork.")
        let center = try XCTUnwrap(image.cgImage?.cropping(to: CGRect(
            x: artwork.minX + artwork.width * 0.2, y: artwork.minY + artwork.height * 0.35,
            width: artwork.width * 0.6, height: artwork.height * 0.3
        )))
        let centerPixels = try rgba(center)
        XCTAssertFalse(stride(from: 0, to: centerPixels.count, by: 4).contains {
            centerPixels[$0 + 1] > 180 && centerPixels[$0 + 2] > 180
        }, "The red collage must not have a white library title painted over it.")
        let caption = try XCTUnwrap(descendant(SystemPosterCaption.CaptionView.self, in: window))
        XCTAssertEqual(try XCTUnwrap(descendant(UILabel.self, in: caption.title)).text, "Movies")
        let badge = try XCTUnwrap(caption.providerBadge)
        let badgeFrame = try XCTUnwrap(NativeFocusProjection.artworkFrame(of: badge, in: window))
        XCTAssertGreaterThanOrEqual(badgeFrame.minY, artwork.maxY)
        XCTAssertFalse(badge.isDescendant(of: poster))
        let attachment = XCTAttachment(image: image)
        attachment.name = "generated-native-library-collage"
        attachment.lifetime = .keepAlways
        add(attachment)

        let returningCard = ImageRenderer(content:
            LibraryCardArtwork(library: library, source: source)
                .frame(width: 720, height: 405)
        )
        let firstFrame = try XCTUnwrap(returningCard.uiImage)
        XCTAssertTrue(try isRed(firstFrame, at: CGPoint(x: 360, y: 100)),
                      "A returning card must show its resident collage before any async task runs.")

        let returningHost = UIHostingController(rootView:
            LibraryCardView(aggregated: library, subtitle: "Server", action: {}, artworkSource: source)
                .environment(\.plozzCardFocusStyle, .system)
                .frame(width: 500)
        )
        host.view.isHidden = true
        controller.addChild(returningHost)
        controller.view.addSubview(returningHost.view)
        returningHost.didMove(toParent: controller)
        returningHost.view.frame = host.view.frame
        window.layoutIfNeeded()
        _ = snapshot(window)
        let returningPoster = try XCTUnwrap(descendant(TVPosterView.self, in: returningHost.view))
        XCTAssertEqual(returningPoster.image?.cgImage?.width, 720,
                       "The native focus surface must receive the cached bitmap on its first paint.")
    }

    func testLibraryTransportMarksRemainDistinct() throws {
        var rendered: [Data] = []
        for transport in [MediaShareTransportKind.smb, .webDAV, .nfs] {
            let renderer = ImageRenderer(content:
                ProviderBrandMark(provider: .mediaShare, size: 32, mediaShareTransport: transport)
            )
            rendered.append(try XCTUnwrap(renderer.uiImage?.pngData()))
        }
        XCTAssertEqual(Set(rendered).count, 3, "Shared drive marks must retain the actual transport labels.")
    }

    func testNativeLibraryCaptionBadgeLayoutAndReuse() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let metrics = PlozzMetrics(density: .standard)
        func fixture(
            _ name: String, focused: Bool = false, direction: LayoutDirection = .leftToRight,
            provider: ProviderKind = .jellyfin, transport: MediaShareTransportKind? = nil
        ) -> some View {
            SystemPosterCaption(
                title: .content(name), subtitle: "Server", reservesSubtitleSpace: true,
                isFocused: focused, providerKind: provider, mediaShareTransport: transport
            )
            .frame(width: 484)
            .environment(\.plozzMetrics, metrics)
            .environment(\.layoutDirection, direction)
            .environment(\.colorScheme, .dark)
            .environment(\.themePalette, .dark)
            .background(.black)
        }
        let host = UIHostingController(rootView: fixture("Movies"))
        host.view.backgroundColor = .black
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        let longName = String(repeating: "A long library name ", count: 8)
        for direction in [LayoutDirection.leftToRight, .rightToLeft] {
            for name in ["Movies", longName] {
                host.rootView = fixture(name, direction: direction)
                try await Task.sleep(for: .milliseconds(100))
                let caption = try XCTUnwrap(descendant(SystemPosterCaption.CaptionView.self, in: window))
                let badge = try XCTUnwrap(caption.providerBadge)
                let restingFrame = badge.frame
                let height = caption.bounds.height
                XCTAssertEqual(badge.bounds.size, CGSize(
                    width: metrics.cardTitleFontSize, height: metrics.cardTitleFontSize
                ))
                XCTAssertFalse(badge.canBecomeFocused)
                XCTAssertFalse(badge.isUserInteractionEnabled)
                XCTAssertTrue(badge.accessibilityElementsHidden)
                XCTAssertFalse(badge.isDescendant(of: caption.title), "The badge must not move inside the marquee.")
                let title = try XCTUnwrap(descendant(UILabel.self, in: caption.title))
                if direction == .leftToRight {
                    XCTAssertEqual(caption.title.frame.minX - badge.frame.maxX, PlozzTheme.Spacing.small, accuracy: 1)
                } else {
                    XCTAssertEqual(badge.frame.minX - caption.title.frame.maxX, PlozzTheme.Spacing.small, accuracy: 1)
                }
                let start = min(badge.frame.minX, caption.title.frame.minX)
                let end = max(badge.frame.maxX, caption.title.frame.maxX)
                XCTAssertEqual((start + end) / 2, caption.bounds.midX, accuracy: 1,
                               "Center the name and badge together, not the name alone.")
                XCTAssertGreaterThanOrEqual(start, 0)
                XCTAssertLessThanOrEqual(end, caption.bounds.width)
                host.rootView = fixture(name, focused: true, direction: direction)
                try await Task.sleep(for: .milliseconds(250))
                XCTAssertTrue(caption.providerBadge === badge, "Focus must not rebuild the badge.")
                XCTAssertEqual(badge.frame, restingFrame)
                XCTAssertEqual(caption.bounds.height, height)
                if name == longName {
                    XCTAssertGreaterThan(title.bounds.width, caption.title.bounds.width)
                    XCTAssertEqual(title.layer.animation(forKey: "captionMarquee") != nil,
                                   !UIAccessibility.isReduceMotionEnabled)
                } else {
                    XCTAssertNil(title.layer.animation(forKey: "captionMarquee"))
                }
                let attachment = XCTAttachment(image: snapshot(window))
                attachment.name = "library-caption-\(direction)-long-\(name == longName)"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
        var transports: [Data] = []
        for provider in ProviderKind.allCases {
            let kinds: [MediaShareTransportKind?] = provider == .mediaShare ? [.smb, .webDAV, .nfs] : [nil]
            for transport in kinds {
                host.rootView = fixture("Movies", provider: provider, transport: transport)
                try await Task.sleep(for: .milliseconds(100))
                let caption = try XCTUnwrap(descendant(SystemPosterCaption.CaptionView.self, in: window))
                XCTAssertNotNil(caption.providerBadge)
                let image = snapshot(window)
                if provider == .mediaShare { transports.append(try XCTUnwrap(image.pngData())) }
                let attachment = XCTAttachment(image: image)
                attachment.name = "library-caption-\(provider.rawValue)-\(transport?.rawValue ?? "")"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
        XCTAssertEqual(Set(transports).count, 3, "The caption must retain each share's actual transport.")
    }

    func testTransportMarkIsUnclippedAndOpticallyCentered() throws {
        let sizes: [CGFloat] = [32, 52, 76]
        for size in sizes {
            for transport in [MediaShareTransportKind.smb, .webDAV, .nfs, .sftp, .ftp] {
                let renderer = ImageRenderer(content:
                    ProviderBrandMark(
                        provider: .mediaShare, size: size, showsBackground: false,
                        mediaShareTransport: transport
                    )
                )
                renderer.scale = 3
                let image = try XCTUnwrap(renderer.cgImage)
                let pixels = try rgba(image)
                let rows = (0..<image.height).filter { y in
                    (0..<image.width).contains { x in pixels[(y * image.width + x) * 4 + 3] > 32 }
                }
                let top = try XCTUnwrap(rows.first)
                let bottom = image.height - 1 - (try XCTUnwrap(rows.last))
                let details = "\(transport), \(size)pt"
                XCTAssertGreaterThan(top, 3, details)
                XCTAssertGreaterThan(bottom, 3, details)
                XCTAssertLessThanOrEqual(abs(top - bottom), 6, "Balanced top/bottom ink padding: \(details)")
                let breaks = zip(rows, rows.dropFirst()).filter { $0.1 > $0.0 + 1 }
                XCTAssertEqual(breaks.count, 2,
                               "The drive's case, front panel and label must remain separate, unclipped shapes: \(details)")
            }
        }
        let renderer = ImageRenderer(content:
            HStack(spacing: 24) {
                ProviderBrandMark(provider: .mediaShare, size: 76, showsBackground: false, mediaShareTransport: .smb)
                ProviderBrandMark(provider: .mediaShare, size: 76, showsBackground: false, mediaShareTransport: .webDAV)
                ProviderBrandMark(provider: .jellyfin, size: 76, showsBackground: false)
            }
            .padding(24)
            .background(.gray)
        )
        renderer.scale = 2
        let attachment = XCTAttachment(image: try XCTUnwrap(renderer.uiImage))
        attachment.name = "unclipped-balanced-provider-marks"
        attachment.lifetime = .keepAlways
        add(attachment)
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
        var images = try [
            "portrait": CGSize(width: 200, height: 300),
            "wide": CGSize(width: 640, height: 180),
            "landscape": CGSize(width: 320, height: 180)
        ].mapValues { size in
            try XCTUnwrap(UIGraphicsImageRenderer(size: size).image {
                UIColor.red.setFill()
                $0.fill(CGRect(origin: .zero, size: size))
            }.pngData())
        }
        let transparentFormat = UIGraphicsImageRendererFormat()
        transparentFormat.scale = 1
        transparentFormat.opaque = false
        images["transparent"] = try XCTUnwrap(UIGraphicsImageRenderer(
            size: CGSize(width: 320, height: 180), format: transparentFormat
        ).image { renderer in
            let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: [UIColor.red.cgColor, UIColor.red.cgColor, UIColor.red.withAlphaComponent(0).cgColor] as CFArray,
                locations: [0, 0.65, 1]
            )!
            renderer.cgContext.drawLinearGradient(
                gradient, start: .zero, end: CGPoint(x: 0, y: 180), options: []
            )
        }.pngData())
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
            for aspect in ["portrait", "wide", "landscape", "transparent"] {
                controller.view.backgroundColor = aspect == "transparent" ? UIColor(white: 0.14, alpha: 1) : .black
                let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/\(aspect)/\(UUID().uuidString)"))
                let synthesized = style == .system && aspect == "landscape"
                let aggregated = AggregatedLibrary(
                    accountID: "fixture", accountName: "Viewer", serverName: "Fixture server",
                    providerKind: aspect == "transparent" ? .emby : .jellyfin,
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
                if style == .system {
                    try await Task.sleep(for: .milliseconds(350))
                }
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
                let restingImage = poster?.image
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
                        XCTAssertTrue(poster.image === restingImage, "Focus must reuse the prepared bitmap.")
                        XCTAssertFalse(poster.imageView.masksFocusEffectToContents)
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
                        if !focused {
                            XCTAssertEqual(frame.minY - artwork.maxY, metrics.landscapeCaptionTopSpacing, accuracy: 1,
                                           "Library captions need the landscape gap even before focus.")
                        }
                        XCTAssertGreaterThanOrEqual(textFrame.minY - artwork.maxY, metrics.landscapeCaptionTopSpacing - 1,
                                                    "The caption must keep breathing room below the focused artwork.")
                        let badge = try XCTUnwrap(caption.providerBadge)
                        let badgeFrame = try XCTUnwrap(NativeFocusProjection.artworkFrame(of: badge, in: window))
                        XCTAssertFalse(badge.isDescendant(of: poster))
                        XCTAssertFalse(badge.canBecomeFocused)
                        XCTAssertGreaterThanOrEqual(badgeFrame.minY - artwork.maxY, metrics.landscapeCaptionTopSpacing - 1,
                                                    "The provider mark must retain the caption's artwork clearance.")
                        XCTAssertLessThanOrEqual(badgeFrame.maxX, textFrame.minX)
                        XCTAssertEqual(slot.bounds.width, metrics.landscapeCardSlotWidth, accuracy: 1)
                        XCTAssertTrue(try isRed(image, at: CGPoint(x: artwork.midX, y: artwork.midY)))
                        for x in [artwork.minX + 3, artwork.maxX - 3] {
                            XCTAssertFalse(try isRed(image, at: CGPoint(x: x, y: artwork.minY + 3)),
                                           "Native artwork must keep rounded corners, including transparent covers: \(aspect), focused=\(focused)")
                        }
                        if aspect == "transparent" {
                            let bitmap = try XCTUnwrap(poster.image?.cgImage)
                            let pixels = try rgba(bitmap)
                            XCTAssertLessThan(pixels[((bitmap.height - 1) * bitmap.width + bitmap.width / 2) * 4 + 3], 16,
                                              "Keep the server cover's fading reflection; do not flatten it onto a plate.")
                            if !focused {
                                let bottom = try pixel(image, at: CGPoint(x: artwork.midX, y: artwork.maxY - 3))
                                XCTAssertGreaterThan(bottom[1], 12, "The backdrop must remain visible through the fade.")
                            }
                        }
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
        XCTAssertNil(caption.providerBadge, "Music and other unbadged poster callers must remain unchanged.")
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
        let pixel = try pixel(image, at: point)
        return pixel[0] > 180 && pixel[1] < 100 && pixel[2] < 100
    }

    private func rgba(_ image: CGImage) throws -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try pixels.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(
                data: bytes.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return pixels
    }

    private func pixel(_ image: UIImage, at point: CGPoint) throws -> [UInt8] {
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
        return pixel
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
