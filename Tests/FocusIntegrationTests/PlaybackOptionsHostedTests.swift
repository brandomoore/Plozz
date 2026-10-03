import CoreModels
@testable import CoreUI
@testable import FeaturePlayback
import Observation
import SwiftUI
import UIKit
import Vision
import XCTest

@MainActor
final class PlaybackOptionsHostedTests: XCTestCase {
    func testNativeInputHostPreservesPresentationEnvironmentWithoutCopyingFocus() async throws {
        try await waitUntil {
            UIApplication.shared.connectedScenes.contains { $0.activationState == .foregroundActive }
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let state = EnvironmentProbeState()
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: environmentProbe(state: state, revised: false))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        try await waitUntil { state.report?.locale == "ar" }
        var report = try XCTUnwrap(state.report)
        XCTAssertEqual(report.direction, .rightToLeft)
        XCTAssertEqual(report.typeSize, .xxxLarge)
        XCTAssertEqual(report.scheme, .dark)
        XCTAssertFalse(report.enabled)
        XCTAssertTrue(report.hdr)
        XCTAssertTrue(report.reduceTransparency)
        XCTAssertFalse(report.reducePanelGlass, "An explicit material override must still survive the boundary.")
        XCTAssertEqual(report.foreground, ThemePalette.dark.primaryText)

        host.rootView = environmentProbe(state: state, revised: true)
        try await waitUntil { state.report?.locale == "fr" }
        report = try XCTUnwrap(state.report)
        XCTAssertEqual(report.direction, .leftToRight)
        XCTAssertEqual(report.typeSize, .large)
        XCTAssertEqual(report.scheme, .light)
        XCTAssertTrue(report.enabled)
        XCTAssertFalse(report.hdr)
        XCTAssertFalse(report.reduceTransparency)
        XCTAssertTrue(report.reducePanelGlass)
        XCTAssertEqual(report.foreground, ThemePalette.light.primaryText)
    }

    func testInlineSpeedKeepsNativeFocusAndZoomBackRestoresItsEntryRow() async throws {
        try await withPanel { probe, host, window in
            let input = try XCTUnwrap(self.inputController(in: host))
            XCTAssertFalse(input.ownsHorizontalNavigationInput)
            try self.assertFocusedText("Zoom Mode", in: window)
            probe.request(.row(PlaybackOptionsPane.speedSlot))
            try await self.waitUntil { probe.focus == .row(PlaybackOptionsPane.speedSlot) }
            try self.assertFocusedText("Playback Speed", in: window)
            let initialFrame = try XCTUnwrap(self.focusFrame(in: window))
            input.beginPress(.right)
            input.stopRepeating()
            try await self.waitUntil { probe.model.playbackSpeed == 1.55 }
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(self.focusFrame(in: window), initialFrame)
            try self.assertFocusedText("Playback Speed", in: window)
            input.beginPress(.left)
            input.stopRepeating()
            XCTAssertEqual(probe.model.playbackSpeed, 1.5)

            probe.request(.row(PlaybackOptionsPane.zoomSlot))
            try await self.waitUntil { probe.focus == .row(PlaybackOptionsPane.zoomSlot) }
            input.beginPress(.right)
            input.stopRepeating()
            try await self.waitUntil { probe.screen == .zoom && probe.focus == .row(PlaybackOptionsPane.modeSlot(.fit)) }
            try await Task.sleep(for: .milliseconds(350))
            try self.assertFocusedText("Fit", in: window)
            probe.request(.row(PlaybackOptionsPane.customSlot))
            try await self.waitUntil { probe.focus == .row(PlaybackOptionsPane.customSlot) }
            input.beginPress(.right)
            input.stopRepeating()
            try await self.waitUntil { probe.screen == .customZoom && probe.focus == .row(PlaybackOptionsPane.amountSlot) }
            try await Task.sleep(for: .milliseconds(350))
            try self.assertFocusedText("Zoom Amount", in: window)
            input.beginPress(.right)
            try await self.waitUntil { probe.model.videoZoom.settings.customPercent >= 103 }
            input.stopRepeating()
            let percent = probe.model.videoZoom.settings.customPercent
            try await Task.sleep(for: .milliseconds(160))
            XCTAssertEqual(probe.model.videoZoom.settings.customPercent, percent)
            try self.assertFocusedText("Zoom Amount", in: window)

            self.attach(window, name: "Custom zoom submenu")

            probe.backRequest += 1
            try await self.waitUntil {
                probe.screen == .zoom && probe.focus == .row(PlaybackOptionsPane.customSlot)
            }
            try await Task.sleep(for: .milliseconds(350))
            try self.assertFocusedText("Custom", in: window)
            probe.backRequest += 1
            try await self.waitUntil {
                probe.screen == .options && probe.focus == .row(PlaybackOptionsPane.zoomSlot)
            }
            try await Task.sleep(for: .milliseconds(350))
            try self.assertFocusedText("Zoom Mode", in: window)
            XCTAssertTrue(try XCTUnwrap(self.inputController(in: host)) === input,
                          "Submenu navigation must retain the native input host.")
            XCTAssertEqual(probe.model.videoZoom.settings.customPercent, percent)
            XCTAssertEqual(probe.model.playbackSpeed, 1.5)
            self.attach(window, name: "Playback fixed zoom and speed rows")
        }
    }

    func testCustomZoomDoesNotAddParentRowsOrObserveCaptionStyle() async throws {
        try await withPanel { probe, host, window in
            let input = try XCTUnwrap(self.inputController(in: host))
            let image = DetailTransitionSnapshot.image(of: window)
            let lines = try self.text(in: image).map(\.text)
            XCTAssertTrue(lines.contains { $0.contains("Zoom Mode") })
            XCTAssertTrue(lines.contains { $0.contains("Playback Speed") })
            XCTAssertFalse(lines.contains { $0.contains("Zoom Amount") })
            input.beginPress(.left)
            input.stopRepeating()
            XCTAssertEqual(probe.model.videoZoom.settings.mode, .fit, "Left must not change a submenu row.")
            probe.model.videoZoom.setCustomPercent(134)
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertFalse(try self.text(in: DetailTransitionSnapshot.image(of: window))
                .contains { $0.text.contains("Zoom Amount") })
            XCTAssertEqual(probe.screen, .options)
            XCTAssertEqual(probe.focus, .row(PlaybackOptionsPane.zoomSlot))
            XCTAssertFalse(input.ownsHorizontalNavigationInput)
            let zoom = probe.model.videoZoom.settings
            probe.model.subtitleStyle.fontScale = 1.4
            probe.model.currentSeconds = 200
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(probe.model.videoZoom.settings, zoom)
            try self.assertFocusedText("Zoom Mode", in: window)
        }
    }

    @MainActor @Observable
    final class Probe {
        let model = PlayerControlsModel()
        var screen: PlayerControls.PlaybackScreen = .options
        var backRequest = 0
        var focus: PlayerControls.FocusSlot?
        var requestedFocus: PlayerControls.FocusSlot = .row(PlaybackOptionsPane.zoomSlot)
        var focusRequest = 0

        init() {
            model.engineCapabilities = [.videoZoom, .playbackSpeed]
            model.playbackSpeed = 1.5
        }

        func request(_ target: PlayerControls.FocusSlot) {
            requestedFocus = target
            focusRequest += 1
        }
    }

    private struct PanelHost: View {
        let probe: Probe
        @State private var heights: [PlayerControls.Category: CGFloat] = [:]
        @FocusState private var focus: PlayerControls.FocusSlot?

        var body: some View {
            PlayerOptionsPanel(
                category: .playback, model: probe.model, palette: .dark,
                actions: PlayerOptionsActions(setPlaybackSpeed: { probe.model.playbackSpeed = $0 }),
                subtitleScreen: .constant(.tracks), heightCache: $heights, focus: $focus,
                close: {}, backRequest: probe.backRequest, maximumHeight: 900,
                playbackScreen: Binding(get: { probe.screen }, set: { probe.screen = $0 })
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .padding(60)
            .background(.black)
            .onChange(of: focus) { _, value in probe.focus = value }
            .onChange(of: probe.focusRequest) { _, _ in focus = probe.requestedFocus }
        }
    }

    private func withPanel(
        _ body: (Probe, UIViewController, UIWindow) async throws -> Void
    ) async throws {
        try await waitUntil {
            UIApplication.shared.connectedScenes.contains { $0.activationState == .foregroundActive }
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let probe = Probe()
        let host = UIHostingController(rootView: PanelHost(probe: probe))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            inputController(in: host)?.stopRepeating()
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        let system = try XCTUnwrap(UIFocusSystem.focusSystem(for: window))
        try await waitUntil {
            window.layoutIfNeeded()
            system.requestFocusUpdate(to: host)
            system.updateFocusIfNeeded()
            return system.focusedItem != nil
        }
        probe.request(.row(PlaybackOptionsPane.zoomSlot))
        try await waitUntil {
            probe.focus == .row(PlaybackOptionsPane.zoomSlot)
                && self.inputController(in: host) != nil
        }
        try await Task.sleep(for: .milliseconds(150))
        try await body(probe, host, window)
    }

    private func inputController(in root: UIViewController) -> (any PlayerOptionsRemoteInput)? {
        if let input = root as? any PlayerOptionsRemoteInput { return input }
        for child in root.children {
            if let input = inputController(in: child) { return input }
        }
        return nil
    }

    private func focusFrame(in window: UIWindow) -> CGRect? {
        guard let item = UIFocusSystem.focusSystem(for: window)?.focusedItem else { return nil }
        var environment: (any UIFocusEnvironment)? = item
        while let current = environment {
            if let container = current.focusItemContainer {
                return container.coordinateSpace.convert(item.frame, to: window)
            }
            environment = current.parentFocusEnvironment
        }
        return nil
    }

    private func text(in image: UIImage) throws -> [(text: String, bounds: CGRect)] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
        return (request.results ?? []).compactMap { observation in
            guard let text = observation.topCandidates(1).first?.string else { return nil }
            return (text, observation.boundingBox)
        }
    }

    private func assertFocusedText(
        _ expected: String, in window: UIWindow, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let frame = try XCTUnwrap(focusFrame(in: window), file: file, line: line)
        let image = DetailTransitionSnapshot.image(of: window)
        let lines = try text(in: image)
        XCTAssertLessThan(frame.height, 100, "Focus must belong to a row, not its hosting ancestor.", file: file, line: line)
        let highlights = try brightHighlights(in: image)
        XCTAssertEqual(highlights.count, 1, "Only the actual focused control may paint a highlight: \(highlights)", file: file, line: line)
        XCTAssertTrue(lines.contains {
            $0.text.contains(expected) && frame.contains(CGPoint(
                x: $0.bounds.midX * window.bounds.width,
                y: (1 - $0.bounds.midY) * window.bounds.height
            ))
        }, "Native highlight must enclose \(expected); found \(lines.map(\.text))", file: file, line: line)
    }

    private func brightHighlights(in image: UIImage) throws -> [CGRect] {
        let cgImage = try XCTUnwrap(image.cgImage)
        let width = cgImage.width, height = cgImage.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ))
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        var mask = (0..<(width * height)).map { index -> UInt8 in
            let offset = index * 4
            return bytes[offset] > 235 && bytes[offset + 1] > 235 && bytes[offset + 2] > 235 ? 1 : 0
        }
        var rectangles: [CGRect] = []
        for index in mask.indices where mask[index] != 0 {
            var pending = [index], count = 0
            var minX = width, minY = height, maxX = 0, maxY = 0
            mask[index] = 0
            while let pixel = pending.popLast() {
                let x = pixel % width, y = pixel / width
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
                count += 1
                for next in [x > 0 ? pixel - 1 : -1, x + 1 < width ? pixel + 1 : -1,
                             y > 0 ? pixel - width : -1, y + 1 < height ? pixel + width : -1]
                    where next >= 0 && mask[next] != 0 {
                    mask[next] = 0
                    pending.append(next)
                }
            }
            if count >= 700, maxX - minX >= 30, maxY - minY >= 28 {
                rectangles.append(CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1))
            }
        }
        return rectangles
    }

    private func attach(_ window: UIWindow, name: String) {
        let attachment = XCTAttachment(image: DetailTransitionSnapshot.image(of: window))
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func waitUntil(
        file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(condition(), "The native player menu did not reach its expected state.", file: file, line: line)
    }

    struct EnvironmentReport: Equatable {
        let locale: String
        let direction: LayoutDirection
        let typeSize: DynamicTypeSize
        let scheme: ColorScheme
        let enabled: Bool
        let hdr: Bool
        let reduceTransparency: Bool
        let reducePanelGlass: Bool
        let foreground: Color
    }

    @MainActor @Observable
    final class EnvironmentProbeState {
        var report: EnvironmentReport?
    }

    private struct EnvironmentProbe: View {
        let state: EnvironmentProbeState
        @Environment(\.locale) private var locale
        @Environment(\.layoutDirection) private var direction
        @Environment(\.dynamicTypeSize) private var typeSize
        @Environment(\.colorScheme) private var scheme
        @Environment(\.isEnabled) private var enabled
        @Environment(\.plozzHDRDisplayActive) private var hdr
        @Environment(\.plozzReduceTransparency) private var reduceTransparency
        @Environment(\.plozzReducePanelGlass) private var reducePanelGlass
        @Environment(\.themePalette) private var palette

        var body: some View {
            let report = EnvironmentReport(
                locale: locale.identifier, direction: direction, typeSize: typeSize, scheme: scheme,
                enabled: enabled, hdr: hdr, reduceTransparency: reduceTransparency,
                reducePanelGlass: reducePanelGlass, foreground: palette.primaryText
            )
            Text("Presentation environment")
                .onChange(of: report, initial: true) { _, value in state.report = value }
        }
    }

    private func environmentProbe(state: EnvironmentProbeState, revised: Bool) -> AnyView {
        AnyView(PlayerOptionsFocusScope(
            content: EnvironmentProbe(state: state), screen: PlayerControls.PlaybackScreen.options,
            adjustableRow: { nil }, submenuRow: { nil }, onMove: { _, _ in }
        )
        .environment(\.locale, Locale(identifier: revised ? "fr" : "ar"))
        .environment(\.layoutDirection, revised ? .leftToRight : .rightToLeft)
        .environment(\.dynamicTypeSize, revised ? .large : .xxxLarge)
        .environment(\.colorScheme, revised ? .light : .dark)
        .environment(\.isEnabled, revised)
        .environment(\.themePalette, revised ? .light : .dark)
        .environment(\.plozzHDRDisplayActive, !revised)
        .environment(\.plozzReduceTransparency, !revised)
        .environment(\.plozzReducePanelGlass, revised))
    }
}
