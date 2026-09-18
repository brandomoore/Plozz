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
