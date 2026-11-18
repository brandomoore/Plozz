import CoreModels
import FeatureProfiles
import Observation
import SwiftUI
import UIKit
import XCTest
@testable import CoreUI

@MainActor
final class DialogPresentationHostedTests: XCTestCase {
    #if os(iOS)
    func testSettingsNavigationKeepsThePageBackgroundInsideASheet() async throws {
        for palette in [ThemePalette.pureBlack, .dark, .light] {
            for gradient in [false, true] {
                try await withFixture(palette: palette, gradient: gradient) { window, host, probe in
                    probe.showSettings = true
                    try await waitUntil { host.presentedViewController != nil }
                    let sheet = try XCTUnwrap(host.presentedViewController)
                    try await waitForPresentation(sheet)
                    try await Task.sleep(for: .milliseconds(300))
                    let frame = sheet.view.convert(sheet.view.bounds, to: window)
                    let root = try XCTUnwrap(snapshot(window, name: "settings-root").cgImage)
                    let rootPixels = try rgba(root)
                    for depth in [1, 2, 0] {
                        probe.settingsPath = Array(0..<depth)
                        try await Task.sleep(for: .milliseconds(600))
                        let image = try XCTUnwrap(snapshot(window, name: "settings-depth-\(depth)").cgImage)
                        let pixels = try rgba(image)
                        for point in [
                            CGPoint(x: frame.minX + 8, y: frame.midY),
                            CGPoint(x: frame.midX, y: frame.maxY - 60),
                            CGPoint(x: frame.midX, y: frame.minY + 70)
                        ] {
                            let offset = (Int(point.y) * image.width + Int(point.x)) * 4
                            for channel in 0..<3 {
                                XCTAssertEqual(
                                    Double(pixels[offset + channel]), Double(rootPixels[offset + channel]), accuracy: 3,
                                    "Depth \(depth), gradient \(gradient): pushed Settings must match its root at \(point)"
                                )
                                if palette == .pureBlack, !gradient {
                                    XCTAssertLessThanOrEqual(
                                        pixels[offset + channel], 8, "Black must retain the shared near-black palette"
                                    )
                                }
                            }
                        }
                    }
                    probe.showSettings = false
                    try await waitUntil { host.presentedViewController == nil }
                }
            }
        }
    }
    #endif

    func testProfileActionsSheetOwnsItsWholeBackgroundAcrossThemes() async throws {
        for palette in [ThemePalette.pureBlack, .dark, .light] {
            for gradient in [false, true] {
                for reduced in [false, true] {
                    try await withFixture(palette: palette, gradient: gradient, reduced: reduced) { window, host, probe in
                        probe.profile = DialogProfile(id: "profile")
                        try await waitUntil { host.presentedViewController != nil && probe.sheetOwnsBackground == true }
                        let controller = try XCTUnwrap(host.presentedViewController)
                        try await waitForPresentation(controller)
                        #if os(tvOS)
                        XCTAssertNotNil(UIFocusSystem.focusSystem(for: window)?.focusedItem)
                        #endif
                        let frame = panelFrame(controller, in: window, probe: probe)
                        let theme = palette.isLight ? "light" : (palette == .pureBlack ? "black" : "dark")
                        let image = snapshot(window, name: "profile-dialog-\(theme)-gradient-\(gradient)-reduced-\(reduced)")
                        let geometry = XCTAttachment(string: "panel=\(frame) content=\(probe.contentFrame) window=\(window.bounds)")
                        geometry.lifetime = .keepAlways
                        add(geometry)
                        try assertSurface(image, frame: frame, palette: palette, gradient: gradient)
                        probe.profile = nil
                        try await waitUntil { host.presentedViewController == nil && probe.dismissals == 1 }
                    }
                }
            }
        }
    }

    #if os(tvOS)
    func testFloatingCardsKeepTheirOwnSurfaceAndDimming() async throws {
        try await withFixture(palette: .pureBlack, gradient: true) { window, host, probe in
            probe.showFloating = true
            try await waitUntil { host.presentedViewController != nil && probe.sheetOwnsBackground == false }
            try await waitForPresentation(try XCTUnwrap(host.presentedViewController))
            let image = snapshot(window, name: "shared-dialog-floating")
            try assertSurface(image, frame: probe.contentFrame, palette: .pureBlack, gradient: true)
            let background = try rgba(XCTUnwrap(image.cgImage))
            let reference = ImageRenderer(content: PlozzDialogBackdrop()
                .background(Color.purple)
                .frame(width: window.bounds.width, height: window.bounds.height)
                .environment(\.themePalette, .pureBlack))
            let expected = try rgba(XCTUnwrap(reference.cgImage))
            for channel in 0..<3 {
                XCTAssertEqual(Double(background[channel]), Double(expected[channel]), accuracy: 5,
                               "An existing floating card must be dimmed once, not wrapped in another dialog.")
            }
            XCTAssertEqual(background[3], 255)
            probe.showFloating = false
            try await waitUntil { host.presentedViewController == nil && probe.dismissals == 1 }
        }
    }
    #endif

    func testBooleanSheetAndNestedCoverKeepTheirOwnBackgroundScope() async throws {
        try await withFixture(palette: .pureBlack, gradient: true) { window, host, probe in
            probe.showPlain = true
            try await waitUntil { host.presentedViewController != nil && probe.sheetOwnsBackground == true }
            let sheet = try XCTUnwrap(host.presentedViewController)
            try await waitForPresentation(sheet)
            XCTAssertEqual(sheet.traitCollection.userInterfaceStyle, .light,
                           "The shared background must not override a flow's explicit preferred color scheme.")
            try assertSurface(
                snapshot(window, name: "shared-dialog-plain"), frame: panelFrame(sheet, in: window, probe: probe),
                palette: .pureBlack, gradient: true
            )
            probe.showCover = true
            try await waitUntil { probe.coverOwnsBackground == false && sheet.presentedViewController != nil }
            XCTAssertEqual(probe.sheetOwnsBackground, true)
            probe.showCover = false
            try await waitUntil { sheet.presentedViewController == nil }
            XCTAssertEqual(probe.sheetOwnsBackground, true)
            probe.showPlain = false
            try await waitUntil { host.presentedViewController == nil && probe.dismissals == 1 }
            XCTAssertEqual(probe.presenterOwnsBackground, false)
        }
    }

    private func assertSurface(
        _ image: UIImage, frame: CGRect, palette: ThemePalette, gradient: Bool,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        XCTAssertGreaterThan(frame.width, 0, file: file, line: line)
        XCTAssertGreaterThan(frame.height, 0, file: file, line: line)
        let cg = try XCTUnwrap(image.cgImage)
        let pixels = try rgba(cg)
        let reference = ImageRenderer(content: PlozzDialogBackground()
            .frame(width: frame.width, height: frame.height)
            .environment(\.themePalette, palette)
            .environment(\.gradientBackgroundsEnabled, gradient))
        reference.scale = image.scale
        let expectedImage = try XCTUnwrap(reference.cgImage)
        let expected = try rgba(expectedImage)
        for point in [
            CGPoint(x: frame.midX, y: frame.minY + 4),
            CGPoint(x: frame.midX, y: frame.maxY - 4),
            CGPoint(x: frame.minX + 4, y: frame.midY),
            CGPoint(x: frame.maxX - 4, y: frame.midY)
        ] {
            let x = Int(point.x * image.scale), y = Int(point.y * image.scale)
            let expectedX = Int((point.x - frame.minX) * image.scale)
            let expectedY = Int((point.y - frame.minY) * image.scale)
            let actualOffset = (y * cg.width + x) * 4
            let expectedOffset = (expectedY * expectedImage.width + expectedX) * 4
            guard actualOffset >= 0, actualOffset + 3 < pixels.count,
                  expectedOffset >= 0, expectedOffset + 3 < expected.count else {
                XCTFail("Dialog geometry must remain inside the captured window: \(frame)", file: file, line: line)
                continue
            }
            for component in 0..<3 {
                XCTAssertEqual(
                    Double(pixels[actualOffset + component]), Double(expected[expectedOffset + component]), accuracy: 5,
                    "Native dialog edge \(point) must use the shared full surface, not reveal the purple presenter.",
                    file: file, line: line
                )
            }
        }
    }

    private func withFixture(
        palette: ThemePalette, gradient: Bool, reduced: Bool = false,
        exercise: (UIWindow, UIHostingController<AnyView>, DialogPresentationProbe) async throws -> Void
    ) async throws {
        try await waitUntil { UIApplication.shared.connectedScenes.contains { $0.activationState == .foregroundActive } }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let probe = DialogPresentationProbe()
        let host = UIHostingController(rootView: AnyView(
            DialogPresentationFixture(probe: probe)
                .environment(\.themePalette, palette)
                .environment(\.gradientBackgroundsEnabled, gradient)
                .environment(\.plozzReduceTransparency, reduced)
        ))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            host.dismiss(animated: false)
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        try await waitUntil { probe.presenterOwnsBackground != nil }
        try await exercise(window, host, probe)
    }

    private func waitUntil(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(predicate(), "Native presentation did not complete.", file: file, line: line)
    }

    private func waitForPresentation(_ controller: UIViewController) async throws {
        var previous: CGRect?
        var stableSamples = 0
        try await waitUntil {
            controller.view.window?.layoutIfNeeded()
            let frame = controller.view.layer.presentation()?.frame ?? controller.view.frame
            let settled = !controller.isBeingPresented && controller.transitionCoordinator == nil
            stableSamples = settled && frame == previous ? stableSamples + 1 : 0
            previous = frame
            return stableSamples >= 3
        }
    }

    private func panelFrame(
        _ controller: UIViewController, in window: UIWindow, probe: DialogPresentationProbe
    ) -> CGRect {
        #if os(tvOS)
        probe.contentFrame
        #else
        controller.view.convert(controller.view.bounds, to: window)
        #endif
    }

    private func snapshot(_ window: UIWindow, name: String) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        return image
    }

    private func rgba(_ image: CGImage) throws -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try pixels.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(
                data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return pixels
    }
}

private struct DialogProfile: Identifiable {
    let id: String
}

@MainActor @Observable
private final class DialogPresentationProbe {
    var profile: DialogProfile?
    var showPlain = false
    var showCover = false
    var showFloating = false
    var showSettings = false
    var settingsPath: [Int] = []
    var dismissals = 0
    var presenterOwnsBackground: Bool?
    var sheetOwnsBackground: Bool?
    var coverOwnsBackground: Bool?
    var contentFrame: CGRect = .zero
}

private struct DialogPresentationFixture: View {
    @Bindable var probe: DialogPresentationProbe
    @Environment(\.themePalette) private var palette

    var body: some View {
        Color.purple.ignoresSafeArea()
            .background(DialogOwnershipProbe { probe.presenterOwnsBackground = $0 })
            .plozzSheet(item: $probe.profile, onDismiss: { probe.dismissals += 1 }) { _ in
                ProfileActionsSheet(
                    profile: .init(id: "dialog-fixture", name: "Sample profile", avatarSymbol: "person.fill"),
                    syncEnabled: false, hasParentalPIN: false, restrictedActionsSealed: false,
                    onEditAppearance: {}, onSetLock: { _ in }, onSetKids: { _ in },
                    onDelete: {}, onClose: { probe.profile = nil }
                )
                .background(DialogOwnershipProbe { probe.sheetOwnsBackground = $0 })
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { probe.contentFrame = $0 }
                #if os(iOS)
                .presentationDragIndicator(.hidden)
                #endif
            }
            .plozzSheet(isPresented: $probe.showPlain, onDismiss: { probe.dismissals += 1 }) {
                VStack(spacing: 20) {
                    Text("Shared dialog")
                    Button("Done") { probe.showPlain = false }
                }
                .padding(48)
                .background { SettingsPageBackground() }
                .background(DialogOwnershipProbe { probe.sheetOwnsBackground = $0 })
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { probe.contentFrame = $0 }
                .preferredColorScheme(.light)
                .plozzFullScreenCover(isPresented: $probe.showCover) {
                    AppBackground(palette: .pureBlack)
                        .background(DialogOwnershipProbe { probe.coverOwnsBackground = $0 })
                }
                #if os(iOS)
                .presentationDragIndicator(.hidden)
                #endif
            }
            .plozzSheet(isPresented: $probe.showFloating, onDismiss: { probe.dismissals += 1 }, style: .floatingCard) {
                ZStack {
                    PlozzDialogBackdrop()
                    Text("Floating dialog")
                        .frame(width: 600, height: 400)
                        .plozzSurface(.overlay, cornerRadius: 32)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { probe.contentFrame = $0 }
                }
                .background(DialogOwnershipProbe { probe.sheetOwnsBackground = $0 })
            }
            #if os(iOS)
            .plozzSheet(isPresented: $probe.showSettings) {
                NavigationStack(path: $probe.settingsPath) {
                    settingsPage
                        .navigationDestination(for: Int.self) { _ in settingsPage }
                }
                .environment(\.colorScheme, palette.isLight ? .light : .dark)
                .presentationDragIndicator(.hidden)
            }
            #endif
    }

    #if os(iOS)
    private var settingsPage: some View {
        List {
            SettingsSectionGroup {
                Text("Settings content")
            }
        }
        .settingsPageSurface()
        .navigationTitle("Settings")
    }
    #endif
}

private struct DialogOwnershipProbe: View {
    @Environment(\.plozzDialogBackgroundOwned) private var owned
    let report: (Bool) -> Void
    var body: some View { Color.clear.onChange(of: owned, initial: true) { _, value in report(value) } }
}
