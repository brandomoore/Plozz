#if canImport(UIKit)
import CoreModels
import CoreUI
import SwiftUI
import UIKit
import Vision
import XCTest

@MainActor
final class HomeSectionStatusViewTests: XCTestCase {
    func testEmptySectionReservesSpaceWithoutRecoveryControls() async throws {
        #if os(tvOS)
        let widths: [CGFloat] = [800, 1600]
        let minimumHeight = 220
        #else
        let widths: [CGFloat] = [280, 360, 760]
        let minimumHeight = 180
        #endif
        for width in widths {
            let image = try await render(.empty, width: width)
            let text = try recognize(image)
            XCTAssertTrue(text.contains("No titles to show"), text)
            XCTAssertTrue(text.contains("Media server"), text)
            XCTAssertFalse(text.contains("Details"), text)
            XCTAssertFalse(text.contains("Retry"), text)
            XCTAssertFalse(text.contains("connection"), text)
            XCTAssertFalse(text.contains("Customize Home"), "The editor preview must not link to itself.")
            XCTAssertFalse(text.contains("Dismiss"), "The editor retains its status evidence.")
            let summary = try XCTUnwrap(
                observations(image).first { $0.topCandidates(1).first?.string == "No titles to show" }
            )
            XCTAssertEqual(summary.boundingBox.midX, 0.5, accuracy: 0.02)
            XCTAssertGreaterThanOrEqual(image.height, minimumHeight * 2)
            XCTAssertLessThan(image.height, 700, "An empty row should not reserve a whole poster wall.")
            let attachment = XCTAttachment(image: UIImage(cgImage: image))
            attachment.name = "Empty Home section \(Int(width))"
            attachment.lifetime = .keepAlways
            add(attachment)
            if let directory = ProcessInfo.processInfo.environment["PLOZZ_HOME_STATUS_SNAPSHOTS"] {
                let url = URL(fileURLWithPath: directory).appendingPathComponent("empty-\(Int(width)).png")
                try XCTUnwrap(UIImage(cgImage: image).pngData()).write(to: url)
            }
        }
    }

    func testNonemptyIssueReasonsKeepRecoveryControls() async throws {
        let reasons: [HomeSectionIssue.Reason] = [.failed(.serverUnreachable), .notReturned, .sourceUnavailable]
        for (index, reason) in reasons.enumerated() {
            let width: CGFloat = 1000
            let image = try await render(reason, width: width, onCustomizeHome: {}, onDismissEmpty: {})
            if let directory = ProcessInfo.processInfo.environment["PLOZZ_HOME_STATUS_SNAPSHOTS"] {
                let url = URL(fileURLWithPath: directory).appendingPathComponent("unavailable-\(index).png")
                try XCTUnwrap(UIImage(cgImage: image).pngData()).write(to: url)
            }
            let text = try recognize(image)
            XCTAssertTrue(text.contains("Details"), text)
            XCTAssertTrue(text.contains("Retry"), text)
            XCTAssertTrue(text.contains("Media server"), text)
            XCTAssertFalse(text.contains("Customize Home"), text)
            XCTAssertFalse(text.contains("Dismiss"), text)
        }
    }

    #if os(iOS)
    func testEmptySectionGrowsForAccessibilityTextWithoutClipping() async throws {
        let normal = try await render(.empty, width: 280, onCustomizeHome: {}, onDismissEmpty: {})
        let large = try await render(
            .empty, width: 280, textSize: .accessibility3, onCustomizeHome: {}, onDismissEmpty: {}
        )
        XCTAssertGreaterThan(large.height, normal.height)
        let text = try recognize(large)
        for word in ["No", "titles", "to", "show", "Media", "server", "Customize", "Home", "Dismiss"] {
            XCTAssertTrue(text.contains(word), text)
        }
    }
    #endif

    func testEmptySectionOffersOptionalHomeCustomization() async throws {
        #if os(tvOS)
        let width: CGFloat = 1000
        #else
        let width: CGFloat = 360
        #endif
        let image = try await render(.empty, width: width, onCustomizeHome: {}, onDismissEmpty: {})
        let text = try recognize(image)
        XCTAssertTrue(text.contains("Customize Home"), text)
        XCTAssertTrue(text.contains("Dismiss"), text)
        XCTAssertTrue(text.contains("No titles to show"), text)
        XCTAssertFalse(text.contains("Details"), text)
        XCTAssertFalse(text.contains("Retry"), text)
        XCTAssertLessThan(image.height, 700)
        if let directory = ProcessInfo.processInfo.environment["PLOZZ_HOME_STATUS_SNAPSHOTS"] {
            let url = URL(fileURLWithPath: directory).appendingPathComponent("empty-customize-\(Int(width)).png")
            try XCTUnwrap(UIImage(cgImage: image).pngData()).write(to: url)
        }
    }

    func testEmptySectionRetainsOptionalBrowseAction() async throws {
        #if os(tvOS)
        let width: CGFloat = 1000
        #else
        let width: CGFloat = 360
        #endif
        let text = try recognize(await render(.empty, width: width, onSeeAll: {}))
        XCTAssertTrue(text.contains("See all"), text)
        XCTAssertFalse(text.contains("Details"), text)
        XCTAssertFalse(text.contains("Retry"), text)
    }

    func testCustomizationActionUsesNeutralThemeInkInsteadOfInheritedBlue() async throws {
        #if os(tvOS)
        let width: CGFloat = 1000
        #else
        let width: CGFloat = 360
        #endif
        for (name, palette) in [("dark", ThemePalette.dark), ("light", ThemePalette.light)] {
            let image = try await render(
                .empty, width: width, onCustomizeHome: {}, palette: palette, inheritedTint: .blue
            )
            let action = try XCTUnwrap(
                observations(image).first { $0.topCandidates(1).first?.string == "Customize Home" }
            ).boundingBox
            let crop = try XCTUnwrap(image.cropping(to: CGRect(
                x: action.minX * CGFloat(image.width),
                y: (1 - action.maxY) * CGFloat(image.height),
                width: action.width * CGFloat(image.width),
                height: action.height * CGFloat(image.height)
            ).integral))
            var pixels = [UInt8](repeating: 0, count: crop.width * crop.height * 4)
            try pixels.withUnsafeMutableBytes { bytes in
                let context = try XCTUnwrap(CGContext(
                    data: bytes.baseAddress, width: crop.width, height: crop.height,
                    bitsPerComponent: 8, bytesPerRow: crop.width * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
                ))
                context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
            }
            let coloredPixels = stride(from: 0, to: pixels.count, by: 4).filter { offset in
                let red = Int(pixels[offset]), green = Int(pixels[offset + 1]), blue = Int(pixels[offset + 2])
                return max(red, max(green, blue)) - min(red, min(green, blue)) > 16
            }.count
            XCTAssertEqual(coloredPixels, 0, "\(name): the action must use neutral theme ink, not accent blue.")
            if let directory = ProcessInfo.processInfo.environment["PLOZZ_HOME_STATUS_SNAPSHOTS"] {
                let url = URL(fileURLWithPath: directory).appendingPathComponent("empty-customize-neutral-\(name).png")
                try XCTUnwrap(UIImage(cgImage: image).pngData()).write(to: url)
            }
        }
    }

    private func render(
        _ reason: HomeSectionIssue.Reason, width: CGFloat,
        textSize: DynamicTypeSize = .large, onSeeAll: (() -> Void)? = nil,
        onCustomizeHome: (() -> Void)? = nil, onDismissEmpty: (() -> Void)? = nil,
        palette: ThemePalette = .dark, inheritedTint: Color? = nil
    ) async throws -> CGImage {
        let issue = HomeSectionIssue(
            choice: .init(
                id: .server(accountID: "fixture", section: "seasonal"),
                title: "Seasonal picks", isProviderDefault: true
            ),
            reason: reason, serverName: "Media server", providerKind: .silo
        )
        let content =
            HomeSectionStatusView(
                issue: issue, showsTitle: false, onSeeAll: onSeeAll,
                onCustomizeHome: onCustomizeHome, onDismissEmpty: onDismissEmpty, onRetry: {}
            )
                .environment(\.themePalette, palette)
                .environment(\.colorScheme, palette.isLight ? .light : .dark)
                .environment(\.locale, Locale(identifier: "en_US"))
                .environment(\.dynamicTypeSize, textSize)
                .tint(inheritedTint)
                .frame(width: width)
                .fixedSize(horizontal: false, vertical: true)
                .background(palette.backgroundBase)
                .ignoresSafeArea()
        // Native glass controls need an application scene and render-server capture.
        let host = UIHostingController(rootView: content)
        host.safeAreaRegions = []
        let proposal = CGSize(width: width, height: 2_000)
        let deadline = ContinuousClock.now + .seconds(5)
        while !UIApplication.shared.connectedScenes.contains(where: { $0.activationState == .foregroundActive }),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: host.sizeThatFits(in: proposal))
        window.overrideUserInterfaceStyle = palette.isLight ? .light : .dark
        host.overrideUserInterfaceStyle = window.overrideUserInterfaceStyle
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(250))
        let size = host.sizeThatFits(in: proposal)
        window.frame.size = size
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        host.view.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            XCTAssertTrue(host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true))
        }
        return try XCTUnwrap(image.cgImage)
    }

    private func recognize(_ image: CGImage) throws -> String {
        try observations(image).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
    }

    private func observations(_ image: CGImage) throws -> [VNRecognizedTextObservation] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(cgImage: image).perform([request])
        return request.results ?? []
    }
}
#endif
