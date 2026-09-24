import SwiftUI
import AppShell
import CoreModels

/// Plozz — an open-source tvOS Jellyfin client.
@main
struct PlozzApp: App {
    init() {
        // TEST-DEPLOY DEFAULTS (coordinator-only, not for merge): persist remux
        // test flags so they apply on EVERY launch (Top Shelf, home-screen
        // relaunch, resume), not just devicectl -arguments. remuxLazyIndex turns
        // on B7's windowed/EVENT near-instant lazy path; remuxHevcAny routes 4K
        // HDR10/DoVi MKVs to AVPlayer (not crash-prone mpv); mpvSafeAudio guards
        // the mpv path for anything that still falls through.
        UserDefaults.standard.register(defaults: [
            "com.plozz.playback.remuxLazyIndex": true,
            "com.plozz.playback.remuxHevcAny": true,
            "com.plozz.playback.mpvSafeAudio": true,
        ])

        // Give artwork a real on-disk cache so backdrops, posters and logos load
        // instantly on revisit instead of being re-fetched every time (the
        // default shared URLCache is only a few MB — far too small for 4K
        // backdrops). AsyncImage and our URLSession-based loader both read
        // through URLCache.shared, so this keeps recently seen art warm the way a
        // dedicated player like Infuse does.
        URLCache.shared = URLCache(
            memoryCapacity: 64 * 1024 * 1024,   // 64 MB in memory
            diskCapacity: 512 * 1024 * 1024,    // 512 MB on disk
            directory: nil
        )
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
