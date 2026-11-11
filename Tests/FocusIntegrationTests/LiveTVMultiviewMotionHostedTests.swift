import CoreModels
@testable import CoreUI
import EnginePlozzigen
import Observation
import SwiftUI
import UIKit
import XCTest
@testable import FeatureLiveTV
@testable import FeaturePlayback

@MainActor
final class LiveTVMultiviewMotionHostedTests: XCTestCase {
    func testLayoutTitlesFollowCountAndOrientationWithoutChangingSavedValues() throws {
        func title(_ layout: LiveTVMultiviewLayout, count: Int, portrait: Bool) -> String {
            var resource = layout.title(count: count, isPortrait: portrait)
            resource.locale = Locale(identifier: "en")
            return String(localized: resource)
        }
        for count in 1...4 {
            for portrait in [false, true] {
                XCTAssertEqual(title(.sideBySide, count: count, portrait: portrait),
                               count > 2 ? "Grid" : portrait ? "Top and bottom" : "Side by side")
                XCTAssertEqual(title(.mainAndStack, count: count, portrait: portrait), "Main picture")
                XCTAssertEqual(title(.corner, count: count, portrait: portrait), "Corner")
            }
        }
        for (rawValue, layout) in [
            ("sideBySide", LiveTVMultiviewLayout.sideBySide), ("mainAndStack", .mainAndStack), ("corner", .corner)
        ] {
            let data = Data("\"\(rawValue)\"".utf8)
            XCTAssertEqual(try JSONDecoder().decode(LiveTVMultiviewLayout.self, from: data), layout)
            XCTAssertEqual(try JSONEncoder().encode(layout), data)
        }
    }

    func testLayoutSymbolStrokesMatchNativeSymbols() throws {
        var measurements: [String] = []
        defer {
            let attachment = XCTAttachment(string: measurements.joined(separator: "\n"))
            attachment.name = "Native and custom symbol stroke measurements"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        for weight in [UIImage.SymbolWeight.ultraLight, .regular, .semibold, .black] {
            for scale in [UIImage.SymbolScale.small, .medium, .large] {
                for pointSize: CGFloat in [20, 32] {
                    let configuration = UIImage.SymbolConfiguration(pointSize: pointSize, weight: weight, scale: scale)
                    let reference = try XCTUnwrap(UIImage(
                        systemName: "rectangle.split.2x1", withConfiguration: configuration))
                    let nativeStroke = try topStrokeThickness(reference)
                    for layout in LiveTVMultiviewLayout.allCases {
                        for count in 2...4 {
                            let corners: [LiveTVMultiviewCorner] = layout == .corner ? LiveTVMultiviewCorner.allCases : [.bottomTrailing]
                            let sizes: [LiveTVMultiviewInsetSize] = layout == .corner ? LiveTVMultiviewInsetSize.allCases : [.medium]
                            for corner in corners {
                                for size in sizes {
                                    let symbol = MultiviewLayoutSymbol(layout: layout, count: count, corner: corner, insetSize: size)
                                    guard symbol.systemName == nil else { continue }
                                    let image = try XCTUnwrap(UIImage(
                                        named: symbol.assetName, in: MultiviewLayoutSymbol.bundle, compatibleWith: nil)?
                                        .applyingSymbolConfiguration(configuration))
                                    let leadingInset = corner == .topLeading || corner == .bottomLeading
                                    let customStroke = try topStrokeThickness(
                                        image, horizontalFraction: layout == .corner && leadingInset ? 0.75 : 0.25,
                                        topBandFraction: layout == .sideBySide ? 0.22 : 0.5)
                                    measurements.append(
                                        "\(symbol.assetName) weight=\(weight.rawValue) scale=\(scale.rawValue) size=\(pointSize): native=\(nativeStroke) custom=\(customStroke)")
                                    XCTAssertEqual(customStroke, nativeStroke, accuracy: max(0.2, nativeStroke * 0.15),
                                                   "\(symbol.assetName), weight \(weight.rawValue), scale \(scale.rawValue), size \(pointSize)")
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func topStrokeThickness(
        _ image: UIImage, horizontalFraction: CGFloat = 0.25, topBandFraction: CGFloat = 0.5
    ) throws -> CGFloat {
        let scale: CGFloat = 4
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        let rendered = UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.withTintColor(.white, renderingMode: .alwaysOriginal).draw(at: .zero)
        }
        let bitmap = try XCTUnwrap(rendered.cgImage)
        let width = bitmap.width
        let height = bitmap.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        try pixels.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(
                data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(bitmap, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        var minX = width, minY = height, maxX = 0, maxY = 0
        for y in 0..<height {
            for x in 0..<width where pixels[(y * width + x) * 4 + 3] > 0 {
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }
        guard minX < maxX, minY < maxY else {
            XCTFail("The symbol must contain visible pixels.")
            return 0
        }
        // Integrate alpha through the top half of a picture, away from dividers
        // and insets. Tiny antialiased gaps need not contain a fully clear pixel.
        let x = minX + Int(CGFloat(maxX - minX) * horizontalFraction)
        let end = CGFloat(minY) + CGFloat(maxY - minY + 1) * topBandFraction
        var coverage: CGFloat = 0
        for y in minY..<Int(ceil(end)) {
            let alpha = CGFloat(pixels[(y * width + x) * 4 + 3]) / 255
            coverage += alpha * min(1, end - CGFloat(y))
        }
        XCTAssertGreaterThan(coverage, 0)
        return coverage / scale
    }

    func testLayoutSymbolsAreNativeCountAwareImagesWithWeightVariants() throws {
        var assets: [String: UIImage] = [:]
        for count in 1...4 {
            for layout in LiveTVMultiviewLayout.allCases {
                for corner in LiveTVMultiviewCorner.allCases {
                    for size in LiveTVMultiviewInsetSize.allCases {
                        let symbol = MultiviewLayoutSymbol(layout: layout, count: count, corner: corner, insetSize: size)
                        let image: UIImage
                        if let name = symbol.systemName {
                            image = try XCTUnwrap(UIImage(systemName: name))
                        } else {
                            image = try XCTUnwrap(UIImage(
                                named: symbol.assetName, in: MultiviewLayoutSymbol.bundle, compatibleWith: nil))
                            assets[symbol.assetName] = image
                        }
                        XCTAssertTrue(image.isSymbolImage, "Layout previews must remain SF Symbol images, not bitmaps.")
                        XCTAssertGreaterThan(image.size.width, 0)
                        XCTAssertGreaterThan(image.size.height, 0)
                    }
                }
            }
        }
        XCTAssertEqual(assets.count, 40)
        let configuration = UIImage.SymbolConfiguration(pointSize: 32, weight: .regular)
        let reference = try XCTUnwrap(UIImage(systemName: "rectangle", withConfiguration: configuration))
        let corner = try XCTUnwrap(assets["multiview.corner.2.bottomTrailing.medium"]?
            .applyingSymbolConfiguration(configuration))
        XCTAssertEqual(corner.size.height, reference.size.height, accuracy: 2,
                       "Custom symbols must match the optical height of Apple's neighboring rectangle symbols.")
        for image in assets.values {
            let light = try XCTUnwrap(image.applyingSymbolConfiguration(
                .init(pointSize: 32, weight: .ultraLight)))
            let bold = try XCTUnwrap(image.applyingSymbolConfiguration(
                .init(pointSize: 32, weight: .black)))
            XCTAssertNotEqual(light.pngData(), bold.pngData(), "Custom symbols must adapt to native font weight.")
        }
        XCTAssertEqual(MultiviewLayoutSymbol(layout: .sideBySide, count: 2, isPortrait: true).systemName,
                       "rectangle.split.1x2")
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let nativeNames = ["rectangle", "rectangle.split.2x1", "rectangle.split.2x2"]
        let nativeImages = try nativeNames.map { (name: $0, image: try XCTUnwrap(UIImage(systemName: $0))) }
        let galleryImages = nativeImages + assets.keys.sorted().map { (name: $0, image: assets[$0]!) }
        let gallery = UIGraphicsImageRenderer(size: CGSize(width: 1080, height: 720), format: format).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1080, height: 720))
            for (index, item) in galleryImages.enumerated() {
                let column = index % 8
                let row = index / 8
                let image = item.image.applyingSymbolConfiguration(.init(pointSize: 36, weight: .regular))!
                    .withTintColor(.white, renderingMode: .alwaysOriginal)
                image.draw(at: CGPoint(x: column * 135 + 45, y: row * 120 + 20))
                let label = item.name.replacingOccurrences(of: "multiview.", with: "")
                (label as NSString).draw(
                    in: CGRect(x: column * 135 + 5, y: row * 120 + 70, width: 125, height: 50),
                    withAttributes: [.font: UIFont.systemFont(ofSize: 11), .foregroundColor: UIColor.white])
            }
        }
        let attachment = XCTAttachment(image: gallery)
        attachment.name = "Native Multiview symbol variants"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testToolbarActionsFadeAndRiseTogetherOnEveryEntrance() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        for reduceMotion in [false, true] {
            let model = ToolbarEntranceModel()
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
            window.rootViewController = UIHostingController(rootView:
                ToolbarEntrancePage(model: model, reduceMotion: reduceMotion))
            window.makeKeyAndVisible()
            defer {
                window.isHidden = true
                window.rootViewController = nil
                previous?.makeKeyAndVisible()
            }
            try await Task.sleep(for: .milliseconds(150))
            for _ in 0..<2 {
                model.visible = true
                var samples: [[(y: CGFloat, opacity: Float)]] = []
                let deadline = ContinuousClock.now + .milliseconds(750)
                while ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(16))
                    guard model.controls.allSatisfy({ $0.window === window }) else { continue }
                    samples.append(model.controls.map { control in
                        let layer = control.layer.presentation() ?? control.layer
                        let y = layer.convert(layer.bounds, to: window.layer.presentation() ?? window.layer).midY
                        var opacity: Float = 1
                        var ancestor: CALayer? = layer
                        while let current = ancestor {
                            opacity *= current.opacity
                            ancestor = current.superlayer
                        }
                        return (y, opacity)
                    })
                }
                XCTAssertGreaterThan(samples.count, 8)
                for sample in samples {
                    for control in sample {
                        XCTAssertEqual(control.y, sample[0].y, accuracy: 0.5)
                        XCTAssertEqual(control.opacity, sample[0].opacity, accuracy: 0.01)
                        XCTAssertGreaterThanOrEqual(control.y, 899.5)
                        XCTAssertLessThanOrEqual(control.y, 920.5)
                    }
                }
                let middle = samples.filter { $0[0].y > 900.5 && $0[0].opacity > 0.01 && $0[0].opacity < 0.99 }
                if reduceMotion {
                    XCTAssertTrue(middle.isEmpty)
                    for sample in samples {
                        XCTAssertEqual(sample[0].y, 900, accuracy: 0.5)
                        XCTAssertEqual(sample[0].opacity, 1, accuracy: 0.01)
                    }
                } else {
                    XCTAssertGreaterThan(middle.count, 3, "All actions must visibly fade and rise, not jump into place.")
                }
                let final = try XCTUnwrap(samples.last?.first)
                XCTAssertEqual(final.y, 900, accuracy: 0.5)
                XCTAssertEqual(final.opacity, 1, accuracy: 0.01)
                model.visible = false
                try await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    @Observable
    final class ToolbarEntranceModel {
        var visible = false
        let controls = (0..<3).map { _ in
            let view = UIView()
            view.backgroundColor = .white
            return view
        }
    }

    private struct ToolbarEntrancePage: View {
        let model: ToolbarEntranceModel
        let reduceMotion: Bool

        var body: some View {
            ZStack(alignment: .topLeading) {
                Color.black
                if model.visible {
                    HStack(spacing: 16) {
                        ForEach(model.controls.indices, id: \.self) { index in
                            ViewportProbe(view: model.controls[index])
                                .frame(width: 160, height: 60)
                        }
                    }
                    .modifier(LiveTVMultiviewToolbarEntrance(reduceMotion: reduceMotion))
                    .position(x: 960, y: 900)
                }
            }
            .ignoresSafeArea()
        }
    }

    func testWorkspacePresentationKeepsItsLiveContentInTheWindowEveryFrame() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let video = UIView()
        video.backgroundColor = .systemBlue
        var state: RetainedFullscreenWorkspaceState?
        window.rootViewController = UIHostingController(rootView:
            RetainedFullscreenWorkspace {
                WorkspaceProbe(video: video, ready: { state = $0 })
            }.ignoresSafeArea())
        window.makeKeyAndVisible()
        let continuity = WindowContinuityProbe(view: video, window: window)
        defer {
            continuity.stop()
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        try await Task.sleep(for: .milliseconds(500))
        let workspace = try XCTUnwrap(state)
        continuity.start()
        for presented in [true, false, true, false] {
            workspace.isPresented = presented
            try await Task.sleep(for: .milliseconds(300))
            XCTAssertFalse(workspace.isTransferring)
            XCTAssertEqual(workspace.isHostingFullscreen, presented)
            XCTAssertEqual(window.rootViewController?.presentedViewController != nil, presented)
            XCTAssertEqual(video.convert(video.bounds, to: window), window.bounds)
        }
        XCTAssertGreaterThan(continuity.frames, 8)
        XCTAssertEqual(continuity.missingFrames, 0,
                       "Presenting and dismissing the isolated workspace must not detach live content for a frame.")
    }

    private struct WorkspaceProbe: View {
        let video: UIView
        let ready: (RetainedFullscreenWorkspaceState) -> Void
        @Environment(\.retainedFullscreenWorkspace) private var workspace

        var body: some View {
            ViewportProbe(view: video)
                .ignoresSafeArea()
                .onAppear { if let workspace { ready(workspace) } }
        }
    }

    private final class WindowContinuityProbe: NSObject {
        let view: UIView
        let window: UIWindow
        var frames = 0
        var missingFrames = 0
        private var displayLink: CADisplayLink?

        init(view: UIView, window: UIWindow) {
            self.view = view
            self.window = window
        }

        func start() {
            let link = CADisplayLink(target: self, selector: #selector(sample))
            displayLink = link
            link.add(to: .main, forMode: .common)
        }

        func stop() {
            displayLink?.invalidate()
            displayLink = nil
        }

        @objc private func sample() {
            frames += 1
            if view.window !== window { missingFrames += 1 }
        }
    }

    func testNativeFocusGainAndLossApplyFinalVideoSizeWithoutIntermediateScaling() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let model = FocusMotionModel()
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        window.rootViewController = UIHostingController(rootView: FocusMotionPage(model: model))
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        try await Task.sleep(for: .seconds(1))
        func presentedWidths() -> [CGFloat] {
            model.engines.map {
                let layer = $0.output.layer.presentation() ?? $0.output.layer
                return layer.convert(layer.bounds, to: window.layer.presentation() ?? window.layer).width
            }
        }
        for selected in [1, 0] {
            let before = presentedWidths()
            model.selected = selected
            var samples: [[CGFloat]] = []
            let deadline = ContinuousClock.now + .milliseconds(700)
            while ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(16))
                window.layoutIfNeeded()
                samples.append(presentedWidths())
            }
            let after = presentedWidths()
            XCTAssertGreaterThan(after[selected], after[1 - selected] + 10)
            for index in 0...1 {
                let low = min(before[index], after[index])
                let high = max(before[index], after[index])
                XCTAssertEqual(samples.filter { $0[index] > low + 1 && $0[index] < high - 1 }.count, 0,
                               "Native focus size must apply directly, without a second scaling animation.")
                XCTAssertTrue(samples.allSatisfy { $0[index] >= low - 1 && $0[index] <= high + 1 })
                XCTAssertTrue(model.engines[index].output.window === window)
                XCTAssertEqual(model.engines[index].stops, 0)
            }
        }
    }

    @Observable
    final class FocusMotionModel {
        let engines = [MotionEngine(), MotionEngine()]
        var selected = 0
    }

    private struct FocusMotionPage: View {
        let model: FocusMotionModel
        var body: some View {
            HStack(spacing: 100) {
                ForEach(0..<2) { index in
                    VideoSurfaceContainer(engine: model.engines[index])
                        .videoCardFocusSurface()
                        .environment(\.videoCardFocus, VideoCardFocus(
                            identifier: "focus-motion-\(index)", title: "Video \(index)",
                            audible: index == model.selected, presentsEffect: true,
                            cornerRadius: 20, horizontalInset: 28, request: model.selected,
                            prefersFocus: index == model.selected, focused: { _ in },
                            activate: {}, promote: {}, replace: {}))
                        .frame(width: 720, height: 405)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.black)
            .ignoresSafeArea()
        }
    }

    func testCardRendererAndItsContainerResizeInTheSameFrames() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let model = SynchronizedCardModel()
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        window.rootViewController = UIHostingController(rootView: SynchronizedCardPage(model: model))
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        try await Task.sleep(for: .milliseconds(500))
        for width in [CGFloat(640), 1600] {
            model.frame = CGRect(x: 100, y: 60, width: width, height: width * 9 / 16)
            var samples: [(container: CGFloat, video: CGFloat)] = []
            let deadline = ContinuousClock.now + .milliseconds(650)
            while ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(16))
                window.layoutIfNeeded()
                samples.append((model.viewport.bounds.width, model.engine.output.bounds.width))
            }
            let differences = samples.map { abs($0.video - max(1, $0.container - 56)) }
            XCTAssertLessThan(try XCTUnwrap(differences.max()), 2,
                              "The video must follow the container in each frame, not start another resize behind it.")
            XCTAssertGreaterThan(Set(samples.map { Int($0.container) }).count, 3)
            XCTAssertEqual(model.engine.output.bounds.width, width - 56, accuracy: 1)
            XCTAssertEqual(model.engine.stops, 0)
        }
        for inset in [CGFloat(0), 28] {
            model.inset = inset
            var widths: [CGFloat] = []
            let deadline = ContinuousClock.now + .milliseconds(650)
            while ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(16))
                window.layoutIfNeeded()
                widths.append(model.engine.output.bounds.width)
            }
            let intermediate = widths.filter { $0 > 1545 && $0 < 1599 }
            XCTAssertGreaterThan(intermediate.count, 2)
            XCTAssertEqual(model.engine.output.bounds.width, 1600 - inset * 2, accuracy: 1)
        }
    }

    @Observable
    final class SynchronizedCardModel {
        let engine = MotionEngine()
        let viewport = UIView()
        var frame = CGRect(x: 0, y: 0, width: 1600, height: 900)
        var inset: CGFloat = 28
    }

    private struct SynchronizedCardPage: View {
        let model: SynchronizedCardModel
        var body: some View {
            ZStack(alignment: .topLeading) {
                Color.black
                VideoSurfaceContainer(engine: model.engine)
                    .videoCardFocusSurface()
                    .background { ViewportProbe(view: model.viewport) }
                    .modifier(PrototypeVideoPlacement(frame: model.frame, focus: VideoCardFocus(
                        identifier: "synchronized-video", title: "Video", audible: true,
                        presentsEffect: false, cornerRadius: 20, horizontalInset: model.inset,
                        request: 0, prefersFocus: true, focused: { _ in },
                        activate: {}, promote: {}, replace: {})))
                    .animation(MultiviewMotion.animation, value: model.frame)
                    .animation(MultiviewMotion.animation, value: model.inset)
            }
            .ignoresSafeArea()
        }
    }

    private struct ViewportProbe: UIViewRepresentable {
        let view: UIView
        func makeUIView(context: Context) -> UIView { view }
        func updateUIView(_ uiView: UIView, context: Context) {}
    }

    func testFourPicturesInterpolatePlacementAndClearanceTogether() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let model = GroupMotionModel()
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        window.rootViewController = UIHostingController(rootView: GroupMotionPage(model: model))
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        try await Task.sleep(for: .milliseconds(500))
        for editing in [true, false, true] {
            model.editing = editing
            var intermediateFrames = 0
            let deadline = ContinuousClock.now + .milliseconds(700)
            while ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(16))
                window.layoutIfNeeded()
                let widths = model.viewports.map { $0.bounds.width }
                XCTAssertLessThan(try XCTUnwrap(widths.max()) - XCTUnwrap(widths.min()), 1)
                if widths[0] > 801, widths[0] < 959 { intermediateFrames += 1 }
                for index in model.engines.indices {
                    let progress = (960 - widths[index]) / 160
                    let output = model.engines[index].output
                    XCTAssertEqual(output.bounds.width, widths[index] - 56 * progress, accuracy: 2,
                                   "Focus clearance must use the same progress as the enclosing picture.")
                    XCTAssertTrue(output.window === window)
                }
            }
            XCTAssertGreaterThan(intermediateFrames, 3)
            for engine in model.engines {
                XCTAssertEqual(engine.output.bounds.width, editing ? 744 : 960, accuracy: 1)
                XCTAssertEqual(engine.stops, 0)
            }
        }
    }

    @MainActor @Observable
    final class GroupMotionModel {
        let engines: [MotionEngine]
        let viewports = (0..<4).map { _ in UIView() }
        var editing = false

        init(engines: [MotionEngine]? = nil) {
            self.engines = engines ?? (0..<4).map { _ in MotionEngine() }
        }
    }

    private struct GroupMotionPage: View {
        let model: GroupMotionModel
        var changesStyle = false

        var body: some View {
            ZStack(alignment: .topLeading) {
                Color.black
                ForEach(0..<4) { index in
                    let width: CGFloat = model.editing ? 800 : 960
                    let frame = CGRect(x: CGFloat(index % 2) * 960, y: CGFloat(index / 2) * 540,
                                       width: width, height: width * 9 / 16)
                    GroupMotionSurface(engine: model.engines[index], presentsEffect: !changesStyle || model.editing)
                        .background { ViewportProbe(view: model.viewports[index]) }
                        .modifier(PrototypeVideoPlacement(frame: frame, focus: VideoCardFocus(
                            identifier: "group-motion-\(index)", title: "Video \(index)",
                            audible: index == 0, presentsEffect: !changesStyle || model.editing,
                            cornerRadius: 20, horizontalInset: model.editing ? 28 : 0,
                            request: 0, prefersFocus: index == 0, focused: { _ in },
                            activate: {}, promote: {}, replace: {})))
                        .animation(MultiviewMotion.animation, value: model.editing)
                }
            }
            .ignoresSafeArea()
        }
    }

    private struct GroupMotionSurface: View {
        let engine: MotionEngine
        let presentsEffect: Bool
        @State private var handoff: VideoPresentationHandoff?

        var body: some View {
            VideoSurfaceContainer(engine: engine)
                .videoCardFocusSurface()
                .onChange(of: presentsEffect) { _, _ in
                    handoff?.cancel(restoringOutput: true)
                    handoff = VideoPresentationHandoff(engine: engine, pictureCornerRadius: 20) {
                        handoff = nil
                    }
                }
                .onDisappear { handoff?.cancel() }
        }
    }

    func testRealRenderersAnimateEveryPictureWhenIdleLabelsBecomeNativeCards() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let engines = try (0..<4).map { _ in try PlozzigenVideoEngine() }
        let model = GroupMotionModel(engines: engines.map { MotionEngine(output: $0.makeVideoOutputView()) })
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        window.rootViewController = UIHostingController(rootView: GroupMotionPage(model: model, changesStyle: true))
        window.makeKeyAndVisible()
        let sampler = RenderedMotionProbe(views: model.engines.map(\.output), window: window)
        defer {
            sampler.stop()
            engines.forEach { $0.stop() }
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        let url = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "live-continuity", withExtension: "mp4", subdirectory: "Fixtures"))
        for (index, engine) in engines.enumerated() {
            await engine.load(request: PlaybackRequest(
                item: MediaItem(id: "motion-\(index)", title: "Motion", kind: .movie),
                streamURL: url), startPosition: 0)
        }
        let ready = ContinuousClock.now + .seconds(15)
        while !engines.allSatisfy({ $0.liveSnapshot.firstFrameReady }), ContinuousClock.now < ready {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(engines.allSatisfy { $0.liveSnapshot.firstFrameReady })
        try await Task.sleep(for: .milliseconds(500))
        for editing in [true, false, true] {
            sampler.start()
            model.editing = editing
            try await Task.sleep(for: .milliseconds(600))
            sampler.stop()
            let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: sampler.frames),
                                           uniformTypeIdentifier: "public.json")
            attachment.name = "real-renderer-motion-\(editing)"
            attachment.lifetime = .keepAlways
            add(attachment)
            XCTAssertGreaterThan(sampler.frames.count, 10)
            for frame in sampler.frames {
                let unfocused = frame.dropFirst()
                XCTAssertLessThan(try XCTUnwrap(unfocused.max()) - XCTUnwrap(unfocused.min()), 1,
                                  "Unfocused pictures must move together on each displayed frame.")
            }
            for index in engines.indices {
                let widths = sampler.frames.map { $0[index] }
                let first = try XCTUnwrap(widths.first)
                let last = try XCTUnwrap(widths.last)
                let low = min(first, last), high = max(first, last)
                XCTAssertGreaterThan(high - low, 100)
                XCTAssertGreaterThan(widths.filter { $0 > low + 2 && $0 < high - 2 }.count, 5,
                                     "Every live picture must visibly animate, including unfocused cards.")
                let steps = zip(widths, widths.dropFirst()).map { abs($1 - $0) }
                XCTAssertLessThan(try XCTUnwrap(steps.max()), (high - low) * 0.3,
                                  "A label replacement must not jump to its new size.")
                XCTAssertTrue(model.engines[index].output.window === window)
            }
        }
    }

    private final class RenderedMotionProbe: NSObject {
        let views: [UIView]
        let window: UIWindow
        var frames: [[CGFloat]] = []
        private var displayLink: CADisplayLink?

        init(views: [UIView], window: UIWindow) {
            self.views = views
            self.window = window
        }

        func start() {
            frames = []
            sample()
            let link = CADisplayLink(target: self, selector: #selector(sample))
            displayLink = link
            link.add(to: .main, forMode: .common)
        }

        func stop() {
            displayLink?.invalidate()
            displayLink = nil
        }

        @objc private func sample() {
            frames.append(views.map {
                guard $0.window === window else { return 0 }
                let layer = $0.layer.presentation() ?? $0.layer
                return layer.convert(layer.bounds, to: window.layer.presentation() ?? window.layer).width
            })
        }
    }

    func testFullscreenHandoffKeepsTheActualOutputVisibleUntilTheInlineHostLaysOut() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let output = fixture.model.engine.output
        let previousHost = try XCTUnwrap(output.superview as? VideoPresentationView)
        let originalFrame = output.convert(output.bounds, to: fixture.window)
        var completions = 0
        let handoff = try XCTUnwrap(VideoPresentationHandoff(engine: fixture.model.engine) {
            completions += 1
        })
        defer { handoff.cancel() }
        fixture.model.visible = false
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(output.superview === handoff)
        XCTAssertTrue(output.window === fixture.window, "Dismissing the old host must not blank the live renderer.")
        XCTAssertEqual(output.convert(output.bounds, to: fixture.window), originalFrame)
        previousHost.attach(fixture.model.engine, deferringOffscreenAttachment: true)
        XCTAssertTrue(output.superview === handoff)
        let nextHost = VideoPresentationView(frame: .zero)
        nextHost.attach(fixture.model.engine, deferringOffscreenAttachment: true)
        XCTAssertTrue(output.superview === handoff, "An offscreen inline host must not end the handoff.")
        fixture.window.addSubview(nextHost)
        nextHost.layoutIfNeeded()
        XCTAssertEqual(completions, 0, "A zero-sized host is not ready to animate.")
        XCTAssertTrue(output.superview === handoff)
        nextHost.frame = fixture.window.bounds
        nextHost.layoutIfNeeded()
        let deadline = ContinuousClock.now + .seconds(2)
        while completions == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(completions, 1)
        XCTAssertNil(handoff.superview)
        XCTAssertTrue(output.superview === nextHost)
        XCTAssertEqual(output.convert(output.bounds, to: fixture.window), originalFrame)
        XCTAssertEqual(fixture.model.engine.stops, 0)
    }

    func testPictureHandoffsKeepBothRenderersVisibleUntilTheirNewLabelsArePresented() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let engines = [MotionEngine(), MotionEngine()]
        let hosts = [
            VideoPresentationView(frame: CGRect(x: 100, y: 300, width: 800, height: 450)),
            VideoPresentationView(frame: CGRect(x: 1020, y: 300, width: 800, height: 450))
        ]
        for (engine, host) in zip(engines, hosts) {
            host.attach(engine)
            host.transform = CGAffineTransform(scaleX: 1.04, y: 1.04)
            fixture.window.addSubview(host)
            host.layoutIfNeeded()
        }
        let frames = engines.map { $0.output.convert($0.output.bounds, to: fixture.window) }
        var completions = 0
        let handoffs = try engines.map { engine in
            try XCTUnwrap(VideoPresentationHandoff(engine: engine, pictureCornerRadius: 20) {
                completions += 1
            })
        }
        defer { handoffs.forEach { $0.cancel() } }
        for index in engines.indices {
            XCTAssertEqual(handoffs[index].frame, frames[index])
            XCTAssertEqual(handoffs[index].backgroundColor, .clear)
            XCTAssertEqual(handoffs[index].layer.cornerRadius, 20)
            hosts[index].removeFromSuperview()
            XCTAssertEqual(engines[index].output.convert(engines[index].output.bounds, to: fixture.window),
                           frames[index])
        }
        let replacements = frames.map { VideoPresentationView(frame: $0) }
        for index in engines.indices {
            replacements[index].alpha = 0
            replacements[index].attach(engines[index], deferringOffscreenAttachment: true)
            fixture.window.addSubview(replacements[index])
            replacements[index].layoutIfNeeded()
        }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(completions, 0)
        for index in engines.indices {
            XCTAssertTrue(engines[index].output.superview === handoffs[index])
            XCTAssertTrue(engines[index].output.window === fixture.window)
            replacements[index].alpha = 1
        }
        let deadline = ContinuousClock.now + .seconds(2)
        while completions < 2, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(completions, 2)
        for index in engines.indices {
            XCTAssertTrue(engines[index].output.superview === replacements[index])
            XCTAssertNil(handoffs[index].superview)
            XCTAssertEqual(engines[index].stops, 0)
        }
    }

    func testCancellingPictureHandoffRestoresItsOriginalTransform() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let output = fixture.model.engine.output
        let host = try XCTUnwrap(output.superview)
        host.transform = CGAffineTransform(scaleX: 1.05, y: 1.05)
        output.transform = CGAffineTransform(scaleX: 1.2, y: 1.2)
        let originalFrame = output.convert(output.bounds, to: fixture.window)
        let originalTransform = output.transform
        func assertOriginalFrame() {
            let actual = output.convert(output.bounds, to: fixture.window)
            for component in [\CGRect.minX, \.minY, \.width, \.height] {
                XCTAssertEqual(actual[keyPath: component], originalFrame[keyPath: component], accuracy: 0.001)
            }
        }
        let handoff = try XCTUnwrap(VideoPresentationHandoff(engine: fixture.model.engine, pictureCornerRadius: 20) {
            XCTFail("A cancelled focus handoff must not complete.")
        })
        XCTAssertEqual(handoff.frame, host.convert(host.bounds, to: fixture.window))
        XCTAssertTrue(handoff.clipsToBounds, "Zoomed video must not cover neighboring pictures during a handoff.")
        assertOriginalFrame()
        handoff.cancel(restoringOutput: true)
        XCTAssertTrue(output.superview === host)
        XCTAssertEqual(output.transform, originalTransform)
        assertOriginalFrame()
        XCTAssertNil(handoff.superview)
        try await Task.sleep(for: .milliseconds(20))
    }

    func testCancelledFullscreenHandoffCannotStartMultiviewBeforeItsNewHostIsPresented() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        var completions = 0
        let handoff = try XCTUnwrap(VideoPresentationHandoff(engine: fixture.model.engine) {
            completions += 1
        })
        let nextHost = VideoPresentationView(frame: fixture.window.bounds)
        nextHost.attach(fixture.model.engine, deferringOffscreenAttachment: true)
        fixture.window.addSubview(nextHost)
        nextHost.layoutIfNeeded()
        handoff.cancel()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(completions, 0)
        XCTAssertNil(handoff.superview)
        XCTAssertNil(fixture.model.engine.output.superview)
        XCTAssertEqual(fixture.model.engine.stops, 0)
    }

    func testDeclinedMultiviewRestoresTheInlineRendererWithoutRestartingIt() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let output = fixture.model.engine.output
        let originalHost = output.superview
        let originalFrame = output.frame
        var completions = 0
        let handoff = try XCTUnwrap(VideoPresentationHandoff(engine: fixture.model.engine) {
            completions += 1
        })
        handoff.cancel(restoringOutput: true)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(completions, 0)
        XCTAssertTrue(output.superview === originalHost)
        XCTAssertEqual(output.frame, originalFrame)
        XCTAssertTrue(output.window === fixture.window)
        XCTAssertNil(handoff.superview)
        XCTAssertEqual(fixture.model.engine.stops, 0)
    }

    func testEnteringWindowClaimsOutputFromAnotherOffscreenLabel() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let engine = MotionEngine()
        let incoming = VideoPresentationView(frame: CGRect(x: 0, y: 0, width: 640, height: 360))
        let preparedLabel = VideoPresentationView(frame: incoming.frame)
        incoming.attach(engine, deferringOffscreenAttachment: true)
        preparedLabel.attach(engine, deferringOffscreenAttachment: true)
        XCTAssertTrue(engine.output.superview === preparedLabel)
        fixture.window.addSubview(incoming)
        fixture.window.layoutIfNeeded()
        XCTAssertTrue(engine.output.superview === incoming)
        XCTAssertTrue(engine.output.window === fixture.window)
        XCTAssertEqual(engine.output.bounds.size, incoming.bounds.size)
        XCTAssertEqual(engine.stops, 0)
    }

    func testOffscreenNativeCardLabelCannotStealTheVisibleVideoOutput() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let output = fixture.model.engine.output
        let visibleParent = try XCTUnwrap(output.superview as? VideoPresentationView)
        let replacement = VideoPresentationView(frame: CGRect(x: 0, y: 0, width: 640, height: 360))
        replacement.attach(fixture.model.engine, deferringOffscreenAttachment: true)
        XCTAssertTrue(output.superview === visibleParent)
        XCTAssertTrue(output.window === fixture.window)
        fixture.window.addSubview(replacement)
        fixture.window.layoutIfNeeded()
        XCTAssertTrue(output.superview === replacement)
        XCTAssertTrue(output.window === fixture.window)
        visibleParent.attach(fixture.model.engine, deferringOffscreenAttachment: true)
        XCTAssertTrue(output.superview === replacement, "An outgoing label must not steal back the live output.")
        visibleParent.removeFromSuperview()
        XCTAssertTrue(output.window === fixture.window)
        XCTAssertEqual(fixture.model.engine.stops, 0)
    }

    func testNativeCardCanLiftLiveVideoAndDisableItsEffectWhileRetainingFocus() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let model = NativeCardModel()
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        window.rootViewController = UIHostingController(rootView: NativeCardPage(model: model))
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        try await Task.sleep(for: .seconds(1))
        window.layoutIfNeeded()
        let output = model.engine.output
        let focused = output.convert(output.bounds, to: window)
        let focus = UIFocusSystem.focusSystem(for: window)?.focusedItem
        XCTAssertNotNil(focus)
        XCTAssertGreaterThan(focused.width, 961, "Native card focus must lift the live video itself.")
        func capture(_ name: String) {
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        capture("native-live-video-focused")
        model.presentsFocus = false
        try await Task.sleep(for: .seconds(1))
        window.layoutIfNeeded()
        capture("native-live-video-effect-disabled")
        let idle = output.convert(output.bounds, to: window)
        XCTAssertEqual(idle.width, 960, accuracy: 1)
        XCTAssertNotNil(UIFocusSystem.focusSystem(for: window)?.focusedItem)
        XCTAssertTrue(output.window === window)
        XCTAssertEqual(model.engine.stops, 0)
        for enabled in [false, true, false, true] {
            model.enabled = enabled
            model.presentsFocus = enabled
            try await Task.sleep(for: .milliseconds(500))
            window.layoutIfNeeded()
            XCTAssertTrue(output.window === window, "Changing card ownership must preserve the windowed video.")
            XCTAssertEqual(model.engine.stops, 0)
        }
    }

    @Observable
    final class NativeCardModel {
        let engine = MotionEngine()
        var presentsFocus = true
        var enabled = true
    }

    private struct NativeCardPage: View {
        let model: NativeCardModel
        var body: some View {
            ZStack {
                Color.black
                VideoSurfaceContainer(engine: model.engine)
                    .videoCardFocusSurface()
                    .environment(\.videoCardFocus, model.enabled ? VideoCardFocus(
                        identifier: "native-video-card", title: "Live video", audible: true,
                        presentsEffect: model.presentsFocus, cornerRadius: 20, horizontalInset: 0,
                        request: 0, prefersFocus: true, focused: { _ in },
                        activate: {}, promote: {}, replace: {}) : nil)
                    .frame(width: 960, height: 540)
            }
            .ignoresSafeArea()
        }
    }

    func testPictureLayoutMotionTakesHalfASecondWithoutOvershooting() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let start = ContinuousClock.now
        fixture.model.frame = CGRect(x: 180, y: 120, width: 640, height: 360)
        var intermediateFrames = 0
        var completed = false
        while ContinuousClock.now - start < .seconds(1) {
            try await Task.sleep(for: .milliseconds(16))
            fixture.window.layoutIfNeeded()
            let width = fixture.model.engine.output.bounds.width
            XCTAssertGreaterThanOrEqual(width, 639)
            XCTAssertLessThanOrEqual(width, 1921)
            if width > 641 && width < 1919 { intermediateFrames += 1 }
            if abs(width - 640) <= 1 {
                XCTAssertGreaterThan(ContinuousClock.now - start, .milliseconds(430),
                                     "Layout must not snap or finish at the former 0.32-second pace.")
                completed = true
                break
            }
        }
        XCTAssertTrue(completed)
        XCTAssertGreaterThan(intermediateFrames, 8)
    }

    func testEmbeddedVideoResizesThroughIntermediateBoundsWithoutReplacingOutput() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let output = fixture.model.engine.output
        let originalSuperview = output.superview
        let start = output.bounds.width
        fixture.model.frame = CGRect(x: 180, y: 120, width: 640, height: 360)
        let samples = try await sample(fixture, milliseconds: 650)
        XCTAssertGreaterThan(samples.filter { $0.width > 641 && $0.width < start - 1 }.count, 2,
                             "The actual engine view must resize, not just its SwiftUI wrapper.")
        try await waitForVideoSize(CGSize(width: 640, height: 360), in: fixture)
        XCTAssertEqual(output.bounds.width, 640, accuracy: 1)
        XCTAssertEqual(output.bounds.height, 360, accuracy: 1)
        XCTAssertTrue(output.superview === originalSuperview)
        XCTAssertEqual(originalSuperview?.subviews.filter { $0 === output }.count, 1)
        XCTAssertEqual(fixture.model.engine.stops, 0)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(bounds: fixture.window.bounds, format: format).image { _ in
            XCTAssertTrue(fixture.window.drawHierarchy(in: fixture.window.bounds, afterScreenUpdates: true))
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "Retained video with rounded picture corners"
        attachment.lifetime = .keepAlways
        add(attachment)
        let bitmap = try XCTUnwrap(image.cgImage)
        var pixel = [UInt8](repeating: 0, count: 4)
        func color(at point: CGPoint) throws -> [UInt8] {
            try pixel.withUnsafeMutableBytes { bytes in
                let context = try XCTUnwrap(CGContext(
                    data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                    bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                let crop = try XCTUnwrap(bitmap.cropping(to: CGRect(origin: point, size: CGSize(width: 1, height: 1))))
                context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            }
            return pixel
        }
        XCTAssertTrue(try color(at: CGPoint(x: 181, y: 121)).prefix(3).allSatisfy { $0 < 20 })
        XCTAssertGreaterThan(try color(at: CGPoint(x: 500, y: 121))[2], 200)
    }

    func testRapidLayoutReversalStartsFromVisibleVideoGeometry() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        fixture.model.frame = CGRect(x: 100, y: 100, width: 480, height: 270)
        _ = try await sample(fixture, milliseconds: 110)
        let midWidth = fixture.model.engine.output.bounds.width
        XCTAssertGreaterThan(midWidth, 481)
        XCTAssertLessThan(midWidth, 1919)
        fixture.model.frame = CGRect(x: 80, y: 40, width: 1600, height: 900)
        let samples = try await sample(fixture, milliseconds: 650)
        XCTAssertFalse(samples.contains { $0.width < 480 || $0.width > max(midWidth, 1600) + 2 })
        XCTAssertEqual(fixture.model.engine.output.bounds.width, 1600, accuracy: 1)
        XCTAssertEqual(fixture.model.engine.stops, 0)
    }

    func testFocusInsetAnimatesActualVideoBothWaysAndHonorsReduceMotion() async throws {
        for reduceMotion in [false, true] {
            let fixture = try await makeFixture(reduceMotion: reduceMotion)
            defer { fixture.close() }
            let full = fixture.model.frame
            let inset = LiveTVMultiviewGeometry.presentationFrame(
                in: full, aspectRatio: 16 / 9, focusActive: true)
            fixture.model.frame = inset
            let shrinking = try await sample(fixture, milliseconds: 650)
            XCTAssertEqual(fixture.model.engine.output.bounds.width, inset.width, accuracy: 1)
            fixture.model.frame = full
            let growing = try await sample(fixture, milliseconds: 650)
            for samples in [shrinking, growing] {
                let intermediate = samples.filter { $0.width > inset.width + 1 && $0.width < full.width - 1 }
                if reduceMotion {
                    XCTAssertTrue(intermediate.isEmpty)
                } else {
                    XCTAssertGreaterThan(intermediate.count, 2)
                }
            }
            XCTAssertEqual(fixture.model.engine.output.bounds.width, full.width, accuracy: 1)
            XCTAssertEqual(fixture.model.engine.stops, 0)
        }
    }

    func testReduceMotionUsesFinalVideoBoundsWithoutIntermediateLayouts() async throws {
        let fixture = try await makeFixture(reduceMotion: true)
        defer { fixture.close() }
        fixture.model.frame = CGRect(x: 100, y: 100, width: 640, height: 360)
        let samples = try await sample(fixture, milliseconds: 420)
        XCTAssertFalse(samples.contains { $0.width > 641 && $0.width < 1919 })
        XCTAssertEqual(fixture.model.engine.output.bounds.width, 640, accuracy: 1)
    }

    func testRoundedClipCutsPictureCornersButKeepsItsCenter() {
        XCTAssertEqual(LiveTVMultiviewGeometry.videoCornerRadius, 20)
        let clip = PrototypeVideoClip(
            reflectionHeight: 0, cornerRadius: LiveTVMultiviewGeometry.videoCornerRadius)
        let picture = LiveTVMultiviewGeometry.contentFrame(
            in: CGRect(x: 0, y: 0, width: 960, height: 1080), aspectRatio: 16 / 9)
        XCTAssertEqual(picture.size, CGSize(width: 960, height: 540))
        let bounds = CGRect(origin: .zero, size: picture.size)
        let path = clip.path(in: bounds)
        XCTAssertFalse(path.contains(CGPoint(x: 1, y: 1)))
        XCTAssertTrue(path.contains(CGPoint(x: bounds.midX, y: 1)))
        XCTAssertTrue(path.contains(CGPoint(x: bounds.midX, y: bounds.midY)))
        XCTAssertTrue(PrototypeVideoClip(reflectionHeight: 0, cornerRadius: 0)
            .path(in: bounds).contains(CGPoint(x: 1, y: 1)))
    }

    func testPaneRemovalAnimatesItsExistingSurfaceBeforeDetaching() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let output = fixture.model.engine.output
        fixture.model.visible = false
        _ = try await sample(fixture, milliseconds: 80)
        XCTAssertNotNil(output.window, "The outgoing video must remain attached during its transition.")
        _ = try await sample(fixture, milliseconds: 600)
        XCTAssertNil(output.window)
        fixture.model.visible = true
        _ = try await sample(fixture, milliseconds: 650)
        XCTAssertTrue(output.window === fixture.window)
    }

    private func sample(_ fixture: Fixture, milliseconds: Int) async throws -> [CGSize] {
        var samples: [CGSize] = []
        let deadline = ContinuousClock.now + .milliseconds(milliseconds)
        while ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(16))
            fixture.window.layoutIfNeeded()
            samples.append(fixture.model.engine.output.bounds.size)
        }
        return samples
    }

    private func waitForVideoSize(_ size: CGSize, in fixture: Fixture) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while fixture.model.engine.output.bounds.size != size, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(16))
            fixture.window.layoutIfNeeded()
        }
        XCTAssertEqual(fixture.model.engine.output.bounds.size, size)
    }

    private func makeFixture(reduceMotion: Bool = false) async throws -> Fixture {
        let deadline = ContinuousClock.now + .seconds(5)
        while !UIApplication.shared.connectedScenes.contains(where: { $0.activationState == .foregroundActive }),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let fixture = Fixture(scene: scene, reduceMotion: reduceMotion)
        do {
            _ = try await sample(fixture, milliseconds: 180)
            XCTAssertEqual(fixture.model.engine.output.bounds.width, 1920, accuracy: 1)
            return fixture
        } catch {
            fixture.close()
            throw error
        }
    }

    @Observable
    final class Model {
        var frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        var visible = true
        let engine = MotionEngine()
    }

    private struct Page: View {
        let model: Model
        let reduceMotion: Bool
        var body: some View {
            ZStack(alignment: .topLeading) {
                Color.black
                if model.visible {
                    VideoSurfaceContainer(engine: model.engine)
                        .clipShape(PrototypeVideoClip(
                            reflectionHeight: 0, cornerRadius: LiveTVMultiviewGeometry.videoCornerRadius))
                        .modifier(PrototypeVideoPlacement(frame: model.frame))
                        .transition(reduceMotion ? .identity : .scale(scale: 0.94).combined(with: .opacity))
                        .animation(reduceMotion ? nil : MultiviewMotion.animation, value: model.frame)
                }
            }
            .animation(reduceMotion ? nil : MultiviewMotion.animation, value: model.visible)
            .ignoresSafeArea()
        }
    }

    private final class Fixture {
        let model = Model()
        let window: UIWindow
        let previous: UIWindow?
        init(scene: UIWindowScene, reduceMotion: Bool) {
            previous = scene.windows.first(where: \.isKeyWindow)
            window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
            window.rootViewController = UIHostingController(rootView: Page(model: model, reduceMotion: reduceMotion))
            window.makeKeyAndVisible()
            window.layoutIfNeeded()
        }
        func close() {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
    }

    final class MotionEngine: VideoEngine {
        let output: UIView
        init(output: UIView = UIView()) { self.output = output }
        var stops = 0
        var status: VideoEngineStatus { .ready }
        var isPaused: Bool { false }
        var currentTime: TimeInterval { 0 }
        var duration: TimeInterval { 0 }
        var furthestObservedPosition: TimeInterval { 0 }
        var audioTracks: [MediaTrack] { [] }
        var subtitleTracks: [MediaTrack] { [] }
        var videoAspectRatio: Double? { 16 / 9 }
        var onProgress: (@MainActor () -> Void)?
        var onFailure: (@MainActor (AppError) -> Void)?
        var onEnded: (@MainActor () -> Void)?
        var onTracksChanged: (@MainActor () -> Void)?
        var onProbedSourceFactsChanged: (@MainActor (EngineProbedSourceFacts) -> Void)?
        var onSubtitleCues: (@MainActor ([SubtitleCue]) -> Void)?
        var onSecondarySubtitleCues: (@MainActor ([SubtitleCue]) -> Void)?
        func load(request: PlaybackRequest, startPosition: TimeInterval) async {}
        func play() {}
        func pause() {}
        func stop() { stops += 1 }
        func seek(to seconds: TimeInterval) async {}
        func selectAudioTrack(_ track: MediaTrack?) {}
        func selectSubtitleTrack(_ track: MediaTrack?) {}
        func makeVideoOutputView() -> UIView {
            output.backgroundColor = .blue
            return output
        }
    }
}
