import CoreModels
@testable import FeatureHome
import UIKit
import XCTest

@MainActor
final class HeroPlaybackLocalizationHostedTests: XCTestCase {
    func testGermanPlaybackLabelsAcrossMoviesAndEpisodeStates() async throws {
        typealias Input = HeroForegroundModelBuilder.PillInput
        let cases: [(Input, String)] = [
            (.init(kind: .play), "Wiedergeben"),
            (.init(kind: .play, isResume: true), "Fortsetzen"),
            (.init(kind: .play, isStarting: true), "Ansehen starten"),
            (.init(kind: .play, seasonEpisodeText: "S2 E3"), "Wiedergeben S2 E3"),
            (.init(kind: .play, isResume: true, seasonEpisodeText: "S2 E3"), "Fortsetzen S2 E3"),
            (.init(kind: .play, isStarting: true, seasonEpisodeText: "S1 E1"), "Ansehen starten · S1 E1"),
            (.init(kind: .play, resumeProgress: 0.4, isResume: true,
                   resumeRemainingText: "20m", seasonEpisodeText: "S2 E3"), "S2 E3 • 20m")
        ]
        let deadline = ContinuousClock.now + .seconds(5)
        while !UIApplication.shared.connectedScenes.contains(where: { $0.activationState == .foregroundActive }),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let controller = UIViewController()
        controller.view.backgroundColor = .black
        let window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = .dark
        window.frame = CGRect(x: 0, y: 0, width: 900, height: 900)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        var y: CGFloat = 24
        for (input, expected) in cases {
            let view = HeroForegroundPillView(frame: .zero)
            controller.view.addSubview(view)
            view.configure(HeroForegroundModelBuilder.pill(for: input), selected: false, locale: Locale(identifier: "de"))
            view.frame = CGRect(origin: CGPoint(x: 24, y: y), size: view.preferredSize())
            view.layoutIfNeeded()
            let label = try XCTUnwrap(view.subviews.compactMap { $0 as? UILabel }.first)
            XCTAssertEqual(label.text, expected)
            XCTAssertGreaterThanOrEqual(label.bounds.width, ceil(label.intrinsicContentSize.width))
            y += view.bounds.height + 16
        }
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "german-hero-playback-labels"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testExistingPlaybackPillRespondsToLocaleChangesWithoutRebuildingTheModel() throws {
        let model = HeroForegroundModelBuilder.pill(for: .init(kind: .play, seasonEpisodeText: "S2 E3"))
        let view = HeroForegroundPillView(frame: .zero)
        for (language, expected) in [("de", "Wiedergeben S2 E3"), ("en", "Play S2 E3"), ("de", "Wiedergeben S2 E3")] {
            view.configure(model, selected: true, locale: Locale(identifier: language))
            XCTAssertEqual(try XCTUnwrap(view.subviews.compactMap { $0 as? UILabel }.first).text, expected)
        }
    }
}
