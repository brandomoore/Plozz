// Adapted from brandomoore/Mozz at 58dab0015d09a4978f2c484e072d1bc0e30f69dc.
// Copyright (C) 2026 Mozz contributors. GPL-3.0-only with Apple distribution permission.
// See Mozz-NOTICE.txt. Plozz adapters retain the original player motion and geometry.
#if os(iOS)
import Foundation

/// How many pixels to ask a server for, given how many pixels a slot will draw.
///
/// Every artwork request used to carry a hand-picked constant — `size: 1200` for
/// a hero, `size * 2` for a thumbnail — which quietly assumed a @2x display and a
/// phone-sized window. On a @3x iPhone that made every cover a third short of the
/// pixels it was drawn at, and on a large window it made the hero a soft upscale
/// of a phone-sized image. The number a slot needs is not a constant; it is the
/// slot's own size in points multiplied by the display's scale.
///
/// Asking for exactly that would be worse, though. Each distinct size is a
/// separate transcode on the server and a separate entry in every cache, so a
/// layout that measures 331pt on one device and 334pt on another would fetch the
/// same cover twice. Requests are therefore snapped UP to a rung: sizes cluster
/// on a handful of values that devices share, and no cover is ever smaller than
/// the box it fills.
public enum ArtworkResolution {
    /// Roughly √2 apart — close enough that snapping up never wastes much
    /// bandwidth, far enough apart that a whole device class shares one rung.
    public static let rungs: [Int] = [128, 192, 256, 384, 512, 768, 1024, 1536, 2048]

    /// The smallest rung that covers `pixels`, capped at the largest one.
    ///
    /// The cap matters: a full-bleed hero on a large display can measure past
    /// 2700 physical pixels, and no music server has cover art that big — asking
    /// for it only makes the server upscale, which costs time and buys nothing.
    public static func rung(forPixels pixels: Int) -> Int {
        rungs.first { $0 >= pixels } ?? rungs[rungs.count - 1]
    }

    /// The rung for a slot `points` wide on a display of scale `scale`.
    public static func rung(forPoints points: Double, scale: Double) -> Int {
        rung(forPixels: Int((points * max(1, scale)).rounded(.up)))
    }
}

#endif
