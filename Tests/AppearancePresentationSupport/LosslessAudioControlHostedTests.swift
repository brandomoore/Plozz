import CoreModels
import CoreUI
import FeatureSettings
import SwiftUI
import UIKit
import Vision
import XCTest

@MainActor
final class LosslessAudioControlHostedTests: XCTestCase {
    func testShortLabelAndTradeoffFitAtDefaultAndLargeTextSizes() async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !UIApplication.shared.connectedScenes.contains(where: { $0.activationState == .foregroundActive }),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let suite = "LosslessAudioControlHostedTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #if os(tvOS)
        let sizes: [(CGSize, DynamicTypeSize)] = [
            (.init(width: 1100, height: 400), .large),
            (.init(width: 760, height: 600), .accessibility3)
        ]
        #else
        let sizes: [(CGSize, DynamicTypeSize)] = [
            (.init(width: 320, height: 320), .large),
            (.init(width: 390, height: 440), .accessibility3),
            (.init(width: 768, height: 320), .large)
        ]
        #endif
        for (size, typeSize) in sizes {
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(origin: .zero, size: size)
            window.rootViewController = UIHostingController(rootView:
                LosslessAudioControl(defaults: defaults)
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .toggleStyle(SettingsSwitchToggleStyle())
                    .environment(\.dynamicTypeSize, typeSize)
                    .environment(\.themePalette, .dark)
                    .environment(\.colorScheme, .dark)
                    .environment(\.locale, Locale(identifier: "en_US"))
                    .background(.black)
            )
            window.makeKeyAndVisible()
            defer {
                window.isHidden = true
                window.rootViewController = nil
                previous?.makeKeyAndVisible()
            }
            try await Task.sleep(for: .milliseconds(250))
            window.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = "Lossless surround toggle \(Int(size.width)) \(typeSize)"
            attachment.lifetime = .keepAlways
            add(attachment)
            let recognition = VNRecognizeTextRequest()
            recognition.recognitionLevel = .accurate
            recognition.recognitionLanguages = ["en-US"]
            try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([recognition])
            let text = (recognition.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: " ")
            XCTAssertTrue(text.contains("Prefer lossless audio"), text)
            XCTAssertTrue(text.contains("Turn off for surround sound over regular HDMI ARC"), text)
            XCTAssertTrue(text.contains("which requires compressed audio"), text)
            XCTAssertFalse(text.contains("…"), text)
            XCTAssertTrue(LosslessAudioSettingsStore(defaults: defaults).load())
            #if os(iOS)
            let control = try XCTUnwrap(nativeSwitch(in: window))
            let controlBounds = control.convert(control.bounds, to: window)
            XCTAssertTrue(window.bounds.contains(controlBounds), "\(controlBounds)")
            let hit = window.hitTest(CGPoint(x: controlBounds.midX, y: controlBounds.midY), with: nil)
            XCTAssertTrue(hit === control || hit?.isDescendant(of: control) == true)
            for enabled in [false, true] {
                control.setOn(enabled, animated: false)
                control.sendActions(for: .valueChanged)
                try await Task.sleep(for: .milliseconds(100))
                XCTAssertEqual(LosslessAudioSettingsStore(defaults: defaults).load(), enabled)
            }
            #endif
        }
    }

    #if os(iOS)
    private func nativeSwitch(in view: UIView) -> UISwitch? {
        if let control = view as? UISwitch { return control }
        return view.subviews.lazy.compactMap { self.nativeSwitch(in: $0) }.first
    }
    #endif
}
