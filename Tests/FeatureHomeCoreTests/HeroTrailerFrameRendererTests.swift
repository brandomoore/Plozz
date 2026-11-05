#if canImport(AVFoundation)
import CoreImage
import XCTest
@testable import FeatureHomeCore

@MainActor
final class HeroTrailerFrameRendererTests: XCTestCase {
    func testIdleControllerAndEmptyHandoffDoNotInitializeCoreImage() async {
        let controller = HeroTrailerController()
        let initial = await controller.handoffRenderer.contextIdentity
        XCTAssertNil(initial)
        await controller.captureHandoffFrame()
        controller.stop()
        let afterStop = await controller.handoffRenderer.contextIdentity
        XCTAssertNil(afterStop)
        XCTAssertNil(controller.handoffImage)
    }

    func testActualFrameInitializesAndReusesContext() async throws {
        let renderer = HeroTrailerFrameRenderer()
        let image = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 16, height: 12))
        let firstResult = await renderer.render(image)
        let first = try XCTUnwrap(firstResult)
        XCTAssertEqual(first.width, 16)
        XCTAssertEqual(first.height, 12)
        let firstContext = await renderer.contextIdentity
        XCTAssertNotNil(firstContext)
        let secondResult = await renderer.render(image)
        let second = try XCTUnwrap(secondResult)
        let secondContext = await renderer.contextIdentity
        XCTAssertEqual(firstContext, secondContext)
        XCTAssertEqual(first.dataProvider?.data as Data?, second.dataProvider?.data as Data?)
    }
}
#endif
