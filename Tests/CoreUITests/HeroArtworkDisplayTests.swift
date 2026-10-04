import CoreModels
import Observation
import SwiftUI
import UIKit
import XCTest
@testable import CoreUI

@MainActor
final class HeroArtworkDisplayTests: XCTestCase {
    func testPaletteAndContrastUseDisplayedPixelsWithoutLoadingAnotherImage() async throws {
        let reference = try networkReference()
        let loader = DisplayArtworkLoader(data: try XCTUnwrap(image(.blue).pngData()))
        ArtworkImageCache.shared.configure(networkFileService: ArtworkNetworkFileService(loader: loader))
        defer { ArtworkImageCache.shared.configure(networkFileService: nil) }
        let artwork = FirstPaintArtwork(image: image(.green), reference: .networkFile(reference), variant: .heroBackdrop)

        let sampledPalette = await AmbientPaletteSampler.sample(
            DisplayedHeroArtwork(itemID: "current", artwork: artwork)
        )
        let palette = try XCTUnwrap(sampledPalette)
        let sampledContrast = await HeroBackgroundSampler.sample(artwork: artwork)
        let contrast = try XCTUnwrap(sampledContrast)
        XCTAssertFalse(palette.isEmpty)
        for color in palette {
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            XCTAssertTrue(UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha))
            XCTAssertGreaterThan(green, 0.95)
            XCTAssertLessThan(blue, 0.05)
        }
        XCTAssertGreaterThan(contrast.green, 0.95)
        XCTAssertLessThan(contrast.blue, 0.05)
        let loads = await loader.count
        XCTAssertEqual(loads, 0)
    }

    func testPreviewFullMissingAndReturningArtworkStayBoundToCurrentSubject() async throws {
        let state = HeroArtworkDisplayState()
        let owner = UUID()
        let reference = ArtworkReference.networkFile(try networkReference())
        let preview = FirstPaintArtwork(image: image(.red), reference: reference, variant: .heroPreview)
        let full = FirstPaintArtwork(image: image(.green), reference: reference, variant: .heroBackdrop)
        state.activate(owner: owner, itemID: "current")
        state.publish(preview, itemID: "current", owner: owner)
        await waitUntil { state.backgroundSample != nil }
        XCTAssertGreaterThan(try XCTUnwrap(state.sample(for: "current")).red, 0.95)
        XCTAssertNil(state.sample(for: "outgoing-logo"))
        let previewKey = try XCTUnwrap(state.displayed?.key)

        state.publish(full, itemID: "current", owner: owner)
        XCTAssertNil(state.backgroundSample)
        await waitUntil { state.backgroundSample != nil }
        XCTAssertNotEqual(state.displayed?.key, previewKey)
        XCTAssertGreaterThan(try XCTUnwrap(state.sample(for: "current")).green, 0.95)
        XCTAssertTrue(state.displayed?.artwork.image === full.image)

        state.publish(nil, itemID: "current", owner: owner)
        XCTAssertNil(state.displayed)
        XCTAssertNil(state.backgroundSample)
        state.publish(full, itemID: "current", owner: owner)
        await waitUntil { state.backgroundSample != nil }
        state.release(owner: owner)
        XCTAssertNil(state.displayed)
        XCTAssertNil(state.backgroundSample)
    }

    func testQueuedOldAndInactiveReportersCannotReplaceOrResurrectArtwork() async throws {
        let state = HeroArtworkDisplayState()
        let old = UUID(), current = UUID()
        let oldReporter = HeroArtworkDisplayReporter(state: state, owner: old, itemID: "old", isActive: true)
        let reporter = HeroArtworkDisplayReporter(state: state, owner: current, itemID: "current", isActive: true)
        let inactive = HeroArtworkDisplayReporter(state: state, owner: current, itemID: "current", isActive: false)
        let artwork = FirstPaintArtwork(image: image(.green), reference: .networkFile(try networkReference()), variant: .heroBackdrop)

        state.activate(owner: old, itemID: "old")
        oldReporter.publish(artwork, itemID: "old")
        state.activate(owner: current, itemID: "current")
        reporter.publish(artwork, itemID: "current")
        oldReporter.publish(artwork, itemID: "old")
        reporter.publish(artwork, itemID: "incoming")
        inactive.publish(nil, itemID: "current")
        await waitUntil { state.backgroundSample != nil }
        XCTAssertEqual(state.displayed?.itemID, "current")
        state.release(owner: old)
        XCTAssertEqual(state.displayed?.itemID, "current")
        reporter.publish(artwork, itemID: "current")
        state.release(owner: current)
        await Task.yield()
        XCTAssertNil(state.displayed)
        XCTAssertNil(state.backgroundSample)
    }

    func testQueuedPreviewAndFullReportsPublishOnlyTheLatestAdoption() async throws {
        let state = HeroArtworkDisplayState()
        let owner = UUID()
        let reference = ArtworkReference.networkFile(try networkReference())
        let reporter = HeroArtworkDisplayReporter(state: state, owner: owner, itemID: "current", isActive: true)
        let preview = FirstPaintArtwork(image: image(.red), reference: reference, variant: .heroPreview)
        let full = FirstPaintArtwork(image: image(.green), reference: reference, variant: .heroBackdrop)
        reporter.publish(preview, itemID: "current")
        reporter.publish(full, itemID: "current")
        state.activate(owner: owner, itemID: "current")
        await waitUntil { state.backgroundSample != nil }
        XCTAssertEqual(state.displayed?.artwork.variant, .heroBackdrop)
        XCTAssertTrue(state.displayed?.artwork.image === full.image)
        XCTAssertGreaterThan(try XCTUnwrap(state.backgroundSample).green, 0.95)
    }

    func testQueuedPreviousSubjectCannotDiscardCurrentArtworkFromSameOwner() async throws {
        let reference = ArtworkReference.networkFile(try networkReference())
        let previous = FirstPaintArtwork(image: image(.blue), reference: reference, variant: .heroBackdrop)
        let preview = FirstPaintArtwork(image: image(.red), reference: reference, variant: .heroPreview)
        let full = FirstPaintArtwork(image: image(.green), reference: reference, variant: .heroBackdrop)
        let staleReports: [FirstPaintArtwork?] = [previous, nil]

        for activateBeforeReports in [true, false] {
            for staleReport in staleReports {
                let state = HeroArtworkDisplayState()
                let owner = UUID()
                let previousReporter = HeroArtworkDisplayReporter(
                    state: state, owner: owner, itemID: "previous", isActive: true
                )
                let currentReporter = HeroArtworkDisplayReporter(
                    state: state, owner: owner, itemID: "current", isActive: true
                )
                state.activate(owner: owner, itemID: "previous")
                state.publish(previous, itemID: "previous", owner: owner)
                if activateBeforeReports {
                    state.activate(owner: owner, itemID: "current")
                }
                currentReporter.publish(preview, itemID: "current")
                currentReporter.publish(full, itemID: "current")
                previousReporter.publish(staleReport, itemID: "previous")
                if !activateBeforeReports {
                    state.activate(owner: owner, itemID: "current")
                }

                await waitUntil { state.sample(for: "current") != nil }
                XCTAssertEqual(state.displayed?.itemID, "current")
                XCTAssertEqual(state.displayed?.artwork.variant, .heroBackdrop)
                XCTAssertTrue(state.displayed?.artwork.image === full.image)
                XCTAssertGreaterThan(try XCTUnwrap(state.sample(for: "current")).green, 0.95)
                XCTAssertNil(state.sample(for: "previous"))
                state.release(owner: owner)
            }
        }
    }

    func testReleasingOwnerCancelsQueuedReportsForEverySubject() async throws {
        let artwork = FirstPaintArtwork(
            image: image(.green), reference: .networkFile(try networkReference()), variant: .heroBackdrop
        )
        for itemID in ["previous", "current"] {
            let state = HeroArtworkDisplayState()
            let owner = UUID()
            state.activate(owner: owner, itemID: "previous")
            state.enqueue(artwork, itemID: "previous", owner: owner)
            state.enqueue(artwork, itemID: "current", owner: owner)
            state.release(owner: owner)
            state.activate(owner: owner, itemID: itemID)

            let republished = expectation(description: "Released \(itemID) report must not publish")
            republished.isInverted = true
            withObservationTracking {
                _ = state.displayed
            } onChange: {
                republished.fulfill()
            }
            await fulfillment(of: [republished], timeout: 0.1)
            XCTAssertNil(state.displayed)
            XCTAssertNil(state.backgroundSample)
        }
    }

    func testCachedRendererRepublishesOnSubjectChangeAndReactivationWithoutGradientOrExtraLoads() async throws {
        let reference = ArtworkReference.networkFile(try networkReference())
        let incoming = ArtworkReference.networkFile(try networkReference())
        let loader = DisplayArtworkLoader(data: try XCTUnwrap(image(.green).pngData()))
        let cache = ArtworkImageCache.shared
        cache.configure(networkFileService: ArtworkNetworkFileService(loader: loader))
        defer { cache.configure(networkFileService: nil) }
        let cachedImage = await cache.image(for: reference, variant: .heroBackdrop)
        let cached = try XCTUnwrap(cachedImage)
        let incomingImage = await cache.image(for: incoming, variant: .heroBackdrop)
        let cachedIncoming = try XCTUnwrap(incomingImage)
        let baselineLoads = await loader.count
        let state = HeroArtworkDisplayState()
        func fixture(active: Bool, showIncoming: Bool = false) -> ReportingArtworkFixture {
            ReportingArtworkFixture(
                state: state,
                reference: showIncoming ? incoming : reference,
                incoming: showIncoming ? reference : incoming,
                isActive: active,
                itemID: showIncoming ? "incoming" : "current",
                incomingItemID: showIncoming ? "current" : "incoming"
            )
        }
        let previousWindow = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow)
        let controller = UIHostingController(rootView: fixture(active: true))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 480, height: 270))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKey()
        }
        controller.view.layoutIfNeeded()
        await waitUntil { state.backgroundSample != nil }
        XCTAssertEqual(state.displayed?.itemID, "current")
        XCTAssertEqual(state.displayed?.artwork.reference, reference)
        XCTAssertTrue(state.displayed?.artwork.image === cached)

        controller.rootView = fixture(active: true, showIncoming: true)
        controller.view.layoutIfNeeded()
        await waitUntil { state.sample(for: "incoming") != nil }
        XCTAssertEqual(state.displayed?.artwork.reference, incoming)
        XCTAssertTrue(state.displayed?.artwork.image === cachedIncoming)
        XCTAssertNil(state.sample(for: "current"))
        controller.rootView = fixture(active: true)
        controller.view.layoutIfNeeded()
        await waitUntil { state.sample(for: "current") != nil }
        XCTAssertTrue(state.displayed?.artwork.image === cached)

        controller.rootView = fixture(active: false)
        controller.view.layoutIfNeeded()
        await waitUntil { state.displayed == nil }
        controller.rootView = fixture(active: true)
        controller.view.layoutIfNeeded()
        await waitUntil { state.backgroundSample != nil }
        XCTAssertTrue(state.displayed?.artwork.image === cached)
        XCTAssertEqual(state.displayed?.itemID, "current")
        let finalLoads = await loader.count
        XCTAssertEqual(finalLoads, baselineLoads)
    }

    func testLogoRefinementReusesPreparedImageAndMeasuredInk() {
        let prepared = PreparedLogo(image: image(.green), luminance: 0.5, red: 0.2, green: 0.6, blue: 0.1, coverage: 0.4)
        let original = HeroLogoAnalysis.analyze(prepared, backgroundSample: nil)
        let matching = HeroBackgroundSample(red: 0.2, green: 0.6, blue: 0.1, luminance: 0.5)
        let different = HeroBackgroundSample(red: 1, green: 1, blue: 1, luminance: 1)
        let refined = HeroLogoAnalysis.refine(original, backgroundSample: different)
        XCTAssertTrue(refined.image === original.image)
        XCTAssertEqual(refined.tone, original.tone)
        XCTAssertFalse(refined.needsHalo)
        XCTAssertTrue(HeroLogoAnalysis.refine(refined, backgroundSample: matching).needsHalo)
        let native = HeroUIKitLogo(image: original.image, isMonochrome: original.isMonochrome,
                                  needsHalo: original.needsHalo, isDark: original.isDark,
                                  coverage: original.coverage, measuredTone: original.tone)
        XCTAssertFalse(native.matchingBackground(different).needsHalo)
        XCTAssertTrue(native.matchingBackground(matching).needsHalo)
        XCTAssertTrue(native.matchingBackground(different).image === original.image)
    }

    private func image(_ color: UIColor) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 48, height: 32)).image {
            color.setFill()
            $0.fill(CGRect(x: 0, y: 0, width: 48, height: 32))
        }
    }

    private func networkReference() throws -> NetworkArtworkReference {
        try NetworkArtworkReference(
            accountID: UUID().uuidString, credentialRevision: CredentialRevision(),
            catalogArtworkID: UUID().uuidString,
            representation: RemoteFileRepresentation(
                size: 1_024,
                identity: RemoteFileIdentity(kind: .modificationTime, modifiedAt: .distantPast),
                consistency: .changeDetecting
            ),
            sourceRevision: UUID().uuidString
        )
    }

    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Displayed artwork did not reach the expected state", file: file, line: line)
    }
}

private actor DisplayArtworkLoader: ArtworkNetworkFileLoading {
    let data: Data
    private(set) var count = 0
    init(data: Data) { self.data = data }
    func loadArtwork(_ reference: NetworkArtworkReference, maximumBytes: Int) async throws -> Data {
        count += 1
        return data
    }
}

private struct ReportingArtworkFixture: View {
    let state: HeroArtworkDisplayState
    let reference: ArtworkReference
    let incoming: ArtworkReference
    let isActive: Bool
    let itemID: String
    let incomingItemID: String

    var body: some View {
        ZStack {
            FallbackAsyncImage(references: [reference], variant: .heroBackdrop, pinIdentity: itemID) { Color.clear }
                .reportingHeroArtwork(id: itemID)
            FallbackAsyncImage(references: [incoming], variant: .heroBackdrop, pinIdentity: incomingItemID) { Color.clear }
                .reportingHeroArtwork(id: incomingItemID)
                .opacity(0.2)
        }
        .heroArtworkSource(id: itemID, isActive: isActive)
        .environment(\.heroArtworkDisplayState, state)
        .environment(\.gradientBackgroundsEnabled, false)
    }
}
