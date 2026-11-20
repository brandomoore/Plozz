import UIKit
import Vision
import XCTest

enum HeroTextInk {
    static func frames(in image: UIImage, terms: [String], darkTerms: Set<String> = []) throws -> [String: CGRect] {
        let full = try XCTUnwrap(image.cgImage)
        let crop = try XCTUnwrap(full.cropping(to: CGRect(
            x: 0, y: 0, width: min(CGFloat(full.width), 1000 * image.scale), height: CGFloat(full.height)
        )))
        let request = VNRecognizeTextRequest()
        request.recognitionLanguages = ["en-US"]
        request.minimumTextHeight = 0.005
        try VNImageRequestHandler(cgImage: crop).perform([request])
        var pixels = [UInt8](repeating: 0, count: crop.width * crop.height * 4)
        try pixels.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(
                data: bytes.baseAddress, width: crop.width, height: crop.height, bitsPerComponent: 8,
                bytesPerRow: crop.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ))
            context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
        }
        // Vision occasionally splits the leading glyph of a native button into a
        // bullet and misreads "Play" as "Plav" at some sizes; the rendered pixels
        // are the evidence, so accept the known OCR variant for matching.
        let aliases: [String: [String]] = ["Play": ["Plav"]]
        return try Dictionary(uniqueKeysWithValues: terms.map { term in
            let spellings = [term] + (aliases[term] ?? [])
            let match = try XCTUnwrap(request.results?.compactMap { observation -> (VNRecognizedTextObservation, String)? in
                guard let text = observation.topCandidates(1).first else { return nil }
                guard let spelling = spellings.first(where: {
                    text.string.localizedCaseInsensitiveContains($0)
                }) else { return nil }
                return (observation, spelling)
            }.first, "Missing \(term): \(request.results?.compactMap { $0.topCandidates(1).first?.string } ?? [])")
            let observation = match.0
            let text = try XCTUnwrap(observation.topCandidates(1).first)
            let range = try XCTUnwrap(text.string.range(of: match.1, options: .caseInsensitive))
            let box = try XCTUnwrap(text.boundingBox(for: range)).boundingBox
            // Character estimates can miss the baseline; the detected line owns vertical bounds.
            let recognized = CGRect(
                x: box.minX * CGFloat(crop.width), y: (1 - observation.boundingBox.maxY) * CGFloat(crop.height),
                width: box.width * CGFloat(crop.width), height: observation.boundingBox.height * CGFloat(crop.height)
            )
            // Exclude adjacent badge borders from Vision's loose substring bounds.
            let rect = recognized.insetBy(dx: recognized.width * 0.1, dy: -2 * image.scale)
            var ink = CGRect.null
            for y in max(0, Int(rect.minY))..<min(crop.height, Int(ceil(rect.maxY))) {
                for x in max(0, Int(rect.minX))..<min(crop.width, Int(ceil(rect.maxX))) {
                    let offset = (y * crop.width + x) * 4
                    let matches = darkTerms.contains(term)
                        ? pixels[offset] < 72 && pixels[offset + 1] < 72 && pixels[offset + 2] < 72
                        : pixels[offset] > 72 && pixels[offset + 1] > 72 && pixels[offset + 2] > 72
                    if matches {
                        ink = ink.union(CGRect(x: x, y: y, width: 1, height: 1))
                    }
                }
            }
            _ = try XCTUnwrap(ink.isNull ? nil : ink, "Missing rendered glyphs for \(term) inside \(rect)")
            return (term, CGRect(
                x: ink.minX / image.scale, y: ink.minY / image.scale,
                width: ink.width / image.scale, height: ink.height / image.scale
            ))
        })
    }
}
