// Adapted from brandomoore/Mozz at 58dab0015d09a4978f2c484e072d1bc0e30f69dc.
// Copyright (C) 2026 Mozz contributors. GPL-3.0-only with Apple distribution permission.
// See Mozz-NOTICE.txt. Plozz adapters retain the original player motion and geometry.
#if os(iOS)
import SwiftUI
import CoreModels

/// A subtle, theme-aware artwork placeholder: a quiet neutral gray box with a
/// faint music-note glyph, sized to whatever frame it's given. Shared by every
/// artwork surface (rows, grids, the player) so a missing/loading cover always
/// reads as a calm empty frame — never a colorful tile that flashes during
/// scrolling or track changes. The caller clips it to the artwork's shape.
struct ArtworkPlaceholder: View {
    /// Music-note glyph size as a fraction of the box's shorter side.
    var iconScale: CGFloat = 0.32
    /// The corner the caller will clip this to.
    ///
    /// The Black hairline has to be drawn in the SAME shape. It was a plain
    /// rectangle, and clipping a square border to a rounded corner removes the
    /// border exactly where the corner is — every placeholder read as a tile
    /// with its corners snipped off, the dock's cover included.
    var cornerRadius: CGFloat = 0
    /// Artists are circles rather than rounded squares.
    var circular: Bool = false

    @Environment(\.colorScheme) private var scheme
    @Environment(\.musicPlayerBlackout) private var blackout

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            Color.mozzArtworkPlaceholder
                .overlay(
                    Image(mozz: "music.note")
                        .resizable().scaledToFit()
                        .frame(width: side * iconScale, height: side * iconScale)
                        .foregroundStyle(.secondary)
                        .opacity(0.35)
                )
                // In Black the fill is the page's own black, so the tile would
                // have no edge at all — a note floating in the middle of
                // nothing. The hairline is what makes it a cover-shaped hole.
                // Drawn in the caller's own shape, and with `strokeBorder` so it
                // sits wholly inside it — a centred stroke would put half its
                // width outside the clip and come back a half-hairline.
                .overlay {
                    if blackout { border }
                }
                .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    @ViewBuilder private var border: some View {
        if circular {
            Circle().strokeBorder(Color.mozzHairline, lineWidth: 1)
        } else {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.mozzHairline, lineWidth: 1)
        }
    }

}

/// Renders artwork for a catalog item. Resolves a tokenized URL from the active
/// backend at the requested pixel size (the catalog stores only a reference, so
/// URLs stay valid across token rotation). Falls back to a subtle neutral
/// placeholder (matching the artwork's shape) while loading or when there's no
/// artwork — e.g. the offline demo, or a server that returns none.
struct ArtworkView: View {
    let artwork: ArtworkRef?
    let seed: String
    var size: CGFloat = 48
    var cornerRadius: CGFloat = 6
    /// When true the artwork is clipped to a full circle (artists), regardless of
    /// `cornerRadius`. Robust at any `size` (unlike passing `size / 2`).
    var circular: Bool = false

    @EnvironmentObject private var env: MusicPlayerEnvironment
    /// The display's pixels-per-point. Read from the environment rather than
    /// assumed: a @3x iPhone needs half again as many pixels as a @2x one for the
    /// same box, and hardcoding 2 made every cover on those devices a soft upscale.
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Group {
            if let url = resolvedURL {
                CachedArtworkImage(url: url) { placeholder }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
    }

    private var shape: AnyShape {
        circular
            ? AnyShape(Circle())
            : AnyShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    private var resolvedURL: URL? {
        guard let artwork, let backend = env.active?.backend else { return nil }
        let pixels = ArtworkResolution.rung(forPoints: size, scale: displayScale)
        return backend.artworkURL(for: artwork, size: pixels)
    }

    private var placeholder: some View {
        ArtworkPlaceholder(cornerRadius: cornerRadius, circular: circular)
    }
}

#endif
