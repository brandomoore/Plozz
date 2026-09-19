#if os(tvOS)
import CoreModels
import HeroUI
import Observation
import SwiftUI
import UIKit
import XCTest

@MainActor
final class HeroExposureHostedTests: XCTestCase {
    func testFreshnessClockRefreshesOnStaleReturnWithoutRepeatedRequests() {
        let start = Date(timeIntervalSince1970: 1_000)
        let clock = HeroFreshnessRefreshDriver(now: start)
        XCTAssertFalse(clock.requestIfDue(at: start.addingTimeInterval(599)))
        XCTAssertTrue(clock.requestIfDue(at: start.addingTimeInterval(600)))
        XCTAssertEqual(clock.revision, 1)
        XCTAssertFalse(clock.requestIfDue(at: start.addingTimeInterval(601)))
        clock.beganCuration(at: start.addingTimeInterval(700))
        XCTAssertFalse(clock.requestIfDue(at: start.addingTimeInterval(1_299)))
        XCTAssertTrue(clock.requestIfDue(at: start.addingTimeInterval(1_300)))
        XCTAssertEqual(clock.revision, 2)
        XCTAssertNotEqual(
            clock.activityID(isActive: true),
            HeroFreshnessRefreshDriver(now: start).activityID(isActive: true)
        )
        XCTAssertNotEqual(
            clock.activityID(isActive: true), clock.activityID(isActive: false)
        )
    }

    func testVisibleSlideCountsOnceAfterTwoSeconds() async throws {
        let model = ExposureFixture()
        let appeared = expectation(description: "Visible title recorded")
        model.didRecord = { appeared.fulfill() }
        let started = Date()
        let window = try await host(model)
        defer { close(window) }

        await fulfillment(of: [appeared], timeout: 4)
        XCTAssertEqual(model.records.map(\.itemID), ["first"])
        let recorded = try XCTUnwrap(model.records.first)
        XCTAssertGreaterThanOrEqual(recorded.at.timeIntervalSince(started), 2)
    }

    func testOffscreenAndInactiveTimeDoesNotCount() async throws {
        let model = ExposureFixture()
        model.isVisible = false
        let window = try await host(model)
        defer { close(window) }
        try await Task.sleep(for: .milliseconds(2200))
        XCTAssertTrue(model.records.isEmpty)

        model.phase = .inactive
        model.isVisible = true
        try await Task.sleep(for: .milliseconds(2200))
        XCTAssertTrue(model.records.isEmpty)

        let appeared = expectation(description: "Fresh active exposure recorded")
        model.didRecord = { appeared.fulfill() }
        let activated = Date()
        model.phase = .active
        await fulfillment(of: [appeared], timeout: 4)
        let recorded = try XCTUnwrap(model.records.first)
        XCTAssertGreaterThanOrEqual(recorded.at.timeIntervalSince(activated), 2)
    }

    func testSlideAndProfileChangesCancelPendingExposure() async throws {
        let model = ExposureFixture()
        let window = try await host(model)
        defer { close(window) }
        try await Task.sleep(for: .milliseconds(800))
        model.item = MediaItem(id: "second", title: "Second", kind: .movie)
        try await Task.sleep(for: .milliseconds(800))
        model.scope = ExposureScope()
        let activeScope = ObjectIdentifier(model.scope)
        let scopeChanged = Date()
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertTrue(model.records.isEmpty)

        let appeared = expectation(description: "Only replacement profile records")
        model.didRecord = { appeared.fulfill() }
        await fulfillment(of: [appeared], timeout: 3)
        XCTAssertEqual(model.records.map(\.itemID), ["second"])
        let recorded = try XCTUnwrap(model.records.first)
        XCTAssertEqual(recorded.scopeID, activeScope)
        XCTAssertGreaterThanOrEqual(recorded.at.timeIntervalSince(scopeChanged), 2)
    }

    func testUnmountingHeroCancelsPendingExposure() async throws {
        let model = ExposureFixture()
        let window = try await host(model)
        defer { close(window) }
        try await Task.sleep(for: .milliseconds(400))
        model.isMounted = false
        try await Task.sleep(for: .milliseconds(2200))
        XCTAssertTrue(model.records.isEmpty)
    }

    private func host(_ model: ExposureFixture) async throws -> UIWindow {
        let deadline = ContinuousClock.now + .seconds(5)
        while !UIApplication.shared.connectedScenes.contains(where: { $0.activationState == .foregroundActive }),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: ExposureFixtureView(model: model))
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        return window
    }

    private func close(_ window: UIWindow) {
        window.isHidden = true
        window.rootViewController = nil
    }
}

@MainActor
private final class ExposureScope {}

@MainActor
@Observable
private final class ExposureFixture {
    struct Record {
        let itemID: String
        let scopeID: ObjectIdentifier
        let at: Date
    }

    var item = MediaItem(id: "first", title: "First", kind: .movie)
    var scope = ExposureScope()
    var isVisible = true
    var isMounted = true
    var phase = ScenePhase.active
    var records: [Record] = []
    @ObservationIgnored var didRecord: (() -> Void)?
}

private struct ExposureFixtureView: View {
    let model: ExposureFixture

    var body: some View {
        Group {
            if model.isMounted {
                let scopeID = ObjectIdentifier(model.scope)
                Text(verbatim: model.item.title)
                    .trackHeroExposure(
                        item: model.item,
                        isVisible: model.isVisible,
                        scopeID: scopeID
                    ) { item in
                        model.records.append(.init(itemID: item.id, scopeID: scopeID, at: Date()))
                        model.didRecord?()
                    }
            } else {
                Color.clear
            }
        }
        .environment(\.scenePhase, model.phase)
    }
}
#endif
