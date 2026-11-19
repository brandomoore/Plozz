import CoreModels
import CoreImage
import CoreNetworking
import CoreUI
import Observation
@testable import FeatureSettings
import PublicMetaDBService
import SwiftUI
import UIKit
import Vision
import XCTest

@MainActor
final class PublicMetaDBCatalogHostedTests: XCTestCase {
    func testSuccessfulReadKeepsOneTaskAndItsRenderedRows() async throws {
        try await withService { service in
            var reads = 0
            var visible = Set<String>()
            let operation = PublicMetaDBReadOperation<[String]>()
            let content = PublicMetaDBPage {
                SettingsPageHeader("Read lifecycle")
                PublicMetaDBReadContent(service: service, operation: operation) { values in
                    ForEach(values, id: \.self) { value in
                        Text(verbatim: value)
                            .onAppear { visible.insert(value) }
                            .onDisappear { visible.remove(value) }
                    }
                }
            }
            .publicMetaDBRead(operation, service: service) { _ in
                reads += 1
                try await Task.sleep(for: .milliseconds(50))
                return ["First contribution", "Second contribution"]
            }
            try await withWindow(content) { _ in
                try await Task.sleep(for: .milliseconds(500))
                XCTAssertEqual(reads, 1, "Rendering loading/results must not start additional reads")
                XCTAssertEqual(visible, ["First contribution", "Second contribution"])
                try await Task.sleep(for: .milliseconds(500))
                XCTAssertEqual(reads, 1, "A loaded page must remain idle until explicit refresh")
                XCTAssertEqual(visible, ["First contribution", "Second contribution"])
            }
        }
    }

    func testReadTaskSurvivesResultsPushingRefreshOffscreen() async throws {
        try await withService { service in
            var reads = 0
            var visible = Set<Int>()
            let operation = PublicMetaDBReadOperation<[Int]>()
            let content = NavigationStack {
                PublicMetaDBPage {
                    SettingsPageHeader("Community contributions")
                    PublicMetaDBReadContent(service: service, operation: operation) { values in
                        ForEach(values, id: \.self) { value in
                            NavigationLink {
                                Text(value, format: .number)
                            } label: {
                                VStack(alignment: .leading) {
                                    Text("Contribution \(value)")
                                    Text("50 / 100")
                                    Text("Test author")
                                }
                            }
                            .onAppear { visible.insert(value) }
                            .onDisappear { visible.remove(value) }
                        }
                    }
                }
                .publicMetaDBRead(operation, service: service) { _ in
                    reads += 1
                    try await Task.sleep(for: .milliseconds(50))
                    return Array(1...21)
                }
            }
            try await withWindow(content) { _ in
                try await Task.sleep(for: .milliseconds(500))
                XCTAssertEqual(reads, 1, "Lazy result rows must not own or restart the read task")
                XCTAssertTrue(visible.contains(1))
                try await Task.sleep(for: .milliseconds(500))
                XCTAssertEqual(reads, 1, "Moving Refresh offscreen must not reload the result")
                XCTAssertTrue(visible.contains(1))
                operation.refresh()
                try await Task.sleep(for: .milliseconds(500))
                XCTAssertEqual(reads, 2, "Explicit refresh must perform exactly one new read")
                XCTAssertTrue(visible.contains(1))
            }
        }
    }

    func testReadPageSelectionAndEnablementRevokeObsoleteResults() async throws {
        try await withService { service in
            let operation = PublicMetaDBReadOperation<[Int]>()
            let selection = ReadSelection()
            var reads: [Int] = []
            let content = ReadSelectionFixture(service: service, operation: operation, selection: selection) { value in
                reads.append(value)
                try await Task.sleep(for: .milliseconds(100))
                return [value]
            }
            try await withWindow(content) { _ in
                try await Task.sleep(for: .milliseconds(200))
                XCTAssertTrue(reads.isEmpty, "A hidden optional collection must not be fetched")
                selection.enabled = true
                try await waitFor { operation.value == [1] }
                XCTAssertEqual(reads, [1])
                selection.id = 2
                try await waitFor { reads == [1, 2] }
                XCTAssertNil(operation.value)
                selection.enabled = false
                try await waitFor { operation.connectionID == nil }
                try await Task.sleep(for: .milliseconds(200))
                XCTAssertNil(operation.value)
                XCTAssertNil(operation.failure)
                XCTAssertFalse(operation.loading)
                selection.id = 3
                selection.enabled = true
                try await waitFor { operation.value == [3] }
                XCTAssertEqual(reads, [1, 2, 3])
                XCTAssertEqual(operation.selectionID, AnyHashable(3))
                service.selectProfile(namespace: "different-profile")
                try await waitFor { operation.failure as? PublicMetaDB.Failure == .disconnected }
                XCTAssertNil(operation.value)
                XCTAssertEqual(reads, [1, 2, 3], "A disconnected profile must not issue another read")
            }
        }
    }

    #if os(tvOS)
    func testWebsiteEntryRendersExactChallengeAndSwitchingToManualRevokesIt() async throws {
        let revoked = expectation(description: "Old challenge revoked")
        try await withService(connected: false, http: PairingUIHTTP(onRevoke: { revoked.fulfill() })) { service in
            let pairing = Task { await service.connectUsingBrowser() }
            defer { pairing.cancel() }
            try await waitFor { service.browserPairing.challenge != nil }
            let challenge = try XCTUnwrap(service.browserPairing.challenge)
            try await withWindow(keyEntryFixture(service)) { window in
                let text = try await renderedKeyEntry(
                    window, expectedURL: challenge.url.absoluteString, expectedCode: challenge.displayCode
                )
                XCTAssertTrue(text.contains("plozz.app/pmdb"), text)
                XCTAssertTrue(text.contains("Enter API key manually"), text)
                XCTAssertTrue(text.contains("Cancel"), text)
            }
            service.switchToManualKeyEntry()
            XCTAssertNil(service.browserPairing.challenge)
            await pairing.value
            await fulfillment(of: [revoked], timeout: 5)
            XCTAssertFalse(service.browserPairing.isActive)
            XCTAssertFalse(service.hasSavedKey)
            XCTAssertEqual(service.phase, .disconnected)
        }
    }
    #endif

    func testUnavailablePairingShowsItsActualError() async throws {
        try await withService(connected: false, http: PairingUIHTTP(unavailable: true)) { service in
            await service.connectUsingBrowser()
            XCTAssertEqual(service.phase, .pairingFailed(.unavailable))
            try await withWindow(keyEntryFixture(service)) { window in
                let text = try await renderedKeyEntry(window, expectedURL: nil)
                XCTAssertTrue(text.contains("QR code unavailable"), text)
                #if os(tvOS)
                XCTAssertTrue(text.contains("Try again") && text.contains("Cancel"), text)
                XCTAssertTrue(text.contains("Enter API key manually"), text)
                #else
                XCTAssertTrue(text.contains("API key"), text)
                #endif
                XCTAssertFalse(text.contains("Something went wrong"), text)
            }
        }
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
            let ready = (expectedURL.map { urls.contains($0) } ?? text.contains("QR code unavailable"))
                && hasSingleLineCode
            if ready || ContinuousClock.now >= deadline {
                let attachment = XCTAttachment(image: image)
                attachment.name = expectedURL == nil ? "pairing-unavailable" : "pairing-qr"
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

@MainActor
@Observable
private final class ReadSelection {
    var id = 1
    var enabled = false
}

private struct ReadSelectionFixture: View {
    let service: PublicMetaDBService
    let operation: PublicMetaDBReadOperation<[Int]>
    let selection: ReadSelection
    let load: @MainActor (Int) async throws -> [Int]

    var body: some View {
        let id = selection.id
        PublicMetaDBPage {
            if selection.enabled {
                PublicMetaDBReadContent(service: service, operation: operation, id: id) { values in
                    ForEach(values, id: \.self) { Text($0, format: .number) }
                }
            }
        }
        .publicMetaDBRead(operation, service: service, id: id, enabled: selection.enabled) { _ in
            try await load(id)
        }
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
    var onRevoke: @Sendable () -> Void = {}

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
            onRevoke()
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
