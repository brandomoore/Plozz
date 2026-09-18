#if os(tvOS)
@testable import CoreUI
import SwiftUI
import UIKit
import XCTest

@MainActor
final class FamilyGuidanceReaderHostedTests: XCTestCase {
    func testReaderKeepsBothTopCornersVisibleWhileFocusedAndScrolled() async throws {
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
        let controller = ReaderFocusController()
        controller.view.backgroundColor = .black
        window.rootViewController = controller
        let other = UIButton(type: .system)
        other.setTitle("Other focus target", for: .normal)
        other.frame = CGRect(x: 200, y: 100, width: 300, height: 60)
        controller.view.addSubview(other)
        let text = (1...12).map {
            "How can families discuss this fictional story? Paragraph \($0) begins here, with enough text to fill the reader's width and test both edges. What helps these characters understand each other?"
        }.joined(separator: "\n\n")
        let host = UIHostingController(rootView:
            TVFamilyGuidanceReader(text: text, onFocus: { _ in })
                .frame(width: 936, height: 465)
                .padding(28)
                .background(Color.gray.opacity(0.15), in: RoundedRectangle(cornerRadius: 20))
                .environment(\.themePalette, .dark)
        )
        controller.addChild(host)
        controller.view.addSubview(host.view)
        host.didMove(toParent: controller)
        host.view.backgroundColor = .clear
        host.view.frame = CGRect(x: 400, y: 280, width: 992, height: 521)
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        let reader = try XCTUnwrap(findReader(in: host.view))
        let system = try XCTUnwrap(UIFocusSystem.focusSystem(for: window))
        // Opaque landmarks expose viewport cutouts independently of glyph antialiasing.
        let markers = (0..<3).map { index in
            let marker = UIView()
            marker.backgroundColor = index == 2 ? .blue : .red
            reader.addSubview(marker)
            return marker
        }
        for focused in [false, true] {
            controller.target = focused ? reader : other
            system.requestFocusUpdate(to: controller)
            system.updateFocusIfNeeded()
            try await Task.sleep(for: .milliseconds(300))
            let readerOwnsFocus = system.focusedItem.map { $0 === reader || reader.contains($0) } ?? false
            XCTAssertEqual(readerOwnsFocus, focused)
            for offset in [CGFloat(0), 110, 400] {
                reader.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
                reader.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(100))
                XCTAssertEqual(reader.layer.cornerRadius, 0, "Only the outer card should round its corners.")
                XCTAssertTrue(reader.clipsToBounds, "Scrolled text must still stay inside its viewport.")
                XCTAssertEqual(reader.textContainerInset, UIEdgeInsets(top: 0, left: 0, bottom: 8, right: 8))
                let y = reader.contentOffset.y
                markers[0].frame = CGRect(x: 2, y: y + 2, width: 6, height: 6)
                markers[1].frame = CGRect(x: reader.bounds.width - 8, y: y + 2, width: 6, height: 6)
                markers[2].frame = CGRect(x: 2, y: y + reader.bounds.height + 2, width: 6, height: 6)
                let format = UIGraphicsImageRendererFormat()
                format.scale = 1
                format.preferredRange = .standard
                let image = UIGraphicsImageRenderer(size: window.bounds.size, format: format).image { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                }
                let frame = reader.convert(reader.bounds, to: window)
                for x in [frame.minX + 4, frame.maxX - 4] {
                    let color = try pixel(image, x: Int(x), y: Int(frame.minY + 4))
                    XCTAssertGreaterThan(color[0], 220, "Both top corners must render without a rounded cutout.")
                    XCTAssertLessThan(color[1], 30)
                }
                let overflow = try pixel(image, x: Int(frame.minX + 4), y: Int(frame.maxY + 4))
                XCTAssertLessThan(overflow[2], 100, "Removing the corner cutout must not allow content to overflow.")
                let screenshot = XCTAttachment(image: image)
                screenshot.name = "reader-viewport-focus-\(focused)-offset-\(Int(offset))"
                screenshot.lifetime = .keepAlways
                add(screenshot)
            }
        }
    }

    private func findReader(in view: UIView) -> TVFamilyGuidanceReader.Reader? {
        if let reader = view as? TVFamilyGuidanceReader.Reader { return reader }
        return view.subviews.lazy.compactMap { self.findReader(in: $0) }.first
    }

    private func pixel(_ image: UIImage, x: Int, y: Int) throws -> [UInt8] {
        let image = try XCTUnwrap(image.cgImage?.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)))
        var pixel = [UInt8](repeating: 0, count: 4)
        try pixel.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(
                data: bytes.baseAddress, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ))
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return pixel
    }
}

@MainActor
private final class ReaderFocusController: UIViewController {
    weak var target: UIView?

    override var preferredFocusEnvironments: [any UIFocusEnvironment] {
        target.map { [$0] } ?? super.preferredFocusEnvironments
    }
}
#endif
