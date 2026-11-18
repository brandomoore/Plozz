// Adapted from brandomoore/Mozz at 58dab0015d09a4978f2c484e072d1bc0e30f69dc.
// Copyright (C) 2026 Mozz contributors. GPL-3.0-only with Apple distribution permission.
// See Mozz-NOTICE.txt. Plozz adapters retain the original player motion and geometry.
#if os(iOS)
import Foundation

/// Turning a piece of artwork into the colours the player paints behind it.
///
/// The *decoding* of an image is irreducibly platform work — UIKit has one image
/// decoder, Android has another, and swift-corelibs-foundation has none at all —
/// so each client downscales its own artwork and hands the raw pixels here.
/// Everything after that is arithmetic, and arithmetic belongs in one place.
///
/// This matters more than it looks. The constants below are not implementation
/// detail; they *are* the design. How hard vibrancy is rewarded, how far accents
/// are pulled toward the dominant colour, how bright a tone may get before white
/// text stops being legible on it — get those different on two platforms and the
/// same album has two different moods depending on which device you picked up.
public enum PlayerArtworkPalette {

    // MARK: Tuning

    public enum Tuning {
        /// Resolution the artwork should be downscaled to before it gets here.
        /// 48×48 ≈ 2.3k pixels: plenty to characterise a cover, cheap to run.
        public static let sampleDim = 48
        /// Most prominent colours to pull out.
        public static let maxColors = 5
        /// Minimum RGB distance between chosen colours, so the palette spans the
        /// art (blue AND red) rather than five shades of one hue.
        public static let minSeparation: Double = 0.22
        /// Vibrancy reward: multiplier = base + saturation × gain.
        public static let vibrancyBase: Double = 0.35
        public static let vibrancyGain: Double = 1.4
        /// Coverage weight is `count^exp` — sublinear, so a big flat area cannot
        /// completely bury a smaller vivid one.
        public static let coverageExponent: Double = 0.65
        /// How hard the luminance extremes are pushed down; their hue barely
        /// registers.
        public static let luminanceFalloff: Double = 1.5
        public static let luminanceFloor: Double = 0.18

        /// Light saturation lift on the final tones.
        public static let saturationBoost: Double = 1.1
        public static let minBrightness: Double = 0.14
        /// Capped so white title and artist text stays legible over the middle of
        /// the screen — every Mozz client overlays text directly on this.
        public static let maxBrightness: Double = 0.58
        /// How far the accents are pulled toward the dominant colour, so a phone
        /// reads as one cohesive wash with gentle accents rather than several
        /// gradients competing. 0 = full-strength accents; 1 = one flat colour.
        public static let dominantCohesion: Double = 0.45
    }

    // MARK: Output

    /// A colour in the 0...1 sRGB space, which every client can turn into its own.
    public struct Tone: Sendable, Equatable, Codable {
        public var red: Double
        public var green: Double
        public var blue: Double

        public init(red: Double, green: Double, blue: Double) {
            self.red = red
            self.green = green
            self.blue = blue
        }
    }

    /// The backdrop, top to bottom. The middle band is the dominant colour and
    /// covers most of the screen; the two accents are gentle bands at the edges.
    public struct Tones: Sendable, Equatable, Codable {
        public var top: Tone
        public var middle: Tone
        public var bottom: Tone
    }

    // MARK: Extraction

    /// Derive the backdrop from raw pixels.
    ///
    /// `pixels` is tightly packed RGBA, 8 bits per channel, `width * height * 4`
    /// bytes. Returns nil when there is nothing usable to sample — an entirely
    /// transparent image, or no pixels at all — and the caller should fall back
    /// to a plain background rather than invent colours.
    public static func tones(rgba pixels: [UInt8], width: Int, height: Int) -> Tones? {
        guard width > 0, height > 0, pixels.count >= width * height * 4 else { return nil }
        let palette = prominent(rgba: pixels, width: width, height: height)
        guard let dominant = palette.first else { return nil }

        func accent(_ index: Int) -> RGB {
            let base = index < palette.count ? palette[index] : dominant
            return blend(base, toward: dominant, amount: Tuning.dominantCohesion)
        }

        return Tones(
            top: backdropAdjusted(accent(1)),
            middle: backdropAdjusted(dominant),
            bottom: backdropAdjusted(accent(2))
        )
    }

    // MARK: - Internals

    struct RGB { var r: Double; var g: Double; var b: Double }

    static func prominent(rgba pixels: [UInt8], width: Int, height: Int) -> [RGB] {
        struct Bucket { var count = 0.0; var r = 0.0; var g = 0.0; var b = 0.0 }
        var buckets: [Int: Bucket] = [:]
        buckets.reserveCapacity(512)

        var index = 0
        let total = width * height * 4
        while index < total {
            // Skip near-transparent pixels: a cover's rounded corners should not
            // vote for whatever is behind them.
            if pixels[index + 3] > 24 {
                let r = Int(pixels[index]), g = Int(pixels[index + 1]), b = Int(pixels[index + 2])
                // Quantise to 5 bits per channel so near-identical colours merge,
                // then average back to the true value within the bucket.
                let key = (r >> 3) << 10 | (g >> 3) << 5 | (b >> 3)
                var bucket = buckets[key] ?? Bucket()
                bucket.count += 1
                bucket.r += Double(r) / 255
                bucket.g += Double(g) / 255
                bucket.b += Double(b) / 255
                buckets[key] = bucket
            }
            index += 4
        }
        guard !buckets.isEmpty else { return [] }

        let scored: [(colour: RGB, score: Double)] = buckets.values.map { bucket in
            let n = bucket.count
            let colour = RGB(r: bucket.r / n, g: bucket.g / n, b: bucket.b / n)
            let maxC = max(colour.r, colour.g, colour.b)
            let minC = min(colour.r, colour.g, colour.b)
            let saturation = maxC <= 0 ? 0 : (maxC - minC) / maxC
            let luminance = 0.299 * colour.r + 0.587 * colour.g + 0.114 * colour.b
            let luminanceWeight = 1 - pow(abs(luminance - 0.5) * 2, Tuning.luminanceFalloff)
            let vibrancy = Tuning.vibrancyBase + saturation * Tuning.vibrancyGain
            let coverage = pow(n, Tuning.coverageExponent)
            return (colour, coverage * vibrancy * max(luminanceWeight, Tuning.luminanceFloor))
        }
        .sorted { $0.score > $1.score }

        // Greedily accept colours far enough apart to span the artwork.
        var chosen: [RGB] = []
        for candidate in scored where chosen.allSatisfy({
            distance($0, candidate.colour) >= Tuning.minSeparation
        }) {
            chosen.append(candidate.colour)
            if chosen.count >= Tuning.maxColors { break }
        }
        return chosen.isEmpty ? Array(scored.prefix(Tuning.maxColors).map(\.colour)) : chosen
    }

    static func distance(_ a: RGB, _ b: RGB) -> Double {
        let dr = a.r - b.r, dg = a.g - b.g, db = a.b - b.b
        return (dr * dr + dg * dg + db * db).squareRoot()
    }

    static func blend(_ from: RGB, toward: RGB, amount: Double) -> RGB {
        let f = min(max(amount, 0), 1)
        return RGB(
            r: from.r + (toward.r - from.r) * f,
            g: from.g + (toward.g - from.g) * f,
            b: from.b + (toward.b - from.b) * f
        )
    }

    /// Keep the hue, lift saturation slightly for richness, and clamp brightness
    /// so the tone is neither crushed to black nor bright enough to fight the
    /// white text laid over it.
    static func backdropAdjusted(_ colour: RGB) -> Tone {
        var (h, s, v) = hsv(colour)
        s = min(s * Tuning.saturationBoost, 1)
        v = min(max(v, Tuning.minBrightness), Tuning.maxBrightness)
        let adjusted = rgb(h: h, s: s, v: v)
        return Tone(red: adjusted.r, green: adjusted.g, blue: adjusted.b)
    }

    /// Written out rather than taken from a platform colour type, because that is
    /// the whole point: UIColor's conversion is not available off Apple.
    static func hsv(_ colour: RGB) -> (h: Double, s: Double, v: Double) {
        let maxC = max(colour.r, colour.g, colour.b)
        let minC = min(colour.r, colour.g, colour.b)
        let delta = maxC - minC
        var hue = 0.0
        if delta > 0 {
            switch maxC {
            case colour.r: hue = ((colour.g - colour.b) / delta).truncatingRemainder(dividingBy: 6)
            case colour.g: hue = (colour.b - colour.r) / delta + 2
            default: hue = (colour.r - colour.g) / delta + 4
            }
            hue /= 6
            if hue < 0 { hue += 1 }
        }
        return (hue, maxC <= 0 ? 0 : delta / maxC, maxC)
    }

    static func rgb(h: Double, s: Double, v: Double) -> RGB {
        if s <= 0 { return RGB(r: v, g: v, b: v) }
        let sector = (h - h.rounded(.down)) * 6
        let i = Int(sector)
        let f = sector - Double(i)
        let p = v * (1 - s)
        let q = v * (1 - s * f)
        let t = v * (1 - s * (1 - f))
        switch i {
        case 0: return RGB(r: v, g: t, b: p)
        case 1: return RGB(r: q, g: v, b: p)
        case 2: return RGB(r: p, g: v, b: t)
        case 3: return RGB(r: p, g: q, b: v)
        case 4: return RGB(r: t, g: p, b: v)
        default: return RGB(r: v, g: p, b: q)
        }
    }
}

#endif
