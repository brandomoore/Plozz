import CoreModels
import CoreUI
import FeatureSettings
import Observation
import SwiftUI
import UIKit
import Vision
import XCTest

@MainActor
@Observable
private final class LibraryUpdateHostedFixture {
    var included: Set<String> = ["media", "archive"]
}

@MainActor
final class LibraryFailureRecoveryHostedTests: XCTestCase {
    func testWatchlistQueryControlsAndFilteredRecoveryRenderTogether() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        let cases: [(WatchlistMediaFilter, SortField, String, String)] = [
            (.all, .dateAdded, "All", "Date Added"),
            (.movies, .name, "Movies", "Name"),
            (.shows, .releaseDate, "TV Shows", "Release Date")
        ]
        for (filter, sort, filterLabel, sortLabel) in cases {
            let preferences = WatchlistBrowsePreferences(
                filter: filter, sort: .init(field: sort, direction: sort.defaultDirection)
            )
            window.rootViewController = UIHostingController(rootView:
                ScrollView {
                    LazyVStack {
                        HStack {
                            Text("Watchlist").font(.largeTitle.bold())
                            Spacer()
                            WatchlistBrowseControls(preferences: .constant(preferences))
                        }
                        .focusSection()
                        WatchlistEmptyStateView(isFiltered: filter != .all, clearFilters: {})
                    }
                    .padding(60)
                }
                .environment(\.themePalette, ThemePalette.dark)
                .environment(\.locale, Locale(identifier: "en_US"))
                .background(.black)
            )
            window.makeKeyAndVisible()
            try await Task.sleep(for: .milliseconds(350))
            window.layoutIfNeeded()
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
                XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
            }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["en-US"]
            try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
            let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
            XCTAssertTrue(text.contains("Watchlist"), text)
            XCTAssertTrue(text.contains(filterLabel), text)
            XCTAssertTrue(text.contains(sortLabel), text)
            XCTAssertFalse(text.contains("Filter:"), text)
            XCTAssertFalse(text.contains("Sort:"), text)
            if filter != .all { XCTAssertTrue(text.contains("Clear Filters"), text) }
            let attachment = XCTAttachment(image: image)
            attachment.name = "watchlist-query-controls-tv-\(filter.rawValue)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    func testLibraryUpdateIsCompactAndScopedToItsIncludedServerSection() async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !UIApplication.shared.connectedScenes.contains(where: { $0.activationState == .foregroundActive }),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let fixture = LibraryUpdateHostedFixture()
        let suite = "LibraryUpdatePresentation.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let visibility = HomeLibraryVisibilityModel(store: HomeLibraryVisibilityStore(defaults: defaults))
        let status = ShareScanStatusModel()
        status.scanStarted(shareID: "media", name: "Media")
        status.enrichStarted(shareID: "media", total: 100)
        status.enrichProgress(shareID: "media", done: 9)
        status.scanStarted(shareID: "excluded", name: "Excluded")
        status.scanStarted(shareID: "removed", name: "Removed")
        let accounts = try ["media", "archive", "excluded"].map { id in
            Account(
                id: id,
                server: MediaServer(
                    id: id, name: id.capitalized,
                    baseURL: try XCTUnwrap(URL(string: "nfs://127.0.0.1/\(id)")), provider: .mediaShare
                ),
                userID: "", userName: "", deviceID: "fixture"
            )
        }
        let libraries = accounts.map { account in
            AggregatedLibrary(
                accountID: account.id, accountName: "", serverName: account.server.name,
                providerKind: .mediaShare,
                library: .init(id: "movies", title: "Movies", kind: .movie)
            )
        }
        let scope = ProfileLibrariesScope(
            accounts: accounts, activeProfile: .init(id: "profile", name: "Alex"),
            discoveredLibraries: .loaded(libraries), refreshingLibraryAccountIDs: [],
            unreachableLibraryAccountIDs: [], reloadLibraries: {}, homeVisibility: visibility,
            isAccountIncludedInActiveProfile: { fixture.included.contains($0) },
            onSetAccountIncluded: { id, included in
                if included { fixture.included.insert(id) } else { fixture.included.remove(id) }
            }, onAddAccount: {}, plexHomeUsersFetcher: { _ in [] }, onSelectPlexHomeUser: { _, _ in }
        )
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        window.rootViewController = UIHostingController(rootView:
            MyLibrariesDetailView(scope: scope)
                .frame(width: SettingsFormMetrics.pageWidth)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .environment(status)
                .environment(\.settingsInWorkspace, true)
                .environment(\.themePalette, ThemePalette.dark)
                .environment(\.locale, Locale(identifier: "en_US"))
                .background { AmbientGradientBackground(palette: .dark) }
        )
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        for phase in ["busy", "excluded", "finished"] {
            if phase == "excluded" { fixture.included.remove("media") }
            if phase == "finished" {
                fixture.included.insert("media")
                status.scanFinished(shareID: "media")
                status.enrichFinished(shareID: "media")
            }
            try await Task.sleep(for: .milliseconds(350))
            window.layoutIfNeeded()
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
                XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
            }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["en-US"]
            try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
            let results = request.results ?? []
            let updates = results.filter {
                $0.topCandidates(1).first?.string.localizedCaseInsensitiveContains("Updating library") == true
            }
            XCTAssertEqual(updates.count, phase == "busy" ? 1 : 0)
            if phase == "busy" {
                let update = try XCTUnwrap(updates.first)
                XCTAssertLessThanOrEqual(update.boundingBox.height * 1080, 32)
                let media = try XCTUnwrap(results.first { $0.topCandidates(1).first?.string == "Media" })
                let archive = try XCTUnwrap(results.first { $0.topCandidates(1).first?.string == "Archive" })
                XCTAssertLessThan(update.boundingBox.midY, media.boundingBox.midY)
                XCTAssertGreaterThan(update.boundingBox.midY, archive.boundingBox.midY)
                XCTAssertTrue(results.contains { $0.topCandidates(1).first?.string == "9%" })
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = "settings-library-progress-\(phase)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    func testLibrariesDistinguishOfflineAuthenticationAndServerResponseFailures() async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !UIApplication.shared.connectedScenes.contains(where: { $0.activationState == .foregroundActive }),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }

        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let server = MediaServer(
            id: "silo", name: "Silo Test", baseURL: URL(string: "https://silo.example.test")!, provider: .silo
        )
        let account = Account(id: "silo", server: server, userID: "viewer", userName: "Viewer", deviceID: "test")
        let suite = "LibraryFailurePresentation.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let visibility = HomeLibraryVisibilityModel(store: HomeLibraryVisibilityStore(defaults: defaults))

        for failure in [AppError.serverUnreachable, .unauthorized, .invalidResponse] {
            let scope = ProfileLibrariesScope(
                accounts: [account], activeProfile: .init(id: "profile", name: "Viewer"),
                discoveredLibraries: .empty, refreshingLibraryAccountIDs: [],
                unreachableLibraryAccountIDs: ["silo"], libraryFailures: ["silo": failure],
                reloadLibraries: {}, homeVisibility: visibility,
                isAccountIncludedInActiveProfile: { _ in true },
                onSetAccountIncluded: { _, _ in }, onAddAccount: {}, onAddUser: { _ in },
                plexHomeUsersFetcher: { _ in [] }, onSelectPlexHomeUser: { _, _ in }
            )
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
            window.rootViewController = UIHostingController(rootView:
                MyLibrariesDetailView(scope: scope)
                    .environment(\.themePalette, ThemePalette.dark)
                    .environment(\.locale, Locale(identifier: "en_US"))
                    .background(.black)
            )
            window.makeKeyAndVisible()
            defer {
                window.isHidden = true
                window.rootViewController = nil
                previous?.makeKeyAndVisible()
            }
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(350))
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
                XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
            }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["en-US"]
            try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
            let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: " ").lowercased()
            if failure.requiresSignIn {
                XCTAssertTrue(text.contains("session has expired"), text)
                XCTAssertTrue(text.contains("sign in"), text)
                XCTAssertFalse(text.contains("offline"), text)
            } else if failure == .serverUnreachable {
                XCTAssertTrue(text.contains("offline"), text)
                XCTAssertTrue(text.contains("retry"), text)
            } else {
                XCTAssertTrue(text.contains("unexpected response"), text)
                XCTAssertFalse(text.contains("offline"), text)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = "Library failure - \(HandoffDiagnostics.errorCode(failure))"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }
}
