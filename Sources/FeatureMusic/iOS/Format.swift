// Adapted from brandomoore/Mozz at 58dab0015d09a4978f2c484e072d1bc0e30f69dc.
// Copyright (C) 2026 Mozz contributors. GPL-3.0-only with Apple distribution permission.
// See Mozz-NOTICE.txt. Plozz adapters retain the original player motion and geometry.
#if os(iOS)
import Foundation

/// Small display formatters shared across the UI.
enum Format {
    static func duration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

}

#endif
