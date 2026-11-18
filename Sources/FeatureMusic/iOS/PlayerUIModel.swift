// Adapted from brandomoore/Mozz at 58dab0015d09a4978f2c484e072d1bc0e30f69dc.
// Copyright (C) 2026 Mozz contributors. GPL-3.0-only with Apple distribution permission.
// See Mozz-NOTICE.txt. Plozz adapters retain the original player motion and geometry.
#if os(iOS)
import SwiftUI

/// Shared command state for the now-playing surface.
///
/// Candidate **B** renders the mini island and the full drawer as a *single*
/// morphing view (`NowPlayingMorphContainer`) that lives in the same hierarchy
/// as everything else, so there is no cross-layer coordinate hand-off to bridge.
/// This model therefore holds only the one bit the rest of the app needs to
/// drive: whether the player should be expanded. The container observes it and
/// runs the open/collapse spring; taps and the dismiss drag write to it.
final class PlayerUIModel: ObservableObject {
    /// `true` ⇒ the drawer should be expanded, `false` ⇒ docked as the island.
    /// The morph container is the single animator that reacts to this flag.
    @Published var isFullPresented: Bool = false
}

#endif
