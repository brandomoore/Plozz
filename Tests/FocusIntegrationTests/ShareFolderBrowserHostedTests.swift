#if os(tvOS)
@testable import AppShell
import CoreUI
import FeatureShareOnboarding
import MediaTransportHTTP
import MediaTransportWebDAV
import SwiftUI
import UIKit
import XCTest

@MainActor
final class ShareFolderBrowserHostedTests: XCTestCase {
    func testOpeningLargeFolderKeepsMainActorResponsiveAndCanReturnToRoot() async throws {
        try await wait {
            UIApplication.shared.connectedScenes.contains { $0.activationState == .foregroundActive }
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let model = UnifiedAddShareModel(webDAVProbe: LargeFolderProbe())
        model.openManualConnect()
        model.applyTransport(.webDAV)
        model.address = "https://fixture.example.test/media"
        model.connect()
        try await wait { model.step == .pickLocation && model.locationLoad == .loaded }
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        window.rootViewController = UIHostingController(rootView:
            UnifiedAddShareView(
                isPageReady: false,
                onBack: {},
                onSMBConfigured: { _ in XCTFail("Browsing must not save an account") },
                onWebDAVConfigured: { _ in XCTFail("Browsing must not save an account") },
                viewModel: model
            )
            .environment(\.themePalette, .pureBlack)
            .preferredColorScheme(.dark)
        )
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
            model.stopScan()
        }
        try await Task.sleep(for: .milliseconds(250))
        window.layoutIfNeeded()
        let rootTable = try XCTUnwrap(scrollViews(in: window).compactMap { $0 as? UITableView }.first)
        XCTAssertLessThan(rootTable.bounds.height, 250, "Short lists must retain their natural height.")

        for _ in 0..<2 {
            let movies = try XCTUnwrap(model.locations.first { $0.name == "Movies" })
            model.selectLocation(movies)
            let clock = ContinuousClock()
            var worst = Duration.zero
            for _ in 0..<20 {
                let start = clock.now
                try await Task.sleep(for: .milliseconds(20))
                window.layoutIfNeeded()
                worst = max(worst, start.duration(to: clock.now) - .milliseconds(20))
            }
            XCTAssertEqual(model.locationLoad, .loaded)
            XCTAssertEqual(model.locations.count, 1_551)
            let milliseconds = Double(worst.components.seconds) * 1_000
                + Double(worst.components.attoseconds) / 1_000_000_000_000_000
            let measurement = "1,551 folders: worst main-actor delay \(milliseconds)ms"
            let attachment = XCTAttachment(string: measurement)
            attachment.lifetime = .keepAlways
            add(attachment)
            print(measurement)
            XCTAssertLessThan(milliseconds, 150, "An instant folder listing must not eagerly render every row.")
            XCTAssertNotNil(UIFocusSystem.focusSystem(for: window)?.focusedItem)
            let scroll = try XCTUnwrap(scrollViews(in: window).first {
                $0.bounds.height <= 620 && $0.contentSize.height > 30_000
            })
            let table = try XCTUnwrap(scroll as? UITableView)
            XCTAssertLessThan(table.visibleCells.count, 20,
                              "Native focus must only search recycled viewport cells, not every directory entry.")
            XCTAssertFalse(table.clipsToBounds)
            for cell in table.visibleCells {
                XCTAssertFalse(cell.clipsToBounds)
                XCTAssertFalse(cell.contentView.clipsToBounds)
            }
            let outer = try XCTUnwrap(scrollViews(in: window).first { $0 !== scroll })
            outer.scrollRectToVisible(scroll.convert(scroll.bounds, to: outer), animated: false)
            table.scrollToRow(at: IndexPath(row: model.locations.count - 1, section: 0), at: .bottom, animated: false)
            try await Task.sleep(for: .milliseconds(100))
            window.layoutIfNeeded()
            let marker = UIView(frame: scroll.convert(
                CGRect(x: 80, y: scroll.bounds.maxY - 140, width: 4, height: 4), to: window
            ))
            marker.isUserInteractionEnabled = false
            window.addSubview(marker)
            defer { marker.removeFromSuperview() }
            let target = try XCTUnwrap(NavigationRowFocusRequester.target(for: marker, in: window))
            XCTAssertTrue(target.canBecomeFocused, "Deep lazy rows must expose a native focus target.")
            let frame = try XCTUnwrap(NavigationRowFocusRequester.frame(of: target, relativeTo: window))
            XCTAssertTrue(window.bounds.contains(frame), "The realized deep row must be onscreen.")
            XCTAssertGreaterThan(scroll.contentOffset.y, 30_000)
            XCTAssertTrue(model.canNavigateUp)
            model.navigateUp()
            try await wait { model.currentPath == "/media" && model.locationLoad == .loaded }
            XCTAssertEqual(model.locations.map(\.name), ["Movies", "TV Shows"])
            XCTAssertFalse(model.canNavigateUp, "Browsing must retain the originally entered root boundary.")
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private func scrollViews(in view: UIView) -> [UIScrollView] {
        ((view as? UIScrollView).map { [$0] } ?? []) + view.subviews.flatMap { scrollViews(in: $0) }
    }

    private func wait(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(predicate())
    }
}

private struct LargeFolderProbe: WebDAVOnboardingProbing {
    func preflightTrust(url: URL) async -> WebDAVTrustPreflight { .systemTrusted }

    func validate(
        url: URL, credential: WebDAVCredential, trust: WebDAVOnboardingTrust
    ) async -> Result<Void, WebDAVOnboardingError> {
        .success(())
    }

    func listFolders(
        url: URL, path: String, credential: WebDAVCredential, trust: WebDAVOnboardingTrust
    ) async -> Result<[WebDAVOnboardingFolder], WebDAVOnboardingError> {
        if path == "/media" {
            return .success(["Movies", "TV Shows"].map {
                WebDAVOnboardingFolder(path: "/media/\($0)", name: $0)
            })
        }
        return .success((0..<1_551).map {
            let name = String(format: "Movie %04d (2026)", $0)
            return WebDAVOnboardingFolder(path: "\(path)/\(name)", name: name)
        })
    }
}
#endif
