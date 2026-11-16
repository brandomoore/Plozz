#if os(iOS)
import CoreModels
import CoreUI
import FeatureHomeCore
import SwiftUI
import UIKit
import Vision
import XCTest

@MainActor
final class UpcomingEmptyStateTests: XCTestCase {
    func testEmptyAndFailedAgendasExplainTheStateOnPhoneAndTablet() async throws {
        for failed in [false, true] {
            let model = try makeModel()
            await model.refresh(scope: UUID().uuidString, namespace: nil, isCurrent: { true }) {
                UpcomingFeedSnapshot(failedSourceCount: failed ? 1 : 0)
            }
            for width in [CGFloat(390), 834] {
                let text = try await renderedText(model: model, width: width, name: failed ? "failed" : "empty")
                if failed {
                    XCTAssertTrue(text.contains("Couldn't load releases"), text)
                    XCTAssertTrue(text.contains("Retry"), text)
                    XCTAssertFalse(text.contains("Nothing upcoming yet"), text)
                } else {
                    XCTAssertTrue(text.contains("Nothing upcoming yet"), text)
                    XCTAssertTrue(text.contains("Live TV schedules are in the guide."), text)
                    XCTAssertFalse(text.contains("Retry"), text)
                }
            }
        }
    }

    func testFilteredAndHiddenAgendasOfferTheRelevantRecovery() async throws {
        let item = MediaItem(id: "saved", title: "Saved film", kind: .movie)
        let release = UpcomingRelease(
            id: "release", titleKey: UpcomingRelease.titleKey(for: item), item: item, date: Date(),
            datePrecision: .dateOnly, kind: .digital, interests: [.watchlist]
        )
        for hidden in [false, true] {
            let model = try makeModel()
            await model.refresh(scope: UUID().uuidString, namespace: nil, isCurrent: { true }) {
                UpcomingFeedSnapshot(releases: [release])
            }
            if hidden {
                model.hide(release)
            } else {
                model.filters.mediaType = .shows
            }
            let text = try await renderedText(model: model, width: 390, name: hidden ? "hidden" : "filtered")
            XCTAssertTrue(text.contains("No matching releases"), text)
            XCTAssertTrue(text.contains(hidden ? "Restore hidden titles" : "Reset filters"), text)
            XCTAssertFalse(text.contains("Nothing upcoming yet"), text)
        }
    }

    private func makeModel() throws -> UpcomingFeedModel {
        let suite = "UpcomingEmptyStateTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return UpcomingFeedModel(defaults: defaults)
    }

    private func renderedText(model: UpcomingFeedModel, width: CGFloat, name: String) async throws -> String {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: width, height: 1024)
        let host = UIHostingController(rootView:
            NavigationStack {
                UpcomingView(model: model, interval: DateInterval(start: Date(), duration: 90 * 86_400))
            }
            .environment(\.themePalette, .dark)
            .environment(\.colorScheme, .dark)
            .environment(\.locale, Locale(identifier: "en"))
            .environment(\.horizontalSizeClass, width < 600 ? .compact : .regular)
            .environment(\.plozzMetrics, .touch(density: .standard))
        )
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        try await Task.sleep(for: .milliseconds(300))
        window.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
        if let directory = ProcessInfo.processInfo.environment["PLOZZ_UPCOMING_CAPTURE_DIR"] {
            try XCTUnwrap(image.pngData()).write(
                to: URL(fileURLWithPath: directory).appendingPathComponent("\(name)-\(Int(width)).png")
            )
        } else {
            let attachment = XCTAttachment(image: image)
            attachment.name = "Upcoming \(name), width \(Int(width))"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
            .replacingOccurrences(of: "’", with: "'")
    }
}
#endif
