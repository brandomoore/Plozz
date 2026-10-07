import CoreImage
import CoreUI
import FeatureAuth
import Observation
import SwiftUI
import UIKit
import XCTest

@MainActor
final class QRCodePresentationTests: XCTestCase {
    func testReplacingPayloadAndThemeNeverLeavesTheOldCodeVisible() async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !UIApplication.shared.connectedScenes.contains(where: { $0.activationState == .foregroundActive }),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let state = QRPresentationState()
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 640, height: 480)
        window.rootViewController = UIHostingController(rootView: QRPresentationFixture(state: state))
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        try await assertPayload(state.payload, in: window)
        for branded in [false, true] {
            for dark in [false, true] {
                state.branded = branded
                state.dark = dark
                state.payload = "https://example.test/obsolete"
                await Task.yield()
                state.payload = "https://example.test/current-\(branded)-\(dark)"
                try await assertPayload(state.payload, in: window)
            }
        }
    }

    private func assertPayload(_ expected: String, in window: UIWindow) async throws {
        // The simulator's first Core Image/QR detector initialization can take
        // several seconds. Wait for decoded pixels, not a fixed startup sleep.
        let deadline = ContinuousClock.now + .seconds(15)
        var payloads: [String] = []
        repeat {
            window.layoutIfNeeded()
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let bitmap = try XCTUnwrap(image.cgImage)
            payloads = await Task.detached {
                let detector = CIDetector(
                    ofType: CIDetectorTypeQRCode, context: nil,
                    options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]
                )
                let input = CIImage(cgImage: bitmap)
                return [input, input.applyingFilter("CIColorInvert")].flatMap {
                    (detector?.features(in: $0) ?? []).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
                }
            }.value
            if Set(payloads) == [expected] { return }
            if ContinuousClock.now >= deadline {
                let attachment = XCTAttachment(image: image)
                attachment.name = "qr-payload-not-ready"
                attachment.lifetime = .keepAlways
                add(attachment)
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        } while true
        XCTAssertEqual(Set(payloads), [expected])
    }
}

@MainActor
@Observable
private final class QRPresentationState {
    var payload = "https://example.test/initial"
    var dark = false
    var branded = false
}

private struct QRPresentationFixture: View {
    let state: QRPresentationState

    var body: some View {
        Group {
            if state.branded {
                BrandQRCodeView(payload: state.payload, size: 280)
            } else {
                QRCodeView(state.payload).frame(width: 280, height: 280)
            }
        }
        .environment(\.themePalette, state.dark ? .dark : .light)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(state.dark && state.branded ? Color.black : Color.white)
    }
}
