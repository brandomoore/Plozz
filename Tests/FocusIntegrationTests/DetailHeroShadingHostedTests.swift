#if os(tvOS)
@testable import CoreUI
import Observation
import SwiftUI
import UIKit
import XCTest

@MainActor
final class DetailHeroShadingHostedTests: XCTestCase {
    func testCachedDetailLayerPreservesShadingDissolveAndVideoClipping() async throws {
        let state = DetailShadingFixtureState()
        let window = try await makeWindow(state: state)
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        for (name, tone, background, pinned) in [
            ("dark", Color.black, Color.black, false),
            ("dark", Color.black, Color.black, true),
            ("light", Color.white, Color.white, false),
            ("light", Color.white, Color.white, true),
            ("custom", Color.purple, Color.black, false),
            ("custom", Color.purple, Color.black, true)
        ] {
            state.tone = tone
            state.background = background
            state.pinned = pinned
            for rightToLeft in [false, true] {
                state.rightToLeft = rightToLeft
                for size in [CGSize(width: 640, height: 360), CGSize(width: 1280, height: 576),
                             CGSize(width: 1920, height: 1080)] {
                    state.size = size
                    for offset in [CGFloat(0), -90] {
                        state.offset = offset
                        state.cached = false
                        try await Task.sleep(for: .milliseconds(100))
                        let original = try pixels(window)
                        state.cached = true
                        try await Task.sleep(for: .milliseconds(100))
                        let cached = try pixels(window)
                        var maximum = 0
                        var compared = 0
                        for yFraction in [0.01, 0.2, 0.33, 0.34, 0.45, 0.538, 0.58, 0.62, 0.72, 0.85, 0.95, 0.99] {
                            let y = Int(size.height * yFraction + offset)
                            guard y >= 0, y < 1080 else { continue }
                            for xFraction in [0.01, 0.1, 0.2, 0.3, 0.41, 0.5, 0.7, 0.9, 0.99] {
                                let index = y * 1920 * 4 + Int(size.width * xFraction) * 4
                                for channel in 0..<4 {
                                    maximum = max(maximum, abs(Int(original[index + channel]) - Int(cached[index + channel])))
                                }
                                compared += 1
                            }
                        }
                        let edge = Int(size.height + offset)
                        if edge >= 0, edge + 1 < 1080 {
                            let index = (edge + 1) * 1920 * 4 + Int(size.width / 2) * 4
                            let expected = name == "light" ? 255 : 0
                            XCTAssertEqual(Int(cached[index]), expected, "Video overdraw must remain clipped.")
                        }
                        XCTAssertGreaterThan(compared, 30)
                        let attachment = XCTAttachment(string:
                            "detail max=\(maximum), theme=\(name), pinned=\(pinned), rtl=\(rightToLeft), size=\(size), offset=\(offset)")
                        attachment.name = "Detail shading pixel comparison"
                        attachment.lifetime = .keepAlways
                        add(attachment)
                        XCTAssertLessThanOrEqual(maximum, 2)
                    }
                }
            }
        }
    }

    func testDetailShadingIsIndependentOfNavigationStyle() async throws {
        let state = DetailShadingFixtureState()
        state.cached = true
        state.size = CGSize(width: 1280, height: 720)
        let window = try await makeWindow(state: state)
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        for tone in [Color.black, Color.white] {
            state.tone = tone
            state.background = tone
            state.pinned = false
            try await Task.sleep(for: .milliseconds(150))
            let native = try pixels(window)
            state.pinned = true
            try await Task.sleep(for: .milliseconds(150))
            XCTAssertEqual(try pixels(window), native,
                           "Detail pages have no sidebar and must retain the same softer upper corner.")
        }
    }

    func testDetailScrimFadesBeforeLogoAndDisabledTransitionsShowCompletedShading() async throws {
        for tone in [Color.black, Color.white] {
            var timing = DetailEntranceTiming()
            timing.artworkPause = 0.4
            timing.stagger = 0.01
            timing.reveal = 0.7
            let session = TVDetailEntranceSession(timing: timing)
            let state = DetailShadingFixtureState()
            state.cached = true
            state.size = CGSize(width: 1280, height: 720)
            state.tone = tone
            state.background = tone
            state.session = session
            let window = try await makeWindow(state: state)
            defer {
                session.finishImmediately()
                window.isHidden = true
                window.rootViewController = nil
            }
            session.attach(to: window, enabled: true, waitsForBackdrop: true)
            let surface = try XCTUnwrap(window.rootViewController?.view)
            try await Task.sleep(for: .milliseconds(150))
            XCTAssertFalse(session.isBackdropShadingVisible)
            let unshaded = try pixels(surface)
            session.resolvedDestinationVideo()
            XCTAssertTrue(session.isBackdropShadingVisible)
            XCTAssertEqual(session.stage, .artwork)
            try await Task.sleep(for: .milliseconds(180))
            XCTAssertEqual(session.stage, .artwork, "The scrim begins before the logo, not after it.")
            let intermediate = try pixels(surface)
            try await Task.sleep(for: .seconds(1))
            XCTAssertEqual(session.stage, .complete)
            let completed = try pixels(surface)
            let index = (324 * 1920 + 64) * 4
            let partialChange = try XCTUnwrap((0..<3).map {
                abs(Int(unshaded[index + $0]) - Int(intermediate[index + $0]))
            }.max())
            let fullChange = try XCTUnwrap((0..<3).map {
                abs(Int(unshaded[index + $0]) - Int(completed[index + $0]))
            }.max())
            XCTAssertGreaterThan(partialChange, 2, "Shading must visibly interpolate rather than pop.")
            XCTAssertLessThan(partialChange, fullChange - 2, "The intermediate frame must not be fully shaded.")
            state.session = nil
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(try pixels(surface), completed, "The reveal must end at the normal cached shading.")
            let disabled = TVDetailEntranceSession()
            disabled.attach(to: window, enabled: false)
            state.session = disabled
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(try pixels(surface), completed, "Disabled transitions must not wait for the entrance.")
        }
    }

    private func makeWindow(state: DetailShadingFixtureState) async throws -> UIWindow {
        let deadline = ContinuousClock.now + .seconds(5)
        while !UIApplication.shared.connectedScenes.contains(where: { $0.activationState == .foregroundActive }),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        window.rootViewController = UIHostingController(rootView: DetailShadingFixture(state: state))
        window.makeKeyAndVisible()
        return window
    }

    private func pixels(_ view: UIView) throws -> [UInt8] {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        let image = UIGraphicsImageRenderer(size: view.bounds.size, format: format).image { _ in
            XCTAssertTrue(view.drawHierarchy(in: view.bounds, afterScreenUpdates: true))
        }
        let cg = try XCTUnwrap(image.cgImage)
        XCTAssertEqual(cg.bitsPerPixel, 32)
        XCTAssertEqual(cg.bytesPerRow, 1920 * 4)
        return Array(try XCTUnwrap(cg.dataProvider?.data) as Data)
    }
}

@MainActor @Observable
private final class DetailShadingFixtureState {
    var cached = false
    var tone = Color.black
    var background = Color.black
    var rightToLeft = false
    var pinned = false
    var session: TVDetailEntranceSession?
    var size = CGSize(width: 640, height: 360)
    var offset: CGFloat = 0
}

private struct DetailShadingFixture: View {
    let state: DetailShadingFixtureState

    var body: some View {
        HeroBackdropLayer(
            references: [], height: state.size.height, scrimTone: state.tone,
            verticalOffset: state.offset, dissolveStart: 0.33, ignoresOverscan: false,
            stillImageOpacity: 0, prefersCachedScrim: state.cached
        ) {
            DetailVideoFixture()
                .frame(width: state.size.width, height: state.size.height)
        }
        .frame(width: state.size.width, height: state.size.height)
        .environment(\.layoutDirection, state.rightToLeft ? .rightToLeft : .leftToRight)
        .environment(\.plozzPinnedSidebarActive, state.pinned)
        .environment(\.detailEntranceSession, state.session)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(state.background)
        .ignoresSafeArea()
    }
}

private struct DetailVideoFixture: UIViewRepresentable {
    func makeUIView(context: Context) -> PictureView { PictureView() }
    func updateUIView(_ view: PictureView, context: Context) {}

    final class PictureView: UIView {
        private let picture = CAGradientLayer()

        override init(frame: CGRect) {
            super.init(frame: frame)
            picture.colors = [UIColor.red.cgColor, UIColor.green.cgColor, UIColor.blue.cgColor]
            picture.startPoint = CGPoint(x: 0, y: 0)
            picture.endPoint = CGPoint(x: 1, y: 1)
            layer.addSublayer(picture)
        }

        required init?(coder: NSCoder) { nil }

        override func layoutSubviews() {
            super.layoutSubviews()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            picture.frame = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height + 1)
            CATransaction.commit()
        }
    }
}
#endif
