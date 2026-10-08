#if os(iOS)
import CoreModels
import CoreNetworking
import CoreUI
import SeerService
import SwiftUI
import UIKit
import Vision
import XCTest
@testable import FeatureSettings

@MainActor
final class ProfileSeerrSetupPresentationTests: XCTestCase {
    func testConnectedSetupKeepsPageGuttersAndAlignedUserLabels() async throws {
        for size in [CGSize(width: 390, height: 844), CGSize(width: 320, height: 568),
                     CGSize(width: 768, height: 1024), CGSize(width: 844, height: 390)] {
            try await render(size: size) { window, scroll in
                let image = try self.capture(window)
                self.attach(image, name: "Seerr connected \(Int(size.width))x\(Int(size.height))")
                let text = try self.recognize(image, size: size)
                let title = try XCTUnwrap(text.first { $0.text.contains("Requests as") })
                XCTAssertTrue(text.contains { $0.text.contains("Emby only") })
                XCTAssertGreaterThanOrEqual(title.frame.minX, 20)
                XCTAssertLessThanOrEqual(title.frame.maxX, size.width - 23)
                XCTAssertFalse(title.text.contains("—"))
                let explanation = try XCTUnwrap(text.first { $0.text.contains("Choose whose") })
                XCTAssertEqual(title.frame.minX, explanation.frame.minX, accuracy: 3)
                XCTAssertLessThanOrEqual(scroll.contentSize.width, scroll.bounds.width + 1)
                let admin = try XCTUnwrap(text.first { $0.text.contains("unrestricted") })
                try self.assertPanelGutters(image, rowY: admin.frame.midY)
                if size.height > 700 {
                    let alex = try XCTUnwrap(text.first { $0.text == "Alex" })
                    let sam = try XCTUnwrap(text.first { $0.text == "Sam" })
                    XCTAssertEqual(admin.frame.minX, alex.frame.minX, accuracy: 4)
                    XCTAssertEqual(alex.frame.minX, sam.frame.minX, accuracy: 4)
                    let footer = try XCTUnwrap(text.first { $0.text.hasPrefix("Admin is unrestricted.") })
                    XCTAssertGreaterThanOrEqual(footer.frame.minX, title.frame.minX + 12)
                }
                try await self.scrollToBottom(scroll, window: window)
                let bottom = try self.capture(window)
                self.attach(bottom, name: "Seerr actions \(Int(size.width))x\(Int(size.height))")
                let bottomText = try self.recognize(bottom, size: size)
                XCTAssertTrue(bottomText.contains { $0.text == "Not Now" })
                XCTAssertTrue(bottomText.contains { $0.text == "Continue" })
                for line in bottomText {
                    XCTAssertGreaterThanOrEqual(line.frame.minX, 20, line.text)
                    XCTAssertLessThanOrEqual(line.frame.maxX, size.width - 23, line.text)
                }
            }
        }
    }

    func testLongNamesAndAccessibilityTextStayScrollableWithoutHorizontalOverflow() async throws {
        for direction in [LayoutDirection.leftToRight, .rightToLeft] {
            try await render(
                size: .init(width: 390, height: 844), typeSize: .accessibility3,
                direction: direction, longNames: true
            ) { window, scroll in
                XCTAssertGreaterThan(scroll.contentSize.height, scroll.bounds.height)
                XCTAssertLessThanOrEqual(scroll.contentSize.width, scroll.bounds.width + 1)
                self.attach(try self.capture(window), name: "Seerr large text top \(direction)")
                try await self.scrollToBottom(scroll, window: window)
                let image = try self.capture(window)
                self.attach(image, name: "Seerr large text actions \(direction)")
                let text = try self.recognize(image, size: window.bounds.size)
                XCTAssertTrue(text.contains { $0.text == "Continue" })
                XCTAssertTrue(text.contains { $0.text == "Not Now" })
                XCTAssertFalse(text.contains { $0.text.contains("…") })
                for line in text {
                    XCTAssertGreaterThanOrEqual(line.frame.minX, 23, line.text)
                    XCTAssertLessThanOrEqual(line.frame.maxX, 367, line.text)
                }
            }
        }
    }

    func testConnectionEmptyAndFailedUserStatesRetainTheSameGutters() async throws {
        for state in [SeerrSetupHTTP.State.unconfigured, .empty, .failed] {
            try await render(size: .init(width: 390, height: 844), state: state) { window, scroll in
                let image = try self.capture(window)
                self.attach(image, name: "Seerr \(state)")
                let text = try self.recognize(image, size: window.bounds.size)
                XCTAssertTrue(text.contains { $0.text.contains("Requests as") })
                let expected: String
                switch state {
                case .unconfigured: expected = "Connect"
                case .empty: expected = "No Seerr users found."
                case .failed: expected = "Retry loading users"
                case .connected: expected = "Alex"
                }
                XCTAssertTrue(text.contains { $0.text.localizedCaseInsensitiveContains(expected) })
                XCTAssertLessThanOrEqual(scroll.contentSize.width, scroll.bounds.width + 1)
                for line in text {
                    XCTAssertGreaterThanOrEqual(line.frame.minX, 23, line.text)
                    XCTAssertLessThanOrEqual(line.frame.maxX, 367, line.text)
                }
            }
        }
    }

    private func render(
        size: CGSize, typeSize: DynamicTypeSize = .large,
        direction: LayoutDirection = .leftToRight, longNames: Bool = false,
        state: SeerrSetupHTTP.State = .connected,
        inspect: (UIWindow, UIScrollView) async throws -> Void
    ) async throws {
        let http = SeerrSetupHTTP(state: state, longNames: longNames)
        let store = InMemorySeerConnectionStore(connection: state == .unconfigured ? nil : .init(
            baseURL: URL(string: "https://fixture.invalid")!, apiKey: "fixture"
        ))
        let service = SeerService(connectionStore: store, http: http)
        let view = ProfileSeerrSetupView(
            seer: service,
            profile: Profile(id: "fixture", name: longNames ? "A household profile with a very long name" : "Emby only"),
            onSelect: { _ in }, onContinue: {}
        )
        .environment(\.themePalette, ThemePalette.dark)
        .environment(\.dynamicTypeSize, typeSize)
        .environment(\.layoutDirection, direction)
        .environment(\.locale, Locale(identifier: "en"))
        let deadline = ContinuousClock.now + .seconds(5)
        while UIApplication.shared.connectedScenes.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        let host = UIHostingController(rootView: view)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        let ready = ContinuousClock.now + .seconds(5)
        while !(await http.finished), state != .unconfigured, ContinuousClock.now < ready {
            try await Task.sleep(for: .milliseconds(20))
        }
        if state != .unconfigured { let finished = await http.finished; XCTAssertTrue(finished) }
        try await Task.sleep(for: .milliseconds(150))
        window.layoutIfNeeded()
        let scroll = try XCTUnwrap(scrollViews(in: host.view).first)
        try await inspect(window, scroll)
    }

    private func scrollViews(in view: UIView) -> [UIScrollView] {
        (view as? UIScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
    }

    private func scrollToBottom(_ scroll: UIScrollView, window: UIWindow) async throws {
        scroll.setContentOffset(CGPoint(x: 0, y: max(
            -scroll.adjustedContentInset.top,
            scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom
        )), animated: false)
        try await Task.sleep(for: .milliseconds(100))
        window.layoutIfNeeded()
    }

    private func capture(_ window: UIWindow) throws -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.preferredRange = .standard
        return UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
    }

    private func assertPanelGutters(_ image: UIImage, rowY: CGFloat) throws {
        let cgImage = try XCTUnwrap(image.cgImage)
        XCTAssertEqual(cgImage.bitsPerPixel, 32)
        guard cgImage.bitsPerPixel == 32 else { return }
        let data = try XCTUnwrap(cgImage.dataProvider?.data)
        let bytes = try XCTUnwrap(CFDataGetBytePtr(data))
        let scale = CGFloat(cgImage.width) / image.size.width
        let y = Int(rowY * scale)
        let expected = max(24, (image.size.width - 720) / 2)
        // Locate the real panel border, before any avatar/text. Native scroll
        // bounds stay edge-to-edge: SwiftUI applies these gutters to its content.
        for trailing in [false, true] {
            var strongest = (delta: 0, inset: CGFloat.zero)
            for distance in 1..<Int((expected + 8) * scale) {
                let x = trailing ? cgImage.width - distance : distance
                let offset = y * cgImage.bytesPerRow + x * 4
                let delta = (0..<3).reduce(0) {
                    $0 + abs(Int(bytes[offset + $1]) - Int(bytes[offset - 4 + $1]))
                }
                if delta > strongest.delta { strongest = (delta, CGFloat(distance) / scale) }
            }
            XCTAssertGreaterThan(strongest.delta, 20, "Expected a visible panel boundary")
            XCTAssertEqual(strongest.inset, expected, accuracy: 1)
        }
    }

    private func attach(_ image: UIImage, name: String) {
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func recognize(_ image: UIImage, size: CGSize) throws -> [(text: String, frame: CGRect)] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
        return (request.results ?? []).compactMap {
            guard let text = $0.topCandidates(1).first?.string else { return nil }
            let box = $0.boundingBox
            return (text, CGRect(x: box.minX * size.width, y: (1 - box.maxY) * size.height,
                                 width: box.width * size.width, height: box.height * size.height))
        }
    }
}

private actor SeerrSetupHTTP: HTTPClient {
    enum State { case connected, unconfigured, empty, failed }
    let state: State
    let longNames: Bool
    private(set) var finished = false

    init(state: State, longNames: Bool) {
        self.state = state
        self.longNames = longNames
    }

    func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
        let json: String
        if endpoint.path.hasSuffix("/status") {
            json = #"{"version":"1.0"}"#
        } else if endpoint.path.hasSuffix("/user") {
            finished = true
            if state == .failed { throw AppError.serverUnreachable }
            if state == .empty {
                json = #"{"results":[]}"#
            } else {
                let name = longNames ? "Alex with an exceptionally long household display name" : "Alex"
                json = """
                {"results":[{"id":1,"displayName":"\(name)","email":"alex@example.invalid"},
                            {"id":2,"displayName":"Sam","email":"sam@example.invalid"}]}
                """
            }
        } else {
            throw AppError.invalidResponse
        }
        return (Data(json.utf8), HTTPURLResponse(url: baseURL, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
#endif
