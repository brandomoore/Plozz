// Adapted from brandomoore/Mozz at 58dab0015d09a4978f2c484e072d1bc0e30f69dc.
// Copyright (C) 2026 Mozz contributors. GPL-3.0-only with Apple distribution permission.
// See Mozz-NOTICE.txt. Plozz adapters retain the original player motion and geometry.
#if os(iOS)
import SwiftUI

// MARK: - Adaptive layout rules
//
// Where navigation, the dock and the player sit at a given width — as rules,
// not as `if wide` scattered through the views.
//
// The twin of Android's `PlayerLayout.kt`, and deliberately the same shape:
// arithmetic and enums, no view code, so what travels between the clients is the
// *reasoning* — which panel shows where, what the dock morphs from — rather than
// a screenful of one platform's UI framework. Anything a second client would
// have to guess at belongs here with a comment saying why.
//
// See ADR-0016.

/// How the expanded player arranges itself.
///
/// Note there is exactly one piece of *state* behind this — `PlayerPanel?` — and
/// width only decides how that state is drawn. That is the whole design: closing
/// the queue means the same thing on a phone and an iPad, so rotating (or, on a
/// folding phone, unfolding) mid-song rearranges the screen without ever
/// changing what you asked for.
enum PlayerPresentation: Equatable {
    /// No panel: artwork centred, given the whole width.
    case artwork

    /// Player on the left, queue or lyrics in a column of their own on the right.
    case panelBeside

    /// The panel takes the artwork's place, leaving the transport where it was.
    /// The only honest option when there is one column.
    case panelInstead
}

/// The rule. Two inputs, three outcomes, no hidden state.
func playerPresentation(wide: Bool, panel: PlayerPanel?) -> PlayerPresentation {
    guard panel != nil else { return .artwork }
    return wide ? .panelBeside : .panelInstead
}

/// The navigation rail: the bottom bar stood on its end, used instead of it once
/// there is width for two columns.
///
/// The dock does **not** move with it. It is the same floating pill at every
/// width — bottom of the content area, capped at `BottomBar.dockMaxWidth` — and
/// only what it clears changes: a tab bar's worth on a phone, nothing beside a
/// rail. That is what lets one morph serve both instead of a phone morph and a
/// tablet morph that drift apart.
enum SideNav {
    /// The rail's column. Android's 88dp, so a destination is the same size and
    /// in the same place on both.
    ///
    /// It is a *column*, not a floating capsule: the page begins where this ends
    /// and nothing runs underneath it. A navigation surface laid over the content
    /// it navigates reads as something in the way, and neither iPadOS nor Android
    /// does it — Apple Music's sidebar pushes its content aside, and Android's
    /// rail is a sibling in a `Row`.
    static let columnWidth: CGFloat = 88

    /// What a page has to leave clear on its leading edge — the column, exactly,
    /// since nothing overlaps any more.
    static var contentInset: CGFloat { columnWidth }

    /// One destination: a 30pt glyph over an 11pt label, with the same air
    /// around it that the bar's items get.
    static let itemHeight: CGFloat = 64
    static let itemSpacing: CGFloat = 2

    /// Air above the first destination, below the status bar.
    static let topPadding: CGFloat = 12

    /// Inset of the selection lozenge inside the column, so it has a margin to
    /// breathe in rather than running edge to edge.
    static let selectionInset: CGFloat = 6
}

/// The one place that decides whether navigation chrome is glass or solid, so
/// the bar, the rail, the dock and the player can never disagree about it.
///
/// They did disagree once: the tab bar knew Black turns glass off and the dock
/// did not, so the two sat side by side in different materials. The rule lives
/// here now and each surface asks.
enum MozzChrome {
    /// Glass is a lit, frosted surface — a lighter shade of whatever is behind
    /// it by definition — which is the one thing Black does not allow. The solid
    /// path already existed for Low Power and Reduce Transparency; Black is a
    /// third reason to take it.
    static func useGlass(enabled: Bool,
                         lowPower: Bool,
                         reduceTransparency: Bool,
                         blackout: Bool) -> Bool {
        enabled && !lowPower && !reduceTransparency && !blackout
    }
}

#endif
