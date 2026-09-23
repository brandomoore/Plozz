#if os(iOS)
import CoreModels
import CoreUI
import SwiftUI
import UIKit
import Vision
import XCTest

@MainActor
final class ServerSetupPresentationTests: XCTestCase {
    func testTransferButtonRemainsReadableWithSettingsForegroundInEveryTheme() async throws {
        let descriptor = SyncedAccountDescriptor(
            id: "share", provider: .mediaShare, serverID: "files",
            serverName: "Documents (WebDAV)", userID: "viewer", userName: "Viewer",
            candidateBaseURLs: [URL(string: "https://files.example.test/Documents")!],
            originDeviceName: "Test TV", originDeviceKind: "tv"
        )
        for (name, palette) in [("dark", ThemePalette.dark), ("black", .pureBlack), ("light", .light)] {
            let image = try await render(
                SyncedServerSetupPrompt(
                    descriptor: descriptor, palette: palette,
                    onSignIn: {}, onUseOtherDevice: {}, onNotNow: {}
                )
                .foregroundStyle(palette.primaryText)
                .environment(\.themePalette, palette)
                .background(palette.cardSurface),
                size: CGSize(width: 390, height: 430), light: palette.isLight
            )
            let text = try recognize(image).joined(separator: " ")
            XCTAssertTrue(text.contains("Auto Sign In"), "\(name): \(text)")
            XCTAssertTrue(text.contains("Sign In Manually"), "\(name): \(text)")
            XCTAssertTrue(text.contains("Not Now"), "\(name): \(text)")
            attach(image, name: "Server setup - \(name)")
        }
    }

    func testProviderPickerNeverUsesIntrinsicLogoSizeInNativeForm() async throws {
        for provider in [ProviderKind.jellyfin, .emby, .plex, .silo] {
            let image = try await render(
                Form {
                    Section { ManagedProviderPicker(provider: .constant(provider)) }
                }
                .environment(\.themePalette, ThemePalette.dark),
                size: CGSize(width: 390, height: 500), light: false
            )
            let text = try recognize(image).joined(separator: " ")
            XCTAssertTrue(text.contains("Provider"), text)
            XCTAssertTrue(text.contains(provider.displayName), text)
            let pixels = try rgba(image)
            var coloredRows: [Int] = []
            for y in 0..<image.height {
                for x in 0..<image.width {
                    let i = (y * image.width + x) * 4
                    let channels = [Int(pixels[i]), Int(pixels[i + 1]), Int(pixels[i + 2])]
                    if channels.max()! - channels.min()! > 70 {
                        coloredRows.append(y)
                        break
                    }
                }
            }
            let first = try XCTUnwrap(coloredRows.first, "The provider logo must remain visible.")
            let last = try XCTUnwrap(coloredRows.last)
            let heightInPoints = CGFloat(last - first + 1) / (CGFloat(image.width) / 390)
            XCTAssertLessThanOrEqual(heightInPoints, 26, "\(provider): oversized provider logo")
            XCTAssertGreaterThan(heightInPoints, 4)
            attach(image, name: "Provider picker - \(provider.rawValue)")
        }
    }

    func testWebDAVCutoutHasNoRectangularPixelsOutsideItsCircle() throws {
        let renderer = ImageRenderer(content:
            ProviderBrandMark(provider: .mediaShare, size: 76, mediaShareTransport: .webDAV)
        )
        renderer.scale = 3
        renderer.isOpaque = false
        let image = try XCTUnwrap(renderer.cgImage)
        let pixels = try rgba(image)
        let center = Double(image.width) / 2
        var leakedPixels = 0
        for y in 0..<image.height {
            for x in 0..<image.width {
                let distance = hypot(Double(x) + 0.5 - center, Double(y) + 0.5 - center)
                if distance > center + 2, pixels[(y * image.width + x) * 4 + 3] > 2 {
                    leakedPixels += 1
                }
            }
        }
        XCTAssertEqual(leakedPixels, 0, "The cutout must not draw a rectangle beyond the circular badge.")
    }

    func testSiloBadgeBackgroundMatchesTheOtherProvidersEmphasis() throws {
        let providers: [ProviderKind] = [.jellyfin, .plex, .emby, .mediaShare, .silo]
        for palette in [ThemePalette.dark, .pureBlack] {
            var luminances: [ProviderKind: Double] = [:]
            for provider in providers {
                let renderer = ImageRenderer(content:
                    ProviderBrandMark(provider: provider, size: 76)
                        .background(palette.cardSurface)
                )
                renderer.scale = 3
                let image = try XCTUnwrap(renderer.cgImage)
                let bytes = try rgba(image)
                let index = ((image.height / 10) * image.width + image.width / 2) * 4
                let components = (0..<3).map { channel -> Double in
                    let value = Double(bytes[index + channel]) / 255
                    return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
                }
                luminances[provider] = components[0] * 0.2126
                    + components[1] * 0.7152 + components[2] * 0.0722
            }
            let silo = try XCTUnwrap(luminances[.silo])
            let peers = providers.filter { $0 != .silo }.compactMap { luminances[$0] }
            XCTAssertLessThanOrEqual(silo, try XCTUnwrap(peers.max()) + 0.02)
            XCTAssertGreaterThanOrEqual(silo, max(0, try XCTUnwrap(peers.min()) - 0.02))
            let strip = ImageRenderer(content:
                HStack(spacing: 16) {
                    ForEach(providers, id: \.self) { provider in
                        ProviderBrandMark(provider: provider, size: 56)
                    }
                }
                .padding(16)
                .background(palette.cardSurface)
            )
            strip.scale = 3
            attach(try XCTUnwrap(strip.cgImage), name: "Provider background comparison")
        }
    }

    private func render<Content: View>(
        _ content: Content, size: CGSize, light: Bool
    ) async throws -> CGImage {
        let deadline = ContinuousClock.now + .seconds(5)
        while !UIApplication.shared.connectedScenes.contains(where: { $0.activationState == .foregroundActive }),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        let host = UIHostingController(rootView: content.environment(\.locale, Locale(identifier: "en_US")))
        host.overrideUserInterfaceStyle = light ? .light : .dark
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
        return try XCTUnwrap(image.cgImage)
    }

    private func recognize(_ image: CGImage) throws -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    }

    private func rgba(_ image: CGImage) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(
                data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }

    private func attach(_ image: CGImage, name: String) {
        let attachment = XCTAttachment(image: UIImage(cgImage: image))
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
#endif
