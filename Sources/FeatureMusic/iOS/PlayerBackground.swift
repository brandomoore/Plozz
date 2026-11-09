// Adapted from brandomoore/Mozz at 58dab0015d09a4978f2c484e072d1bc0e30f69dc.
// Copyright (C) 2026 Mozz contributors. GPL-3.0-only with Apple distribution permission.
// See Mozz-NOTICE.txt. Plozz adapters retain the original player motion and geometry.
#if os(iOS)
import SwiftUI
import CoreModels
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Style

/// How the now-playing player paints its background. Persisted via `@AppStorage`
/// ("playerBackgroundStyle") so a future Settings picker can switch it with no
/// other changes. `adaptive` is the default — a lush mesh gradient sampled from
/// the artwork (Apple-Music style).
enum PlayerBackgroundStyle: String, CaseIterable, Sendable {
    /// Mesh gradient sampled from the current artwork's colors.
    case adaptive
    /// Pure black (AMOLED / OLED battery + aesthetic).
    case oled
    /// Follow the app's light/dark theme (a neutral system background).
    case theme

    var storageValue: String { rawValue }
    static let storageKey = "playerBackgroundStyle"
    static let `default`: PlayerBackgroundStyle = .adaptive
}

// MARK: - Sampled color grid

/// A `dim × dim` grid of colors sampled from the current artwork, used to build
/// the mesh-gradient backdrop. Nine colors (3×3) blend into a smooth, artwork-
/// accurate field. Colors are pre-adjusted for depth + legibility.
struct ArtworkColorGrid: Equatable {
    static let dim = 3
    var colors: [Color]           // count == dim*dim, row-major (top→bottom)

    var isValid: Bool { colors.count == Self.dim * Self.dim }
}

enum ArtworkPalette {
    /// How the sampled grid is shaped into a backdrop.
    ///
    /// Extraction and tone are **not** here any more: they moved to
    /// `PlayerArtworkPalette.Tuning`, so iOS and Android cannot drift apart on
    /// what an album looks like. What remains is the motion, which is genuinely
    /// per-platform — SwiftUI has `MeshGradient` and Compose does not, so the two
    /// render the same tones by different means.
    enum Tuning {
        /// Resolution the artwork is drawn to before histogramming.
        static var sampleDim: Int { PlayerArtworkPalette.Tuning.sampleDim }

        // --- Motion ---
        /// Mesh point drift amplitude (fraction of the frame). Large enough to be
        /// visibly alive (Apple-Music "paint in water") without folding the mesh.
        static let driftAmplitude: Float = 0.16
        /// The center point roams a little further than the edges.
        static let driftCenterBoost: Float = 1.4
        /// Horizontal drift is scaled DOWN vs vertical: a portrait phone has
        /// little side-to-side room, so the field should flow top↔bottom, not
        /// left↔right. 0 = no horizontal motion; 1 = equal to vertical.
        static let driftHorizontalScale: Float = 0.3
    }

    /// Sample the artwork into a color grid, or derive a pleasant deterministic
    /// grid from `seed` when there's no artwork (offline demo / art-less server).
    static func grid(for artwork: ArtworkRef?, backend: (MusicPlayerArtworkResolver)?, seed: String) async -> ArtworkColorGrid {
        #if canImport(UIKit)
        if let artwork, let backend,
           let url = backend.artworkURL(for: artwork, size: 240),
           let image = await ArtworkImageLoader.shared.image(for: url),
           let colors = image.mozzColorGrid(dim: ArtworkColorGrid.dim) {
            return ArtworkColorGrid(colors: colors)
        }
        #endif
        return seedGrid(seed)
    }

    /// The grid IF the artwork is already decoded in-memory, so a preloaded cover
    /// resolves colors on the first frame (no fade-in). Nil ⇒ caller awaits.
    static func cachedGrid(for artwork: ArtworkRef?, backend: (MusicPlayerArtworkResolver)?, seed: String) -> ArtworkColorGrid? {
        #if canImport(UIKit)
        if let artwork, let backend,
           let url = backend.artworkURL(for: artwork, size: 240),
           let image = ArtworkImageLoader.shared.cached(url),
           let colors = image.mozzColorGrid(dim: ArtworkColorGrid.dim) {
            return ArtworkColorGrid(colors: colors)
        }
        #endif
        return nil
    }

    /// Deterministic grid from a seed hue (mirrors `ArtworkView`'s placeholder),
    /// varied across the grid so the art-less fallback still looks intentional.
    static func seedGrid(_ seed: String) -> ArtworkColorGrid {
        let hue = Double(seed.hashValue.magnitude % 360) / 360.0
        var colors: [Color] = []
        for row in 0..<ArtworkColorGrid.dim {
            for col in 0..<ArtworkColorGrid.dim {
                let h = (hue + Double(col) * 0.03).truncatingRemainder(dividingBy: 1)
                let b = 0.42 - Double(row) * 0.10
                colors.append(Color(hue: h, saturation: 0.5, brightness: max(0.16, b)))
            }
        }
        return ArtworkColorGrid(colors: colors)
    }
}

// MARK: - Backdrop view

/// Observes the system Low Power Mode state and republishes on change, so views
/// can shed expensive continuous work (e.g. the backdrop's 30fps mesh drift) when
/// the device is conserving power — the same battery/thermal state where SwiftUI
/// animations are already CPU/GPU-throttled and most likely to drop frames.
@MainActor
final class LowPowerModeObserver: ObservableObject {
    @Published private(set) var isLowPower: Bool = ProcessInfo.processInfo.isLowPowerModeEnabled
    private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.isLowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
            }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }
}

/// The player's background. `adaptive` draws a mesh gradient from the sampled
/// grid (with a gentle drift + legibility scrim); `oled` is pure black; `theme`
/// follows the system background. Self-contained so its per-frame drift redraws
/// this view only, not the morph container.
struct PlayerBackdrop: View {
    let style: PlayerBackgroundStyle
    let grid: ArtworkColorGrid?
    /// Only drift while the drawer is open (saves power when collapsed).
    var animated: Bool = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var power = LowPowerModeObserver()
    /// When the live drift last turned on — used to ease the drift amplitude in
    /// from zero (driven by the timeline's own clock) so enabling it at settle
    /// doesn't pop the mesh from centered to full offset.
    @State private var driftStart: Date?

    var body: some View {
        switch style {
        case .oled:
            Color.black
        case .theme:
            Color.mozzBackground
        case .adaptive:
            adaptive
        }
    }

    private var drift: Bool { animated && !reduceMotion && !power.isLowPower }
    /// Seconds over which drift eases in when it turns on.
    private static let driftRampDuration: TimeInterval = 0.9

    /// Use the live mesh only when the device can afford it. In Low Power Mode (or
    /// Reduce Motion) fall back to a cheap static gradient so the player's expand
    /// transition composites less per frame on exactly the throttled devices where
    /// frames are already tight.
    private var useMesh: Bool {
        if #available(iOS 18.0, macOS 15.0, *) {
            return !power.isLowPower && !reduceMotion
        }
        return false
    }

    @ViewBuilder private var adaptive: some View {
        let colors = (grid?.isValid == true ? grid!.colors : ArtworkPalette.seedGrid("mozz").colors)
        ZStack {
            // Base fill (also the mesh-off fallback): the darkest sampled color, so
            // there's never a gap behind the gradient.
            (colors.min(by: { $0.mozzLuminance < $1.mozzLuminance }) ?? .black)
                .ignoresSafeArea()

            if useMesh, #available(iOS 18.0, macOS 15.0, *), colors.count == 9 {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !drift)) { ctx in
                    let t = ctx.date.timeIntervalSinceReferenceDate
                    MeshGradient(width: 3, height: 3, points: meshPoints(t, ramp: driftRamp(at: ctx.date)), colors: colors)
                }
                .onChange(of: drift, initial: true) { _, on in
                    driftStart = on ? Date() : nil
                }
            } else {
                // Static, color-faithful top→bottom wash from the grid's vertical
                // centerline (rows top/mid/bottom) — cheap to composite on resize.
                staticGradient(colors)
            }

            // Legibility scrim: gently darken the very top (status bar / titles)
            // and the bottom (transport + tab controls) without crushing the mid.
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.30), location: 0.0),
                    .init(color: .clear, location: 0.18),
                    .init(color: .clear, location: 0.62),
                    .init(color: .black.opacity(0.38), location: 1.0),
                ],
                startPoint: .top, endPoint: .bottom)
        }
    }

    /// Smoothstep ease of the drift amplitude from 0→1 over `driftRampDuration`
    /// after drift turns on. Continuous (driven by `now`), so no visible jump.
    private func driftRamp(at now: Date) -> Float {
        guard drift, let start = driftStart else { return 0 }
        let x = min(max(now.timeIntervalSince(start) / Self.driftRampDuration, 0), 1)
        return Float(x * x * (3 - 2 * x))
    }

    /// Cheap static replacement for the mesh (Low Power Mode / Reduce Motion /
    /// <iOS18): a top→bottom wash from the grid's vertical centerline so it keeps
    /// the artwork's colour flow without any per-frame mesh compositing.
    @ViewBuilder private func staticGradient(_ colors: [Color]) -> some View {
        let stops: [Color] = colors.count == 9
            ? [colors[1], colors[4], colors[7]]   // top-center, center, bottom-center
            : [colors.first ?? .black, colors.last ?? .black]
        LinearGradient(colors: stops, startPoint: .top, endPoint: .bottom)
    }

    /// 3×3 mesh points. Corners are pinned to the frame; edge-midpoints drift only
    /// ALONG their edge; the center drifts in both axes (a little further) — so the
    /// field churns like paint in water without ever opening a gap. `ramp` eases the
    /// amplitude in when drift starts.
    private func meshPoints(_ t: TimeInterval, ramp: Float) -> [SIMD2<Float>] {
        let ay: Float = (drift ? ArtworkPalette.Tuning.driftAmplitude : 0) * ramp
        let ax = ay * ArtworkPalette.Tuning.driftHorizontalScale
        let cy = ay * ArtworkPalette.Tuning.driftCenterBoost
        func s(_ speed: Double, _ phase: Double) -> Float { Float(sin(t * speed + phase)) }
        return [
            SIMD2(0, 0),
            SIMD2(0.5 + ax * s(0.13, 0.0), 0),
            SIMD2(1, 0),
            SIMD2(0, 0.5 + ay * s(0.11, 1.3)),
            SIMD2(0.5 + ax * s(0.15, 2.0), 0.5 + cy * s(0.09, 0.5)),
            SIMD2(1, 0.5 + ay * s(0.12, 3.1)),
            SIMD2(0, 1),
            SIMD2(0.5 + ax * s(0.10, 4.2), 1),
            SIMD2(1, 1),
        ]
    }
}

// MARK: - Sampling helpers

extension Color {
    /// Rough perceived luminance for picking the darkest sampled color.
    var mozzLuminance: Double {
        #if canImport(UIKit)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        return Double(0.299 * r + 0.587 * g + 0.114 * b)
        #else
        return 0
        #endif
    }
}

#if canImport(UIKit)
extension UIImage {
    /// Extract the artwork's most *prominent, vibrant, distinct* colors and lay
    /// them out as a 9-slot mesh (Apple-Music / Plozz style) — NOT a spatial map.
    /// The image is histogrammed; buckets are scored by coverage × vibrancy ×
    /// mid-luminance (so muddy greys and the black/white extremes lose), then a
    /// greedy diverse pick spans the cover instead of clustering on one hue. The
    /// most prominent color anchors the mesh center with the rest spread around.
    /// The 3×3 backdrop grid for this artwork, or nil if it yields nothing usable.
    ///
    /// The colours come from `PlayerArtworkPalette`, which every Mozz client
    /// shares. All this does is decode the image — the one part that cannot be
    /// shared, because Foundation has no image decoder off Apple — and lay the
    /// three tones out as mesh rows.
    func mozzColorGrid(dim: Int) -> [Color]? {
        guard let pixels = mozzSampledRGBA() else { return nil }
        let side = ArtworkPalette.Tuning.sampleDim
        guard let tones = PlayerArtworkPalette.tones(
            rgba: pixels, width: side, height: side
        ) else { return nil }

        // Phone-calm, VERTICAL layout: colour varies top→bottom, not side→side (a
        // portrait screen has little horizontal room). Each mesh ROW is one tone
        // — dominant across the middle so the screen reads as mostly one wash,
        // with the two accents as gentle top/bottom bands.
        let top = Color(tones.top), middle = Color(tones.middle), bottom = Color(tones.bottom)
        return [top, top, top,
                middle, middle, middle,
                bottom, bottom, bottom]
    }

    /// Draw this image down to the sampling grid and hand back tightly packed
    /// RGBA — the shape `PlayerArtworkPalette` reads.
    private func mozzSampledRGBA() -> [UInt8]? {
        guard let cg = cgImage else { return nil }
        let dim = ArtworkPalette.Tuning.sampleDim
        let bytesPerRow = dim * 4
        var px = [UInt8](repeating: 0, count: dim * bytesPerRow)
        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &px, width: dim, height: dim, bitsPerComponent: 8,
            bytesPerRow: bytesPerRow, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: dim, height: dim))
        return px
    }
}

extension Color {
    /// A tone from the shared palette, as SwiftUI sees it.
    init(_ tone: PlayerArtworkPalette.Tone) {
        self.init(red: tone.red, green: tone.green, blue: tone.blue)
    }
}

#endif

#endif
