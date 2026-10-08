#if os(iOS)
import CoreModels
import CoreUI
import SwiftUI
import UIKit
import Vision
import XCTest
@testable import AppShelliOS

@MainActor
final class ProfilePickerPresentationTests: XCTestCase {
    func testLayoutUsesCompactAvatarsAndBoundsLargeHouseholds() {
        for width in [CGFloat(320), 390, 430, 768, 1024] {
            for count in [1, 3, 6, 12, 40] {
                let layout = PlozziOSProfilePickerLayout(
                    width: width, itemCount: count, usesAccessibleText: false
                )
                XCTAssertLessThanOrEqual(layout.contentWidth, min(640, width - 48))
                XCTAssertLessThanOrEqual(layout.avatarSize, 104)
                XCTAssertGreaterThanOrEqual(layout.avatarSize, 64)
                XCTAssertLessThanOrEqual(
                    CGFloat(layout.columnCount) * layout.avatarSize
                        + CGFloat(layout.columnCount - 1) * layout.columnSpacing,
                    layout.contentWidth
                )
            }
        }
        XCTAssertEqual(PlozziOSProfilePickerLayout(
            width: 390, itemCount: 12, usesAccessibleText: false
        ).columnCount, 3)
        XCTAssertEqual(PlozziOSProfilePickerLayout(
            width: 390, itemCount: 12, usesAccessibleText: true
        ).columnCount, 1)
    }

    func testRenderedPickerFitsThemesWidthsAndHouseholdSizes() async throws {
        let cases: [(CGSize, Int, ThemePalette, Bool)] = [
            (.init(width: 390, height: 844), 3, .dark, true),
            (.init(width: 390, height: 844), 10, .dark, true),
            (.init(width: 320, height: 568), 12, .light, false),
            (.init(width: 768, height: 1024), 4, .light, true),
            (.init(width: 844, height: 390), 6, .pureBlack, false),
            (.init(width: 390, height: 844), 1, .light, false)
        ]
        for (size, count, palette, gradient) in cases {
            try await renderPicker(size: size, count: count, palette: palette, gradient: gradient) { window in
                let scroll = try XCTUnwrap(self.scrollViews(window).first)
                XCTAssertLessThanOrEqual(scroll.contentSize.width, scroll.bounds.width + 1)
                let image = self.capture(window, name: "picker-\(Int(size.width))-\(count)-\(gradient)")
                let text = try self.recognize(image)
                XCTAssertTrue(text.contains { $0.contains(count == 1 ? "Profiles" : "watching") }, "\(text)")
                XCTAssertTrue(text.contains { $0.contains("Alex") }, "\(text)")
                XCTAssertFalse(text.contains { $0.contains("Choose a profile") })
                if count <= 4, size.height > 700 {
                    XCTAssertLessThanOrEqual(scroll.contentSize.height, scroll.bounds.height + 1)
                }
                if count == 12 {
                    for _ in 0..<3 {
                        scroll.setContentOffset(CGPoint(x: 0, y: max(
                            0, scroll.contentSize.height - scroll.bounds.height
                        )), animated: false)
                        try await Task.sleep(for: .milliseconds(80))
                    }
                    let bottom = self.capture(window, name: "picker-many-bottom")
                    XCTAssertTrue(try self.recognize(bottom).contains { $0.contains("Viewer 12") })
                }
            }
        }
    }

    func testAccessibleLongNamesWrapAndRemainScrollableInBothDirections() async throws {
        for direction in [LayoutDirection.leftToRight, .rightToLeft] {
            try await renderPicker(
                size: .init(width: 390, height: 844), count: 8, palette: .dark,
                gradient: true, typeSize: .accessibility3, direction: direction
            ) { window in
                let scroll = try XCTUnwrap(self.scrollViews(window).first)
                XCTAssertLessThanOrEqual(scroll.contentSize.width, scroll.bounds.width + 1)
                XCTAssertGreaterThan(scroll.contentSize.height, scroll.bounds.height)
                let text = try self.recognize(self.capture(window, name: "picker-accessible-\(direction)"))
                XCTAssertTrue(text.contains { $0.contains("Alex") })
                XCTAssertFalse(text.contains { $0.contains("…") })
            }
        }
    }

    func testEntranceIsStaggeredSettlesWithoutOvershootAndHonorsReduceMotion() async throws {
        XCTAssertEqual(PlozziOSProfilePickerEntrance.delay(at: 0), 0)
        XCTAssertEqual(PlozziOSProfilePickerEntrance.delay(at: 1), 0.05)
        XCTAssertEqual(PlozziOSProfilePickerEntrance.delay(at: 100), 0.3)
        XCTAssertEqual(PlozziOSProfilePickerEntrance.initialScale, 0.94)
        let model = PickerMotionFixtureModel()
        try await withWindow(
            PickerMotionFixture(model: model), size: .init(width: 240, height: 360)
        ) { window in
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertLessThan(try self.brightness(self.capture(window), x: 70, y: 70), 5)
            model.isPresented = true
            try await Task.sleep(for: .milliseconds(120))
            let entering = self.capture(window, name: "picker-motion-early", afterUpdates: false)
            let first = try self.brightness(entering, x: 70, y: 70)
            let last = try self.brightness(entering, x: 70, y: 190)
            XCTAssertGreaterThan(first, last + 20, "The first tile must lead the later tile.")
            try await Task.sleep(for: .milliseconds(750))
            let settled = self.capture(window, name: "picker-motion-settled")
            XCTAssertGreaterThan(try self.brightness(settled, x: 70, y: 70), 245)
            XCTAssertGreaterThan(try self.brightness(settled, x: 70, y: 190), 245)
            XCTAssertLessThan(try self.brightness(settled, x: 17, y: 70), 5)
        }
        let reduced = PickerMotionFixtureModel()
        try await withWindow(
            PickerMotionFixture(model: reduced, reduceMotion: true),
            size: .init(width: 240, height: 360)
        ) { window in
            try await Task.sleep(for: .milliseconds(100))
            let image = self.capture(window, name: "picker-reduce-motion")
            XCTAssertGreaterThan(try self.brightness(image, x: 70, y: 70), 245)
            XCTAssertGreaterThan(try self.brightness(image, x: 70, y: 190), 245)
            XCTAssertGreaterThan(try self.brightness(image, x: 21, y: 70), 245)
        }
    }

    func testProductionPickerActuallyAnimatesOnPresentation() async throws {
        let profiles = (0..<6).map {
            Profile(id: "motion-\($0)", name: "Viewer \($0)", avatarSymbol: "person.fill", colorIndex: 0)
        }
        try await withWindow(
            PlozziOSProfilePickerView(profiles: profiles, activeProfileID: profiles[0].id, onSelect: { _ in })
                .environment(\.themePalette, .pureBlack)
                .environment(\.gradientBackgroundsEnabled, false)
                .preferredColorScheme(.dark),
            size: .init(width: 390, height: 844)
        ) { window in
            try await Task.sleep(for: .milliseconds(80))
            let entering = self.capture(window, name: "production-picker-entering", afterUpdates: false)
            try await Task.sleep(for: .milliseconds(150))
            let cascading = self.capture(window, name: "production-picker-cascading", afterUpdates: false)
            try await Task.sleep(for: .milliseconds(700))
            let settled = self.capture(window, name: "production-picker-settled")
            let early = try self.redPixelCount(entering)
            let middle = try self.redPixelCount(cascading)
            let final = try self.redPixelCount(settled)
            XCTAssertGreaterThan(final, 10_000, "The actual shared avatars must be rendered.")
            XCTAssertLessThan(early, final * 9 / 10, "The production grid must reveal, not start fully visible.")
            XCTAssertGreaterThan(middle, 1_000, "Some avatars must already be appearing.")
            XCTAssertLessThan(middle, final * 9 / 10, "The cascade must not appear all at once.")
        }
    }

    private func renderPicker(
        size: CGSize, count: Int, palette: ThemePalette, gradient: Bool,
        typeSize: DynamicTypeSize = .large, direction: LayoutDirection = .leftToRight,
        inspect: (UIWindow) async throws -> Void
    ) async throws {
        let profiles = (0..<count).map { index in
            Profile(
                id: "fixture-\(index)",
                name: index == 0 ? (typeSize.isAccessibilitySize ? "Alex with a longer profile name" : "Alex")
                    : "Viewer \(index + 1)",
                avatarSymbol: ["person.fill", "star.fill", "moon.fill"][index % 3],
                colorIndex: index % 5
            )
        }
        try await withWindow(
            PlozziOSProfilePickerView(profiles: profiles, activeProfileID: profiles[0].id, onSelect: { _ in })
                .environment(\.themePalette, palette)
                .environment(\.gradientBackgroundsEnabled, gradient)
                .environment(\.dynamicTypeSize, typeSize)
                .environment(\.layoutDirection, direction)
                .environment(\.locale, Locale(identifier: "en"))
                .preferredColorScheme(palette.isLight ? .light : .dark),
            size: size
        ) { window in
            try await Task.sleep(for: .seconds(1))
            try await inspect(window)
        }
    }

    private func withWindow<Content: View>(
        _ content: Content, size: CGSize, inspect: (UIWindow) async throws -> Void
    ) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.rootViewController = UIHostingController(rootView: content)
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        try await inspect(window)
    }

    private func scrollViews(_ view: UIView) -> [UIScrollView] {
        (view as? UIScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
    }

    private func capture(_ window: UIWindow, name: String? = nil, afterUpdates: Bool = true) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.preferredRange = .standard
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: afterUpdates))
        }
        if let name {
            let attachment = XCTAttachment(image: image)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        return image
    }

    private func recognize(_ image: UIImage) throws -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
        return request.results?.compactMap { $0.topCandidates(1).first?.string } ?? []
    }

    private func brightness(_ image: UIImage, x: Int, y: Int) throws -> Int {
        let cg = try XCTUnwrap(image.cgImage)
        XCTAssertEqual(cg.bitsPerPixel, 32)
        let data = try XCTUnwrap(cg.dataProvider?.data)
        let bytes = try XCTUnwrap(CFDataGetBytePtr(data))
        let scale = CGFloat(cg.width) / image.size.width
        let offset = Int(CGFloat(y) * scale) * cg.bytesPerRow + Int(CGFloat(x) * scale) * 4
        return (Int(bytes[offset]) + Int(bytes[offset + 1]) + Int(bytes[offset + 2])) / 3
    }

    private func redPixelCount(_ image: UIImage) throws -> Int {
        let cg = try XCTUnwrap(image.cgImage)
        var rgba = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(
            data: &rgba, width: cg.width, height: cg.height, bitsPerComponent: 8,
            bytesPerRow: cg.width * 4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        return stride(from: 0, to: rgba.count, by: 4).reduce(0) { count, offset in
            count + (rgba[offset] > 150 && Int(rgba[offset]) > Int(rgba[offset + 1]) * 2 ? 1 : 0)
        }
    }
}

@MainActor @Observable
private final class PickerMotionFixtureModel {
    var isPresented = false
}

private struct PickerMotionFixture: View {
    let model: PickerMotionFixtureModel
    var reduceMotion = false

    var body: some View {
        VStack(spacing: 20) {
            ForEach([0, 6], id: \.self) { position in
                Color.white.frame(width: 100, height: 100)
                    .modifier(PlozziOSProfilePickerEntrance(
                        isPresented: model.isPresented, position: position, reduceMotion: reduceMotion
                    ))
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.black)
        .ignoresSafeArea()
    }
}
#endif
