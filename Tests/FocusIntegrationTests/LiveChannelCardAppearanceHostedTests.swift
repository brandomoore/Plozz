import CoreModels
import SwiftUI
import UIKit
import XCTest
@testable import CoreUI
@testable import FeaturePlayback

@MainActor
final class LiveChannelCardAppearanceHostedTests: XCTestCase {
    func testOnNowKeepsNativeFocusAndPlayerShapesWithProgrammeArtAndLogoFallbacks() async throws {
        let artworkURL = try XCTUnwrap(URL(string: "https://fixture.invalid/\(UUID())/programme.png"))
        let logoURL = try XCTUnwrap(URL(string: "https://fixture.invalid/\(UUID())/logo.png"))
        let art = UIGraphicsImageRenderer(size: CGSize(width: 320, height: 180)).image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 320, height: 180))
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 160, y: 0, width: 160, height: 180))
        }
        let logo = UIGraphicsImageRenderer(size: CGSize(width: 80, height: 80)).image { context in
            UIColor.systemRed.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 80, height: 80))
            ("TV" as NSString).draw(at: CGPoint(x: 12, y: 19), withAttributes: [
                .font: UIFont.boldSystemFont(ofSize: 38), .foregroundColor: UIColor.white
            ])
        }
        HeroLogoMemo.store(
            HeroLogoAnalysis.analyze(
                PreparedLogo(image: logo, luminance: 0.3, red: 1, green: 0, blue: 0, coverage: 1),
                backgroundSample: nil
            ),
            for: HeroLogoMemo.key(for: [.remote(logoURL)])
        )
        let request = URLRequest(url: artworkURL)
        let response = try XCTUnwrap(HTTPURLResponse(
            url: artworkURL, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "image/png", "Cache-Control": "max-age=3600"]
        ))
        let cache = try XCTUnwrap(ArtworkSession.shared.configuration.urlCache)
        cache.storeCachedResponse(CachedURLResponse(response: response, data: try XCTUnwrap(art.pngData())), for: request)
        defer { cache.removeCachedResponse(for: request) }
        let decoded = await ArtworkImageCache.shared.image(for: artworkURL, variant: .original)
        XCTAssertNotNil(decoded)

        let now = Date()
        let items: [LiveChannelOnNowItem] = [
            .init(channelID: "programme", channelName: "News", logoURL: logoURL, program: .init(
                title: "Evening News", start: now.addingTimeInterval(-900), end: now.addingTimeInterval(900),
                artworkURL: artworkURL
            )),
            .init(channelID: "boxed-logo", channelName: "Sports", logoURL: logoURL, program: .init(
                title: "Live Football", start: now.addingTimeInterval(-1800), end: now.addingTimeInterval(3600)
            )),
            .init(channelID: "missing-art", channelName: "Local Channel", logoURL: nil, program: nil)
        ]
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: AnyView(EmptyView()))
        host.safeAreaRegions = []
        window.rootViewController = host
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }

        for density in UIDensity.allCases {
            host.rootView = AnyView(
                LiveChannelCardAppearanceFixture(items: items)
                    .environment(\.plozzMetrics, PlozzMetrics(density: density))
                    .environment(\.playerCardMetrics, .tv)
                    .environment(\.themePalette, .dark)
                    .environment(\.colorScheme, .dark)
                    .environment(\.channelLogoPreservesSourceCorners, true)
                    .environment(\.plozzReducePanelGlass, true)
                    .transaction { $0.disablesAnimations = true }
                    .id(density)
            )
            window.layoutIfNeeded()
            window.setNeedsFocusUpdate()
            window.updateFocusIfNeeded()
            let deadline = ContinuousClock.now + .seconds(3)
            while UIFocusSystem.focusSystem(for: window)?.focusedItem == nil, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertTrue(try XCTUnwrap(UIFocusSystem.focusSystem(for: window)?.focusedItem).canBecomeFocused)
            try await Task.sleep(for: .milliseconds(300))
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = "live-player-on-now-\(density.rawValue)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }
}

private struct LiveChannelCardAppearanceFixture: View {
    let items: [LiveChannelOnNowItem]
    @FocusState private var focus: LiveChannelControl?

    var body: some View {
        VStack(alignment: .leading, spacing: 36) {
            Spacer()
            Text(verbatim: "On Now").font(.system(size: 38, weight: .semibold)).foregroundStyle(.white)
            LiveChannelOnNowPanel(
                items: items, currentChannelID: "programme", focus: $focus, isCardOpen: true, select: { _ in }
            )
            .frame(height: PlayerCardMetrics.tv.cardHeight)
        }
        .padding(80)
        .background(LinearGradient(colors: [.indigo, .black], startPoint: .topLeading, endPoint: .bottomTrailing))
    }
}
