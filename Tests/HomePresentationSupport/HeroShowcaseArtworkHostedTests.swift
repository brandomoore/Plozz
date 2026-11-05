#if os(tvOS)
import CoreModels
import CoreNetworking
import CoreUI
import HeroUI
import SwiftUI
import UIKit
import XCTest
@testable import FeatureHome

@MainActor
final class HeroShowcaseArtworkHostedTests: XCTestCase {
    func testFeaturedArtworkReturnsAfterShowcaseRelinquishesOwnership() async throws {
        let url = try XCTUnwrap(URL(string: "https://stage.example.test/\(UUID()).png"))
        let image = UIGraphicsImageRenderer(size: CGSize(width: 320, height: 180)).image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 320, height: 180))
        }
        let bytes = try XCTUnwrap(image.pngData())
        let cache = try XCTUnwrap(ArtworkSession.shared.configuration.urlCache)
        let requests = ArtworkImageVariant.allCases.map { URLRequest(url: $0.requestURL(for: url)) }
        for request in requests {
            let response = try XCTUnwrap(HTTPURLResponse(
                url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "image/png", "Cache-Control": "max-age=3600"]
            ))
            cache.storeCachedResponse(CachedURLResponse(response: response, data: bytes), for: request)
        }
        defer { requests.forEach { cache.removeCachedResponse(for: $0) } }
        let warmed = await ArtworkImageCache.shared.image(for: url, variant: .heroBackdrop)
        XCTAssertNotNil(warmed)
        let featured = MediaItem(id: "featured", title: "Featured", kind: .movie, backdropURL: url)
        let rowItem = MediaItem(id: "row", title: "Row", kind: .movie, backdropURL: url)
        let rows = [FocusHeroRow(id: "first", itemIDs: [rowItem.id], leadItem: rowItem, items: [rowItem])]
        let artwork = HeroArtworkDisplayState()
        let host = UIHostingController(rootView: FocusHeroHomeView(
            rows: rows, settings: .default, spoilerSettings: .default,
            navigationStyle: .rail, isFrontmost: true,
            featuredHero: { suspended in
                AnyView(HostedFeaturedArtwork(item: featured, suspended: suspended))
            }
        ) { _, _ in
            Button("Row") {}.frame(width: 400, height: 300)
        }
        .environment(\.heroArtworkDisplayState, artwork)
        .environment(\.plozzArtworkSettings, .init(preference: .library)))
        try await waitUntil {
            UIApplication.shared.connectedScenes.contains { $0.activationState == .foregroundActive }
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        host.view.layoutIfNeeded()
        func findStage(_ controller: UIViewController) -> HeroShowcaseStage.Controller? {
            if let stage = controller as? HeroShowcaseStage.Controller { return stage }
            return controller.children.lazy.compactMap(findStage).first
        }
        try await waitUntil { findStage(host) != nil }
        let stage = try XCTUnwrap(findStage(host))
        defer { stage.stopAnimations() }
        let system = try XCTUnwrap(UIFocusSystem.focusSystem(for: stage.view))
        let focusDeadline = ContinuousClock.now + .seconds(2)
        while !stage.contains(system.focusedItem, in: stage.hero), ContinuousClock.now < focusDeadline {
            window.layoutIfNeeded()
            system.requestFocusUpdate(to: stage)
            system.updateFocusIfNeeded()
            try await Task.sleep(for: .milliseconds(25))
        }
        for (index, expanded) in [true, false, true, false, true].enumerated() {
            if index > 0 { stage.beginBoundaryMove(expanded ? .up : .down) }
            let expected = expanded ? featured.id : "item-\(rowItem.id)"
            let destination = expanded ? stage.hero : stage.rows
            let deadline = ContinuousClock.now + .seconds(2)
            while (!stage.contains(system.focusedItem, in: destination)
                   || artwork.displayed?.itemID != expected || artwork.sample(for: expected) == nil),
                  ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(25))
            }
            let evidence = """
            expanded=\(expanded) scene=\(window.windowScene != nil)
            heroFocus=\(stage.contains(system.focusedItem, in: stage.hero))
            rowFocus=\(stage.contains(system.focusedItem, in: stage.rows))
            displayed=\(artwork.displayed?.itemID ?? "nil") sample=\(artwork.sample(for: expected) != nil)
            """
            let attachment = XCTAttachment(string: evidence)
            attachment.name = "Artwork ownership transition \(index)"
            attachment.lifetime = .keepAlways
            add(attachment)
            XCTAssertTrue(stage.contains(system.focusedItem, in: destination), evidence)
            XCTAssertEqual(artwork.displayed?.itemID, expected, evidence)
            XCTAssertNotNil(artwork.sample(for: expected), evidence)
        }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        try XCTUnwrap(condition() ? true : nil, "The hosted fixture did not become ready.")
    }
}

private struct HostedFeaturedArtwork: View {
    let item: MediaItem
    let suspended: Bool
    @Namespace private var focus
    @State private var trailer = HeroTrailerController()
    @State private var recede = HomeHeroRecedeModel()

    var body: some View {
        HomeHeroView(
            items: [item], settings: .default, backgroundSettings: .default,
            trailerController: trailer, trailerResolver: { _ in nil },
            isFrontmost: true, spoilerSettings: .default, navigationStyle: .rail,
            focusScope: focus, onSelect: { _ in }, onPlay: { _ in },
            recedeModel: recede, showcaseSuspended: suspended
        )
    }
}
#endif
