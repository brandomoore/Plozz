import SwiftUI
import AppShell
import CoreModels

/// Plozz — an open-source tvOS Jellyfin client.
@main
struct PlozzApp: App {
    init() {
        // COORDINATOR TEST-ONLY (never commit/merge): persist remux flags so they
        // survive a TV-initiated relaunch (devicectl launch args only apply to the
        // one process). Full-at-open in-sync path (B6 04de3b8): route 4K HDR10/DoVi
        // to the AVPlayer remux, enable whole-timeline keyframe-scan (cheap 64KB
        // cluster-header probe is auto-on within scan). remuxLazyIndex deliberately
        // OFF — this build is the full-timeline-seek architecture, not windowed lazy.
        UserDefaults.standard.register(defaults: [
            "com.plozz.playback.remuxHevcAny": true,
            "com.plozz.playback.mpvSafeAudio": true,
            "com.plozz.playback.remuxKeyframeScan": true,
            "com.plozz.playback.remuxKeyframeIndex": true,
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
