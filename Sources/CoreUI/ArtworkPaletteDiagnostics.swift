#if canImport(UIKit)
import CoreModels
import CryptoKit
import SwiftUI
import UIKit

/// Opt-in evidence for the image-to-palette chain, using the existing hero-art trace.
public enum ArtworkPaletteDiagnostics {
    private actor Worker {
        func record(_ image: UIImage, reference: ArtworkReference, id: String, event: String, time: TimeInterval) {
            let palette = ArtworkColorExtractor.palette(from: image, maxColors: 4)
            HeroArtDiagnostics.emit(
                "palette hero event=\(event) at=\(time) item=\(HandoffDiagnostics.correlationID(id)) "
                + "reference=\(referenceID(reference)) \(imageSummary(image)) colors=\(colors(palette))"
            )
        }
    }
    private static let worker = Worker()

    public static func displayed(_ image: UIImage, reference: ArtworkReference, id: String, event: String) {
        guard HeroArtDiagnostics.isEnabled else { return }
        let time = ProcessInfo.processInfo.systemUptime
        Task { await worker.record(image, reference: reference, id: id, event: event, time: time) }
    }

    static func referenceID(_ reference: ArtworkReference) -> String {
        HandoffDiagnostics.correlationID(reference.privacySafeIdentity)
    }

    static func keyID(_ key: AmbientArtworkKey?) -> String {
        guard let key else { return "none" }
        return HandoffDiagnostics.correlationID(
            key.id + "|" + key.reference.privacySafeIdentity + "|" + key.variant.rawValue
        )
    }

    static func colors(_ colors: [Color]?) -> String {
        guard let colors else { return "none" }
        return "[" + colors.map { color in
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            guard UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a) else { return "unresolved" }
            return String(format: "(%.4f,%.4f,%.4f,%.4f)", Double(r), Double(g), Double(b), Double(a))
        }.joined(separator: ",") + "]"
    }

    // Called only off the main actor, and only while tracing. No full-image encoding.
    static func imageSummary(_ image: UIImage) -> String { // l10n:content - developer-facing artwork trace, not UI copy.
        guard let cgImage = image.cgImage else { return "pixels=unavailable" }
        let size = 24
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(
                    data: buffer.baseAddress, width: size, height: size,
                    bitsPerComponent: 8, bytesPerRow: size * 4, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: size, height: size))
            return true
        }
        guard drawn else { return "pixels=unavailable" }
        let fingerprint = SHA256.hash(data: Data(pixels)).prefix(8)
            .map { String(format: "%02x", $0) }.joined()
        return "pixels=\(fingerprint) size=\(cgImage.width)x\(cgImage.height)"
    }
}
#endif
