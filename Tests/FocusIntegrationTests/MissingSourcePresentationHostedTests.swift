import CoreModels
import CoreUI
import FeatureHome
import FeatureHomeCore
import FeatureSettings
import MetadataKit
import Observation
import SwiftUI
import UIKit
import Vision
import XCTest
@testable import AppShell

@MainActor
final class MissingSourcePresentationHostedTests: XCTestCase {
    func testProviderFreeExternalDetailRendersMetadataAndRequestAction() async throws {
        let seed = MediaItem(
            id: "external-\(UUID())", title: "External Movie", kind: .movie,
            allowsTitleBasedMetadataMatching: false,
            availability: .unknown, locallyValidatedPlayableSource: false
        )
        let model = ItemDetailViewModel(
            provider: nil, itemID: seed.id, initialItem: seed, isDiscoveryItem: true,
            externalMetadataResolver: { _, region in
                .init(
                    enrichment: MetadataEnrichment(overview: SourcedValue(value: "External movie overview.", source: .tmdb)),
                    availability: ExternalTitleAvailability(regionCode: region)
                )
            },
            onlineTrailerResolver: { _ in [] }, playableVideoIDResolver: { _ in nil },
            trailerCache: TrailerResolutionCache()
        )
        let trailer = HeroTrailerController()
        defer { model.suspendEnrichment(); trailer.stop() }
        try await withWindow(
            NavigationStack {
                ItemDetailView(
                    viewModel: model,
                    onPlay: { _ in XCTFail("An external title must not play through a media server") },
                    onSelectChild: { _ in },
                    seerConnected: true,
                    onRequest: { _ in .success(.pending) }
                )
            }
                .environment(trailer)
                .environment(HeroBackgroundSettingsModel(store: InMemoryHeroBackgroundSettingsStore()))
        ) { window in
            try await waitUntil { model.state.value?.item.overview == "External movie overview." }
            let text = try await visibleText(window, containing: "External Movie")
            XCTAssertTrue(text.contains("External Movie"), text)
            XCTAssertTrue(text.contains("Request"), text)
            XCTAssertFalse(text.contains("Source Unavailable"), text)
            XCTAssertNil(model.currentSourceForDisplay)
            XCTAssertTrue(model.isDiscoveryItem)
        }
    }

    func testOnlineTrailerCannotEnterThePlayerOrResolveALibraryAccount() async throws {
        let probe = MissingSourcePresentationProbe()
        let trailer = MediaItem.youTubeTrailer(videoID: "fixture1234", title: "External Movie Trailer")
        let suite = "MissingSourceTrailer.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = VersionPreferenceStore(defaults: defaults)
        try await withWindow(
            PlayerPresentation(
                request: PlayRequest(item: trailer, startPosition: 0, versionPreferences: preferences),
                make: { _, _, _ in
                    probe.creationAttempts += 1
                    XCTFail("Online trailers must open externally, never through an embedded player.")
                    throw CancellationError()
                },
                makeFailover: { _, _ in XCTFail("Trailers do not fail over between libraries"); return nil },
                showDiagnostics: false, themePalette: .dark, versionPreferences: preferences,
                prepareVersion: { _, _ in
                    XCTFail("An online trailer must bypass library-account resolution")
                    throw AppError.unauthorized
                },
                versionAuthorizationScope: []
            )
        ) { window in
            try await waitUntil { window.rootViewController?.presentedViewController is UIAlertController }
            XCTAssertEqual(probe.creationAttempts, 0)
        }
    }

    func testMissingSourcePushShowsRecoveryAndKeepsNativeBackNavigation() async throws {
        let probe = MissingSourcePresentationProbe()
        try await withWindow(MissingSourceNavigationFixture(probe: probe)) { window in
            probe.path = ["removed"]
            try await waitUntil { self.navigationController(window.rootViewController)?.viewControllers.count == 2 }
            let text = try await visibleText(window)
            XCTAssertTrue(text.contains("Source Unavailable"), text)
            XCTAssertTrue(text.contains("Settings"), text)
            let navigation = try XCTUnwrap(navigationController(window.rootViewController))
            navigation.popViewController(animated: false)
            try await waitUntil { probe.path.isEmpty && navigation.viewControllers.count == 1 }
        }
    }

    func testVersionPreparationFailsOverBeforeConstructingThePlayer() async throws {
        let probe = MissingSourcePresentationProbe()
        let suite = "MissingSourceFailover.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = VersionPreferenceStore(defaults: defaults)
        let first = MediaItem(id: "first-item", title: "Movie", kind: .movie, sourceAccountID: "first")
        let alternate = MediaItem(id: "second-item", title: "Movie", kind: .movie, sourceAccountID: "second")
        var preparedAccounts: [String?] = []
        try await withWindow(
            PlayerPresentation(
                request: PlayRequest(item: first, startPosition: 42, versionPreferences: preferences),
                make: { request, _, _ in
                    XCTAssertEqual(request.item.id, alternate.id)
                    XCTAssertEqual(request.item.sourceAccountID, "second")
                    XCTAssertEqual(request.startPosition, 42)
                    probe.creationAttempts += 1
                    throw CancellationError()
                },
                makeFailover: { failed, tried in
                    XCTAssertEqual(failed.id, first.id)
                    XCTAssertEqual(tried, ["first"])
                    return alternate
                },
                showDiagnostics: false, themePalette: .dark, versionPreferences: preferences,
                prepareVersion: { _, item in
                    preparedAccounts.append(item.sourceAccountID)
                    if item.sourceAccountID == "first" { throw AppError.unauthorized }
                    return item
                },
                versionAuthorizationScope: ["first", "second"]
            )
        ) { window in
            try await waitUntil { probe.creationAttempts == 1 }
            XCTAssertEqual(preparedAccounts, ["first", "second"])
            XCTAssertNil(window.rootViewController?.presentedViewController)
            XCTAssertEqual(probe.creationAttempts, 1)
        }
    }

    func testMissingProviderDuringPlayerConstructionShowsAnErrorInsteadOfLeavingABlackCover() async throws {
        let probe = MissingSourcePresentationProbe()
        let suite = "MissingSourcePresentation.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = VersionPreferenceStore(defaults: defaults)
        try await withWindow(
            PlayerPresentation(
                request: PlayRequest(
                    item: MediaItem(id: "saved", title: "Saved", kind: .movie, sourceAccountID: "removed"),
                    startPosition: 0, versionPreferences: preferences
                ),
                make: { _, _, _ in
                    probe.creationAttempts += 1
                    _ = try resolveProvider("removed", in: [])
                    XCTFail("Missing provider must not construct a player")
                    throw AppError.invalidResponse
                },
                makeFailover: { _, _ in XCTFail("No player exists to fail over"); return nil },
                showDiagnostics: false,
                themePalette: .dark,
                versionPreferences: preferences,
                prepareVersion: { _, item in item },
                versionAuthorizationScope: []
            )
        ) { window in
            try await waitUntil { probe.creationAttempts == 1 && window.rootViewController?.presentedViewController != nil }
            let text = try await visibleText(window)
            XCTAssertTrue(text.contains("Source Unavailable"), text)
            XCTAssertTrue(text.contains("Settings"), text)
            XCTAssertTrue(text.contains("Close player"), text)
            let alert = try XCTUnwrap(window.rootViewController?.presentedViewController as? UIAlertController)
            XCTAssertEqual(alert.actions.count, 1)
            XCTAssertEqual(alert.actions.first?.title, "Close player")
            XCTAssertEqual(alert.actions.first?.isEnabled, true)
            XCTAssertEqual(probe.creationAttempts, 1)
        }
    }

    private func withWindow<Content: View>(
        _ content: Content, exercise: (UIWindow) async throws -> Void
    ) async throws {
        try await waitUntil {
            UIApplication.shared.connectedScenes.contains { $0.activationState == .foregroundActive }
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        window.overrideUserInterfaceStyle = .dark
        window.rootViewController = UIHostingController(rootView: content
            .environment(\.locale, Locale(identifier: "en_US"))
            .environment(\.themePalette, .dark))
        window.makeKeyAndVisible()
        defer {
            window.rootViewController?.dismiss(animated: false)
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        try await exercise(window)
    }

    private func visibleText(_ window: UIWindow, containing expected: String? = nil) async throws -> String {
        let deadline = ContinuousClock.now + .seconds(5)
        while true {
            try await Task.sleep(for: .milliseconds(400))
            window.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
            }
            let request = VNRecognizeTextRequest()
            request.recognitionLanguages = ["en-US"]
            request.recognitionLevel = .accurate
            try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
            let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
            if (expected.map { text.contains($0) } ?? true) || ContinuousClock.now >= deadline {
                let attachment = XCTAttachment(image: image)
                attachment.name = "missing-source-recovery"
                attachment.lifetime = .keepAlways
                add(attachment)
                return text
            }
        }
    }

    private func navigationController(_ controller: UIViewController?) -> UINavigationController? {
        guard let controller else { return nil }
        if let navigation = controller as? UINavigationController { return navigation }
        return controller.children.lazy.compactMap { self.navigationController($0) }.first
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(predicate(), "Missing-source presentation did not reach its expected native state")
    }
}

@MainActor @Observable
private final class MissingSourcePresentationProbe {
    var path: [String] = []
    var creationAttempts = 0
}

private struct MissingSourceNavigationFixture: View {
    @Bindable var probe: MissingSourcePresentationProbe

    var body: some View {
        NavigationStack(path: $probe.path) {
            Text("Watchlist")
                .navigationDestination(for: String.self) { _ in
                    MediaSourceUnavailableView()
                }
        }
    }
}
