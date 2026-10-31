#if canImport(UIKit)
import CoreModels
import SwiftUI
import UIKit
import XCTest
@testable import FeaturePlayback

@MainActor
final class PlayerVideoZoomTests: XCTestCase {
    private let television = CGRect(x: 0, y: 0, width: 1920, height: 1080)

    func testZoomModeCopyUsesFamiliarNamesAndIdentifiesTheDefaultWithoutDescriptions() {
        XCTAssertEqual(PlayerVideoZoom().mode, .fit)
        XCTAssertEqual(PlayerVideoZoom.Mode.allCases.map { String(localized: $0.title) },
                       ["Normal", "Crop", "Stretch", "Custom", "Fit picture"])
        XCTAssertEqual(PlayerVideoZoom.Mode.allCases.map { String(localized: $0.menuTitle) },
                       ["Normal (Default)", "Crop", "Stretch", "Custom", "Fit picture"])
    }

    func testPictureFitUsesUniformScaleAndAsymmetricTranslation() throws {
        let normalized = CGRect(x: 0.05, y: 0.1, width: 0.8, height: 0.65)
        for (bounds, insets) in safeAreaCases {
            let safe = bounds.inset(by: insets)
            let zoom = PlayerVideoZoom(mode: .picture)
            let video = try XCTUnwrap(zoom.videoRect(
                in: bounds, aspectRatio: 16 / 9, fitBounds: safe, activePicture: normalized
            ))
            let active = VideoActivePictureGeometry.map(normalized, into: video)
            XCTAssertEqual(active.midX, safe.midX, accuracy: 0.001)
            XCTAssertEqual(active.midY, safe.midY, accuracy: 0.001)
            XCTAssertTrue(safe.insetBy(dx: -0.001, dy: -0.001).contains(active))
            XCTAssertEqual(video.width / video.height, 16 / 9, accuracy: 0.001)
            let scale = zoom.scaleFactors(in: bounds, aspectRatio: 16 / 9, fitBounds: safe, activePicture: normalized)
            XCTAssertEqual(scale.dx, scale.dy)
            XCTAssertLessThanOrEqual(scale.dx, 2)
        }
    }

    func testUnknownAndUnsafePictureGeometryUseNormalWithoutChangingManualModes() {
        for invalid: CGRect? in [nil, .zero, CGRect(x: 0, y: 0, width: 0.01, height: 0.01),
                                 CGRect(x: 0, y: 0, width: Double.nan, height: 1)] {
            XCTAssertEqual(PlayerVideoZoom(mode: .picture).videoRect(in: television, aspectRatio: 16 / 9, activePicture: invalid),
                           PlayerVideoZoom().videoRect(in: television, aspectRatio: 16 / 9))
        }
        for mode in [PlayerVideoZoom.Mode.fit, .fill, .stretch, .custom] {
            let zoom = PlayerVideoZoom(mode: mode)
            XCTAssertEqual(zoom.videoRect(in: television, aspectRatio: 16 / 9, activePicture: CGRect(x: 0, y: 0.1, width: 1, height: 0.8)),
                           zoom.videoRect(in: television, aspectRatio: 16 / 9))
        }
        let model = PlayerVideoZoomModel()
        XCTAssertFalse(model.availableModes.contains(.picture))
        model.supportsActivePicture = true
        XCTAssertTrue(model.availableModes.contains(.picture))
        XCTAssertEqual(model.settings.mode, .fit)
    }

    func testStretchFillsWithoutCroppingUnlikeTheProportionalModes() throws {
        let stretch = PlayerVideoZoom(mode: .stretch)
        XCTAssertEqual(stretch.videoRect(in: television, aspectRatio: 4 / 3), television)
        XCTAssertEqual(stretch.videoRect(in: television, aspectRatio: 2.4), television)
        let scale = stretch.scaleFactors(in: television, aspectRatio: 4 / 3)
        XCTAssertEqual(scale.dx, 4 / 3, accuracy: 0.0001)
        XCTAssertEqual(scale.dy, 1)
        let engine = ZoomVideoEngine()
        let surface = VideoPresentationView(frame: television)
        surface.attach(engine)
        surface.update(zoom: stretch)
        XCTAssertEqual(engine.output.bounds, television)
        XCTAssertEqual(engine.output.transform.a, 4 / 3, accuracy: 0.0001)
        XCTAssertEqual(engine.output.transform.d, 1)
        let originalPicture = CGRect(x: 240, y: 0, width: 1440, height: 1080)
        let transformed = engine.output.convert(originalPicture, to: surface)
        XCTAssertEqual(transformed.minX, television.minX, accuracy: 0.001)
        XCTAssertEqual(transformed.minY, television.minY, accuracy: 0.001)
        XCTAssertEqual(transformed.width, television.width, accuracy: 0.001)
        XCTAssertEqual(transformed.height, television.height, accuracy: 0.001)
        XCTAssertTrue(engine.transportCalls.isEmpty)
        surface.update(zoom: PlayerVideoZoom())
        XCTAssertEqual(engine.output.transform, .identity)
        XCTAssertEqual(engine.output.frame, television)
    }

    func testBitmapCanvasFollowsBothStretchAxes() {
        let bitmap = SubtitleOverlayGeometry.bitmapRect(
            normalizedRect: CGRect(x: 0.1, y: 0.8, width: 0.8, height: 0.1),
            canvasSize: CGSize(width: 800, height: 600),
            videoRect: television, sourceAspectRatio: 4 / 3
        )
        XCTAssertEqual(bitmap.minX, 192, accuracy: 0.0001)
        XCTAssertEqual(bitmap.minY, 864, accuracy: 0.0001)
        XCTAssertEqual(bitmap.width, 1536, accuracy: 0.0001)
        XCTAssertEqual(bitmap.height, 108, accuracy: 0.0001)
    }

    func testFitKeepsTheOriginalFrameAndFillCropsProportionally() throws {
        let fit = PlayerVideoZoom()
        XCTAssertEqual(fit.surfaceFrame(in: television, aspectRatio: 4 / 3), television)
        XCTAssertEqual(fit.videoRect(in: television, aspectRatio: 4 / 3),
                       CGRect(x: 240, y: 0, width: 1440, height: 1080))
        let fill = PlayerVideoZoom(mode: .fill)
        let frame = try XCTUnwrap(fill.videoRect(in: television, aspectRatio: 4 / 3))
        XCTAssertEqual(frame, CGRect(x: 0, y: -180, width: 1920, height: 1440))
        XCTAssertEqual(frame.width / frame.height, 4 / 3, accuracy: 0.0001)
        XCTAssertEqual(1 - television.height / frame.height, 0.25, accuracy: 0.0001)
        let cinema = try XCTUnwrap(fill.videoRect(in: television, aspectRatio: 2.4))
        XCTAssertEqual(cinema.height, television.height, accuracy: 0.001)
        XCTAssertEqual(cinema.width / cinema.height, 2.4, accuracy: 0.001)
        XCTAssertLessThan(cinema.minX, 0)
    }

    func testManualZoomCanRemoveEncodedBarsThatBasicFillLeaves() throws {
        let viewport = CGRect(x: 0, y: 0, width: 2622, height: 1206)
        // The issue's 16:9 raster contains a 2144 x 901 active picture.
        let activeFraction = CGRect(x: 0, y: 153.0 / 1206.0, width: 1, height: 901.0 / 1206.0)
        func picture(_ zoom: PlayerVideoZoom) throws -> CGRect {
            let raster = try XCTUnwrap(zoom.videoRect(in: viewport, aspectRatio: 16 / 9))
            return CGRect(x: raster.minX, y: raster.minY + activeFraction.minY * raster.height,
                          width: raster.width, height: raster.height * activeFraction.height)
        }
        let fill = try picture(PlayerVideoZoom(mode: .fill))
        XCTAssertGreaterThan(fill.minY, 50)
        XCTAssertLessThan(fill.maxY, viewport.maxY - 50)
        let custom = try picture(PlayerVideoZoom(mode: .custom, customPercent: 134))
        XCTAssertTrue(custom.contains(viewport))
    }

    func testZoomUsesTheCurrentViewportAndDisplayAspectAcrossRotation() throws {
        let zoom = PlayerVideoZoom(mode: .fill)
        let portrait = CGRect(x: 0, y: 0, width: 390, height: 844)
        let portraitVideo = try XCTUnwrap(zoom.videoRect(in: portrait, aspectRatio: 16 / 9))
        XCTAssertEqual(portraitVideo.height, 844, accuracy: 0.001)
        XCTAssertEqual(portraitVideo.midX, portrait.midX, accuracy: 0.001)
        let landscape = CGRect(x: 0, y: 0, width: 844, height: 390)
        let landscapeVideo = try XCTUnwrap(zoom.videoRect(in: landscape, aspectRatio: 16 / 9))
        XCTAssertEqual(landscapeVideo.width, 844, accuracy: 0.001)
        XCTAssertEqual(landscapeVideo.midY, landscape.midY, accuracy: 0.001)
        for ratio: Double? in [nil, 0, -.infinity, .nan] {
            XCTAssertNil(zoom.videoRect(in: landscape, aspectRatio: ratio))
            XCTAssertEqual(zoom.surfaceFrame(in: landscape, aspectRatio: ratio), landscape)
        }
        XCTAssertNil(zoom.videoRect(in: .zero, aspectRatio: 16 / 9))
    }

    func testNormalFitsTheWholePictureInsidePortraitLandscapeAndTabletSafeAreas() throws {
        for (bounds, insets) in safeAreaCases {
            let safe = bounds.inset(by: insets)
            for aspect: Double in [4 / 3, 16 / 9, 2.4, 9 / 16] {
                let normal = PlayerVideoZoom()
                let expected = try XCTUnwrap(SubtitleOverlayGeometry.aspectFitRect(
                    in: safe, aspectRatio: CGFloat(aspect)
                ))
                let picture = try XCTUnwrap(normal.videoRect(in: bounds, aspectRatio: aspect, fitBounds: safe))
                assertRect(picture, equals: expected)
                XCTAssertTrue(safe.insetBy(dx: -0.001, dy: -0.001).contains(picture))
                XCTAssertEqual(picture.width / picture.height, aspect, accuracy: 0.0001)
                let scale = normal.scaleFactors(in: bounds, aspectRatio: aspect, fitBounds: safe)
                XCTAssertEqual(scale.dx, scale.dy)
                XCTAssertLessThanOrEqual(scale.dx, 1.0001)
                XCTAssertEqual(picture.midX, safe.midX, accuracy: 0.0001)
                XCTAssertEqual(picture.midY, safe.midY, accuracy: 0.0001)

                let crop = PlayerVideoZoom(mode: .fill)
                let cropped = try XCTUnwrap(crop.videoRect(in: bounds, aspectRatio: aspect, fitBounds: safe))
                XCTAssertEqual(cropped, crop.videoRect(in: bounds, aspectRatio: aspect))
                XCTAssertTrue(cropped.insetBy(dx: -0.001, dy: -0.001).contains(bounds))
                XCTAssertEqual(cropped.width / cropped.height, aspect, accuracy: 0.0001)
                let stretch = PlayerVideoZoom(mode: .stretch)
                assertRect(try XCTUnwrap(stretch.videoRect(in: bounds, aspectRatio: aspect, fitBounds: safe)),
                           equals: bounds)
            }
        }
    }

    func testCustomRemainsRelativeToNormalOnlyWhenTheCallerOptsIntoSafeFitting() throws {
        for (bounds, insets) in safeAreaCases {
            let safe = bounds.inset(by: insets)
            let normal = try XCTUnwrap(PlayerVideoZoom().videoRect(
                in: bounds, aspectRatio: 16 / 9, fitBounds: safe
            ))
            for percent in [50, 100, 150, 200] {
                let zoom = PlayerVideoZoom(mode: .custom, customPercent: percent)
                let rect = try XCTUnwrap(zoom.videoRect(in: bounds, aspectRatio: 16 / 9, fitBounds: safe))
                XCTAssertEqual(rect.midX, normal.midX, accuracy: 0.0001)
                XCTAssertEqual(rect.midY, normal.midY, accuracy: 0.0001)
                XCTAssertEqual(rect.width, normal.width * CGFloat(percent) / 100, accuracy: 0.0001)
                XCTAssertEqual(rect.height, normal.height * CGFloat(percent) / 100, accuracy: 0.0001)
                XCTAssertEqual(zoom.videoRect(in: bounds, aspectRatio: 16 / 9),
                               zoom.videoRect(in: bounds, aspectRatio: 16 / 9, fitBounds: bounds))
            }
        }
    }

    func testSafeFittingUsesTheSameShiftAndScaleForAuthoredTextAndBitmapCues() throws {
        for (bounds, insets) in safeAreaCases {
            let safe = bounds.inset(by: insets)
            let picture = try XCTUnwrap(PlayerVideoZoom().videoRect(
                in: bounds, aspectRatio: 16 / 9, fitBounds: safe
            ))
            let expected = try XCTUnwrap(SubtitleOverlayGeometry.aspectFitRect(in: safe, aspectRatio: 16 / 9))
            let anchor = CGPoint(x: 0.2, y: 0.7)
            let origin = SubtitleOverlayGeometry.anchoredOrigin(
                anchor: anchor, alignment: .topLeft, contentSize: CGSize(width: 20, height: 10),
                videoRect: picture, limits: bounds
            )
            XCTAssertEqual(origin.x, expected.minX + anchor.x * expected.width, accuracy: 0.0001)
            XCTAssertEqual(origin.y, expected.minY + anchor.y * expected.height, accuracy: 0.0001)
            let bitmap = SubtitleOverlayGeometry.bitmapRect(
                normalizedRect: CGRect(x: anchor.x, y: anchor.y, width: 0.3, height: 0.1),
                canvasSize: CGSize(width: 1920, height: 1080), videoRect: picture
            )
            assertRect(bitmap, equals: CGRect(
                x: expected.minX + anchor.x * expected.width,
                y: expected.minY + anchor.y * expected.height,
                width: expected.width * 0.3, height: expected.height * 0.1
            ))
        }
    }

    func testMissingAspectAndInvalidSafeBoundsRemainFiniteAndPreserveLegacyDefaults() throws {
        let bounds = CGRect(x: 12, y: 20, width: 844, height: 390)
        let safe = bounds.inset(by: UIEdgeInsets(top: 9, left: 60, bottom: 21, right: 12))
        for aspect: Double? in [nil, 0, -.infinity, .nan] {
            let frame = PlayerVideoZoom().surfaceFrame(in: bounds, aspectRatio: aspect, fitBounds: safe)
            XCTAssertTrue(safe.insetBy(dx: -0.001, dy: -0.001).contains(frame))
            XCTAssertNil(PlayerVideoZoom().videoRect(in: bounds, aspectRatio: aspect, fitBounds: safe))
            XCTAssertEqual(PlayerVideoZoom().surfaceFrame(in: bounds, aspectRatio: aspect), bounds)
        }
        for invalid in [CGRect.zero, .null, .infinite, CGRect(x: -500, y: -500, width: 1, height: 1)] {
            XCTAssertEqual(PlayerVideoZoom().videoRect(in: bounds, aspectRatio: 16 / 9, fitBounds: invalid),
                           PlayerVideoZoom().videoRect(in: bounds, aspectRatio: 16 / 9))
        }
        assertRect(try XCTUnwrap(PlayerVideoZoom().videoRect(
            in: bounds, aspectRatio: 16 / 9, fitBounds: bounds.insetBy(dx: -30, dy: -40)
        )), equals: try XCTUnwrap(PlayerVideoZoom().videoRect(in: bounds, aspectRatio: 16 / 9)))
    }

    private var safeAreaCases: [(CGRect, UIEdgeInsets)] {
        [
            (CGRect(x: 0, y: 0, width: 390, height: 844),
             UIEdgeInsets(top: 59, left: 0, bottom: 34, right: 0)),
            (CGRect(x: 0, y: 0, width: 844, height: 390),
             UIEdgeInsets(top: 0, left: 59, bottom: 21, right: 0)),
            (CGRect(x: 0, y: 0, width: 844, height: 390),
             UIEdgeInsets(top: 0, left: 0, bottom: 21, right: 59)),
            (CGRect(x: 23, y: 41, width: 844, height: 390),
             UIEdgeInsets(top: 17, left: 63, bottom: 29, right: 11)),
            (CGRect(x: 0, y: 0, width: 1024, height: 1366), .zero),
            (CGRect(x: 0, y: 0, width: 1366, height: 1024),
             UIEdgeInsets(top: 24, left: 0, bottom: 20, right: 0))
        ]
    }

    private func assertRect(
        _ actual: CGRect, equals expected: CGRect, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(actual.minX, expected.minX, accuracy: 0.0001, file: file, line: line)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: 0.0001, file: file, line: line)
        XCTAssertEqual(actual.width, expected.width, accuracy: 0.0001, file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: 0.0001, file: file, line: line)
    }

    func testModeCyclingCustomBoundsAndIndependentSessions() {
        let first = PlayerVideoZoomModel()
        let second = PlayerVideoZoomModel()
        first.cycleMode(forward: true)
        XCTAssertEqual(first.settings.mode, .fill)
        first.cycleMode(forward: true)
        XCTAssertEqual(first.settings.mode, .stretch)
        first.cycleMode(forward: true)
        XCTAssertEqual(first.settings.mode, .custom)
        first.setCustomPercent(134)
        first.cycleMode(forward: true)
        XCTAssertEqual(first.settings.mode, .fit)
        first.cycleMode(forward: false)
        XCTAssertEqual(first.settings, PlayerVideoZoom(mode: .custom, customPercent: 134))
        first.setCustomPercent(999)
        XCTAssertEqual(first.settings.customPercent, 200)
        first.setCustomPercent(-1)
        XCTAssertEqual(first.settings.customPercent, 50)
        XCTAssertEqual(second.settings, PlayerVideoZoom())
    }

    func testInlineSpeedAndZoomSubmenuUseTheSharedSubtitleRowKinds() throws {
        let model = PlayerControlsModel()
        model.engineCapabilities = [.videoZoom, .playbackSpeed]
        model.playbackSpeed = 1.5
        var opened: [PlayerControls.PlaybackScreen] = []
        let actions = PlayerOptionsActions(setPlaybackSpeed: { model.playbackSpeed = $0 })
        let rows = PlaybackOptionsPane.rows(model: model, zoom: model.videoZoom, actions: actions) { opened.append($0) }
        XCTAssertEqual(rows.map(\.slot), [PlaybackOptionsPane.zoomSlot, PlaybackOptionsPane.speedSlot])
        guard case let .submenu(_, open) = rows[0].kind else {
            return XCTFail("Zoom must open a normal submenu.")
        }
        open()
        XCTAssertEqual(opened, [.zoom])
        XCTAssertEqual(model.videoZoom.settings.mode, .fit)
        guard case let .number(_, changeSpeed) = rows[1].kind else {
            return XCTFail("Speed must use the existing inline numeric row.")
        }
        changeSpeed(1)
        XCTAssertEqual(model.playbackSpeed, 1.55)
        changeSpeed(-1)
        XCTAssertEqual(model.playbackSpeed, 1.5)
        changeSpeed(100)
        XCTAssertEqual(model.playbackSpeed, 2)
        changeSpeed(-100)
        XCTAssertEqual(model.playbackSpeed, 0.25)
        let choices = PlaybackOptionsPane.rows(
            model: model, zoom: model.videoZoom, actions: actions, screen: .zoom, openScreen: { opened.append($0) }
        )
        XCTAssertEqual(choices.map(\.slot), [PlaybackOptionsPane.customSlot])
        guard case let .number(_, step) = choices[0].kind else {
            return XCTFail("Custom must adjust directly on the Zoom Mode screen.")
        }
        step(-10)
        XCTAssertEqual(model.videoZoom.settings, PlayerVideoZoom(mode: .custom, customPercent: 90))
        XCTAssertTrue(PlaybackOptionsPane.rows(
            model: model, zoom: model.videoZoom, actions: actions, screen: .zoom, openScreen: { _ in }
        )[0].isSelected)
        XCTAssertEqual(opened, [.zoom], "Adjusting Custom must not open another screen.")
        step(10)
        step(34)
        XCTAssertEqual(model.videoZoom.settings.customPercent, 134)
        XCTAssertEqual(PlaybackOptionsPane.rows(
            model: model, zoom: model.videoZoom, actions: actions, openScreen: { _ in }
        ).map(\.slot), [0, 2], "Custom zoom must never add a third parent row.")
        let live = PlaybackOptionsPane.rows(
            model: model, zoom: model.videoZoom, actions: actions, offersPlaybackSpeed: false, openScreen: { _ in }
        )
        XCTAssertEqual(live.map(\.slot), [0])
    }

    func testCapabilityGatesAndSelectedSpeedFocus() {
        let model = controlsWithoutSystemAudio()
        model.engineCapabilities = [.videoZoom]
        XCTAssertEqual(model.trackControlCategories, [.playback])
        XCTAssertEqual(PlayerOptionsPanel.preferredFocus(
            for: .playback, subtitleScreen: .tracks, model: model
        ), .row(PlaybackOptionsPane.zoomSlot))
        model.engineCapabilities = [.playbackSpeed]
        XCTAssertEqual(PlayerOptionsPanel.preferredFocus(
            for: .playback, subtitleScreen: .tracks, model: model
        ), .row(PlaybackOptionsPane.speedSlot))
        model.videoZoom.settings.mode = .custom
        XCTAssertEqual(PlayerOptionsPanel.preferredFocus(
            for: .playback, subtitleScreen: .tracks, model: model, playbackScreen: .zoom
        ), .row(PlaybackOptionsPane.customSlot))
        XCTAssertEqual(PlayerControls.PlaybackScreen.zoom.parent, .options)
        model.engineCapabilities = []
        XCTAssertTrue(model.trackControlCategories.isEmpty)
        XCTAssertTrue(PlaybackOptionsPane.rows(
            model: model, zoom: model.videoZoom, actions: PlayerOptionsActions(), openScreen: { _ in }
        ).isEmpty)
    }

    func testVideoSurfaceChangesWithoutResizingOverlaysOrRestartingTheEngine() throws {
        let engine = ZoomVideoEngine()
        let parent = UIView(frame: television)
        let host = VideoPresentationView(frame: television)
        let overlay = UIView(frame: television)
        parent.addSubview(host)
        parent.addSubview(overlay)
        host.attach(engine)
        host.update(zoom: PlayerVideoZoom())
        host.layoutIfNeeded()
        let original = engine.output.layer
        host.update(zoom: PlayerVideoZoom(mode: .fill))
        XCTAssertEqual(host.frame, television)
        XCTAssertEqual(overlay.frame, television)
        XCTAssertEqual(engine.output.frame, CGRect(x: -320, y: -180, width: 2560, height: 1440))
        XCTAssertEqual(host.videoRect, CGRect(x: 0, y: -180, width: 1920, height: 1440))
        XCTAssertTrue(host.clipsToBounds)
        XCTAssertTrue(engine.output.layer === original)
        XCTAssertEqual(engine.surfaceRequests, 1)
        XCTAssertTrue(engine.transportCalls.isEmpty)
        engine.videoAspectRatio = 16 / 9
        host.update(zoom: PlayerVideoZoom(mode: .fill))
        XCTAssertEqual(engine.output.frame, television)
        host.update(zoom: PlayerVideoZoom(mode: .custom, customPercent: 150))
        XCTAssertEqual(engine.output.frame.size, CGSize(width: 2880, height: 1620))
        host.update(zoom: PlayerVideoZoom())
        XCTAssertEqual(engine.output.frame, television)
        XCTAssertTrue(engine.transportCalls.isEmpty)
    }

    func testZoomOutInsetsThePictureWithoutInvertingIt() throws {
        let zoom = PlayerVideoZoom(mode: .custom, customPercent: 90)
        XCTAssertEqual(zoom.surfaceFrame(in: television, aspectRatio: 16 / 9),
                       CGRect(x: 96, y: 54, width: 1728, height: 972))
        XCTAssertEqual(zoom.videoRect(in: television, aspectRatio: 16 / 9),
                       CGRect(x: 96, y: 54, width: 1728, height: 972))
        let smallest = try XCTUnwrap(PlayerVideoZoom(mode: .custom, customPercent: -100)
            .videoRect(in: television, aspectRatio: 4 / 3))
        XCTAssertGreaterThan(smallest.width, 0)
        XCTAssertGreaterThan(smallest.height, 0)
        XCTAssertEqual(smallest.midX, television.midX)
        XCTAssertEqual(smallest.midY, television.midY)
        XCTAssertEqual(smallest.width / smallest.height, 4 / 3, accuracy: 0.0001)
    }

    func testRetiredVideoHostDoesNotResizeASurfaceAdoptedByAnotherHost() {
        let engine = ZoomVideoEngine()
        let retired = VideoPresentationView(frame: television)
        retired.attach(engine)
        let current = VideoPresentationView(frame: CGRect(x: 0, y: 0, width: 844, height: 390))
        current.attach(engine)
        current.layoutIfNeeded()
        let frame = engine.output.frame
        retired.update(zoom: PlayerVideoZoom(mode: .custom, customPercent: 200))
        retired.layoutIfNeeded()
        XCTAssertTrue(engine.output.superview === current)
        XCTAssertEqual(engine.output.frame, frame)
    }

    #if os(tvOS)
    func testSafeAreaFittingOptInIsInertOnTelevision() throws {
        let controller = UIViewController()
        controller.additionalSafeAreaInsets = UIEdgeInsets(top: 20, left: 60, bottom: 40, right: 10)
        controller.view.frame = television
        let video = VideoPresentationView(frame: television)
        controller.view.addSubview(video)
        let engine = ZoomVideoEngine()
        video.attach(engine)
        video.update(zoom: PlayerVideoZoom(), fitsInsideSafeArea: true)
        video.layoutIfNeeded()
        XCTAssertNil(video.fitBounds)
        XCTAssertEqual(video.videoRect, PlayerVideoZoom().videoRect(in: television, aspectRatio: 4 / 3))
        XCTAssertEqual(engine.output.frame, television)
        XCTAssertTrue(engine.transportCalls.isEmpty)
    }
    #endif
}

@MainActor
private final class ZoomVideoEngine: VideoEngine {
    let output = UIView()
    var videoAspectRatio: Double? = 4 / 3
    var surfaceRequests = 0
    var transportCalls: [String] = []
    var status: VideoEngineStatus = .ready
    var isPaused = true
    var currentTime: TimeInterval = 10
    var duration: TimeInterval = 100
    var furthestObservedPosition: TimeInterval = 10
    var audioTracks: [MediaTrack] = []
    var subtitleTracks: [MediaTrack] = []
    var onProgress: (@MainActor () -> Void)?
    var onFailure: (@MainActor (AppError) -> Void)?
    var onEnded: (@MainActor () -> Void)?
    var onTracksChanged: (@MainActor () -> Void)?
    var onProbedSourceFactsChanged: (@MainActor (EngineProbedSourceFacts) -> Void)?
    var onSubtitleCues: (@MainActor ([SubtitleCue]) -> Void)?
    var onSecondarySubtitleCues: (@MainActor ([SubtitleCue]) -> Void)?
    func load(request: PlaybackRequest, startPosition: TimeInterval) async { transportCalls.append("load") }
    func play() { transportCalls.append("play") }
    func pause() { transportCalls.append("pause") }
    func stop() { transportCalls.append("stop") }
    func seek(to seconds: TimeInterval) async { transportCalls.append("seek") }
    func selectAudioTrack(_ track: MediaTrack?) {}
    func selectSubtitleTrack(_ track: MediaTrack?) {}
    func makeVideoOutputView() -> UIView { surfaceRequests += 1; return output }
}
#endif
