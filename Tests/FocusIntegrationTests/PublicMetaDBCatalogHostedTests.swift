import CoreModels
import CoreImage
import CoreNetworking
import CoreUI
@testable import FeatureSettings
@testable import FeaturePlayback
import PublicMetaDBService
import SwiftUI
import UIKit
import Vision
import XCTest

@MainActor
final class PublicMetaDBCatalogHostedTests: XCTestCase {
    #if os(tvOS)
    func testAPIKeyFieldAndScannableBrowserCodeAreVisibleTogether() async throws {
        try await withService(connected: false, http: PairingUIHTTP()) { service in
            let pairing = Task { await service.connectUsingBrowser() }
            defer { pairing.cancel() }
            try await waitFor { service.browserPairing.challenge != nil }
            let challenge = try XCTUnwrap(service.browserPairing.challenge)
            try await withWindow(keyEntryFixture(service)) { window in
                let text = try await renderedKeyEntry(
                    window, expectedURL: challenge.url.absoluteString, expectedCode: challenge.displayCode
                )
                XCTAssertTrue(text.contains("API key"), text)
                XCTAssertTrue(text.contains("Connect"), text)
            }
            pairing.cancel()
            await pairing.value
            XCTAssertFalse(service.browserPairing.isActive)
        }
    }
    #endif

    func testUnavailablePairingShowsItsActualErrorAndKeepsManualEntryVisible() async throws {
        try await withService(connected: false, http: PairingUIHTTP(unavailable: true)) { service in
            await service.connectUsingBrowser()
            XCTAssertEqual(service.phase, .pairingFailed(.unavailable))
            try await withWindow(keyEntryFixture(service)) { window in
                let text = try await renderedKeyEntry(window, expectedURL: nil)
                XCTAssertTrue(text.contains("QR code unavailable"), text)
                XCTAssertTrue(text.contains("API key"), text)
                XCTAssertFalse(text.contains("Something went wrong"), text)
            }
        }
    }

    func testManualTimestampBrowserShowsReleaseWarningWithoutSeeking() async throws {
        let source = HostedTimestampSource()
        var seeks: [Double] = []
        let model = PlayerCommunityTimestampsModel(
            item: .init(id: "movie", title: "Movie", kind: .movie), source: source,
            duration: { 120 }, isCurrent: { true }, requestSeek: { seeks.append($0) }
        )
        try await withWindow(PlayerCommunityTimestampsView(model: model)) { window in
            try await waitFor { model.loaded }
            var text = ""
            for _ in 0..<30 {
                try await Task.sleep(for: .milliseconds(100))
                let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                }
                let request = VNRecognizeTextRequest()
                request.recognitionLanguages = ["en-US"]
                try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
                text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
                if text.contains("Physical release") && text.contains("different release") { break }
            }
            XCTAssertTrue(text.contains("Physical release"), text)
            XCTAssertTrue(text.contains("different release"), text)
            XCTAssertTrue(seeks.isEmpty)
            XCTAssertEqual(source.includesHighlights, [false])
        }
        try await waitFor { !model.loaded }
        XCTAssertTrue(model.entries.isEmpty)
    }

    func testOpeningCatalogTitleDismissesItsRealIntegrationSheetAndDeliversOnce() async throws {
        try await withService { service in
            let item = MediaItem(id: "server-movie", title: "Curated movie", kind: .movie, providerIDs: ["Tmdb": "42"])
            service.resolveCatalogItem = { _ in item }
            var routes: [String] = []
            let content = CatalogNavigationFixture(service: service) { routes.append($0.id) }
            try await withWindow(content) { window in
                let root = try XCTUnwrap(window.rootViewController)
                try service.presentContent(for: item)
                try await waitFor { root.presentedViewController != nil }
                try await Task.sleep(for: .milliseconds(400))
                try await service.openCatalogItem(
                    for: .init(tmdbID: 42, mediaType: .movie),
                    expectedConnectionID: XCTUnwrap(service.connectionID)
                )
                try await waitFor { root.presentedViewController == nil && routes == [item.id] }
                XCTAssertNil(service.presentedItem)
                XCTAssertNil(service.consumeCatalogNavigation())
                XCTAssertEqual(routes, [item.id])
            }
        }
    }

    func testCatalogLabelDisplaysResolvedShowAndExactEpisodeCoordinates() async throws {
        try await withService { service in
            service.resolveCatalogItem = { _ in
                MediaItem(id: "server-show", title: "Curated show", kind: .series, providerIDs: ["Tmdb": "42"])
            }
            let content = PublicMetaDBContentLabel(
                content: try .init(tmdbID: 42, mediaType: .tv, season: 3, episode: 7), allowsFocus: false
            )
            .environment(\.publicMetaDBCatalogService, service)
            .font(.title)
            .padding(40)
            .foregroundStyle(.white)
            .background(.black)
            try await withWindow(content) { window in
                var text = ""
                for _ in 0..<30 {
                    try await Task.sleep(for: .milliseconds(100))
                    let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                        window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                    }
                    let request = VNRecognizeTextRequest()
                    request.recognitionLanguages = ["en-US"]
                    try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
                    text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
                    if text.contains("Curated show") && text.contains("Season 3, episode 7") { break }
                }
                XCTAssertTrue(text.contains("Curated show"), text)
                XCTAssertTrue(text.contains("Season 3, episode 7"), text)
            }
        }
    }

    private func keyEntryFixture(_ service: PublicMetaDBService) -> some View {
        PublicMetaDBKeyEntryView(
            service: service, key: .constant(""),
            onConnect: {}, onRetry: {}, onCancel: {}
        )
        .padding(40)
        .frame(maxWidth: 1_000)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.colorScheme, .dark)
        .environment(\.themePalette, .dark)
        .background(ThemePalette.dark.settingsBackground)
    }

    private func renderedKeyEntry(
        _ window: UIWindow, expectedURL: String?, expectedCode: String? = nil
    ) async throws -> String {
        window.overrideUserInterfaceStyle = .dark
        let detector = try XCTUnwrap(CIDetector(
            ofType: CIDetectorTypeQRCode,
            context: CIContext(options: [.useSoftwareRenderer: true]),
            options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]
        ))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let deadline = ContinuousClock.now + .seconds(5)
        while true {
            window.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let bitmap = try XCTUnwrap(image.cgImage)
            let request = VNRecognizeTextRequest()
            request.recognitionLanguages = ["en-US"]
            request.customWords = ["PublicMetaDB", "API"]
            try VNImageRequestHandler(cgImage: bitmap).perform([request])
            let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            let text = lines.joined(separator: " ")
            let hasSingleLineCode = expectedCode.map { expected in
                lines.contains {
                    $0.replacingOccurrences(of: " ", with: "") == expected.replacingOccurrences(of: " ", with: "")
                }
            } ?? true
            let urls = detector.features(in: CIImage(cgImage: bitmap)).compactMap {
                ($0 as? CIQRCodeFeature)?.messageString
            }
            let ready = text.contains("API key")
                && (expectedURL.map { urls.contains($0) } ?? text.contains("QR code unavailable"))
                && hasSingleLineCode
            if ready || ContinuousClock.now >= deadline {
                let attachment = XCTAttachment(image: image)
                attachment.name = expectedURL == nil ? "pairing-unavailable-manual-entry" : "pairing-qr-and-manual-entry"
                attachment.lifetime = .keepAlways
                add(attachment)
                if let expectedURL { XCTAssertEqual(urls, [expectedURL]) }
                XCTAssertTrue(hasSingleLineCode, "Keep the whole pairing code readable on one line.")
                return text
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private func withService(
        connected: Bool = true, http: any HTTPClient = CatalogHTTP(),
        _ body: (PublicMetaDBService) async throws -> Void
    ) async throws {
        let suite = "PublicMetaDBCatalogHostedTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = PublicMetaDBService(credentials: CatalogCredentials(), http: http, defaults: defaults)
        if connected {
            let key = "pm-" + (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").prefix(60)
            await service.connect(key: key)
            XCTAssertEqual(service.phase, .connected)
        }
        try await body(service)
    }

    private func withWindow(
        _ content: some View, body: (UIWindow) async throws -> Void
    ) async throws {
        try await waitFor {
            UIApplication.shared.connectedScenes.contains { $0.activationState == .foregroundActive }
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        var appeared = false
        window.rootViewController = UIHostingController(rootView: content.onAppear { appeared = true })
        window.makeKeyAndVisible()
        defer {
            window.rootViewController?.dismiss(animated: false)
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        try await waitFor { appeared }
        try await body(window)
    }

    private func waitFor(
        file: StaticString = #filePath, line: UInt = #line, _ predicate: () -> Bool
    ) async throws {
        for _ in 0..<100 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("The expected catalog presentation did not occur", file: file, line: line)
        throw AppError.notFound
    }
}

private struct CatalogNavigationFixture: View {
    let service: PublicMetaDBService
    let onRoute: (MediaItem) -> Void

    var body: some View {
        Text("Library")
            .publicMetaDBContentPresentation(service: service)
            .onChange(of: service.catalogNavigation?.id) { _, _ in
                if let item = service.consumeCatalogNavigation() { onRoute(item) }
            }
    }
}

private struct CatalogCredentials: PublicMetaDBCredentialStoring {
    func load(namespace: String?) -> PublicMetaDBCredentials? { nil }
    func save(_ credentials: PublicMetaDBCredentials, namespace: String?) throws {}
    func clear(namespace: String?) throws {}
}

private struct CatalogHTTP: HTTPClient {
    func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
        XCTAssertEqual(endpoint.path, "/api/external/lists")
        XCTAssertEqual(endpoint.method, .get)
        return (
            Data(#"{"items":[],"total":0,"page":1,"perPage":1,"totalPages":0}"#.utf8),
            try XCTUnwrap(HTTPURLResponse(url: baseURL, statusCode: 200, httpVersion: nil, headerFields: nil))
        )
    }

}

private struct PairingUIHTTP: HTTPClient {
    var unavailable = false

    func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
        if unavailable { throw AppError.invalidResponse }
        let status: Int
        let data: Data
        switch (endpoint.method, endpoint.path) {
        case (.post, "/api/publicmetadb/pairing"):
            status = 201
            data = try JSONSerialization.data(withJSONObject: [
                "code": "ABCDEFGH",
                "expiresAt": Date().addingTimeInterval(600).timeIntervalSince1970 * 1000
            ])
        case (.post, "/api/publicmetadb/pairing/ABCDEFGH/redeem"):
            status = 202
            data = Data()
        case (.delete, "/api/publicmetadb/pairing/ABCDEFGH"):
            status = 204
            data = Data()
        default:
            XCTFail("Unexpected pairing request")
            throw AppError.invalidResponse
        }
        return (data, try XCTUnwrap(HTTPURLResponse(
            url: baseURL, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"]
        )))
    }
}

@MainActor
private final class HostedTimestampSource: CommunityPlaybackTimestampProviding {
    let name = "PublicMetaDB"
    let isCurrent = true
    var includesHighlights: [Bool] = []
    func timestamps(for item: MediaItem, includeHighlights: Bool) async throws -> [CommunityPlaybackTimestamp] {
        includesHighlights.append(includeHighlights)
        return [.init(id: "intro-a", kind: .intro, start: 1, end: 5, release: .physical)]
    }
}
