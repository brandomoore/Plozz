// Adapted from brandomoore/Mozz at 58dab0015d09a4978f2c484e072d1bc0e30f69dc.
// Copyright (C) 2026 Mozz contributors. GPL-3.0-only with Apple distribution permission.
// See Mozz-NOTICE.txt. Plozz adapters retain the original player motion and geometry.
#if os(iOS)
import SwiftUI

/// Icon vocabulary for Mozz. Most glyphs are custom **Tabler** icons (MIT,
/// imported as vector template images into `Icons.xcassets` via
/// `tools/icons/build-icons.sh`); a few Apple-specific device glyphs (AirPlay,
/// AirPods, headphones) stay as SF Symbols.
///
/// Two ways to use:
///  - `AppIcon.play.styled(size:)` — the player's fixed-size transport glyphs.
///  - `Image(mozz: "sf.name")` / `Label("x", mozz: "sf.name")` — everywhere else:
///    pass the ORIGINAL SF Symbol name and it maps to the Tabler asset (falling
///    back to the SF Symbol if unmapped, e.g. device/route glyphs).
enum AppIcon {
    case skipBack, skipForward, play, pause, shuffle, repeatTracks
    case lyrics, queue, overflow
    /// The two halves of the skip glyph, on a shared grid so they compose back
    /// into `skipForward`. Split so the player can drive the arrow into the end
    /// bar on a skip while the bar holds still — see `TransportGlyph`.
    case skipArrow, skipBar

    private var customName: String? {
        switch self {
        case .skipBack: return "player-skip-back"
        case .skipForward: return "player-skip-forward"
        case .skipArrow: return "player-skip-arrow"
        case .skipBar: return "player-skip-bar"
        case .play: return "player-play"
        case .pause: return "player-pause"
        case .shuffle: return "arrows-shuffle"
        case .repeatTracks: return "repeat"
        case .lyrics: return "quote"
        case .queue: return "list"
        case .overflow: return "dots"
        }
    }

    var image: Image { Image(customName ?? "", bundle: .module) }

    /// Render at a target point size (custom template image fills the frame).
    @ViewBuilder
    func styled(size: CGFloat) -> some View {
        image.resizable().scaledToFit().frame(width: size, height: size)
    }
}

extension Image {
    /// A UI icon by its ORIGINAL SF Symbol name, mapped to the Tabler asset when
    /// one exists; otherwise the SF Symbol (device/route glyphs, unmapped names).
    init(mozz sfName: String) {
        if let asset = MozzIconMap.tabler[sfName] {
            self.init(asset, bundle: .module)
        } else {
            self.init(systemName: sfName)
        }
    }
}

extension Label where Title == Text, Icon == Image {
    /// `Label` whose icon is resolved through the Tabler map (see `Image(mozz:)`).
    init(_ title: String, mozz sfName: String) {
        self.init { Text(title) } icon: { Image(mozz: sfName) }
    }
}

/// SF Symbol name → Tabler asset name. Anything absent falls back to the SF
/// Symbol at the call site (e.g. AirPlay / AirPods / headphones device glyphs).
enum MozzIconMap {
    static let tabler: [String: String] = [
        "music.note": "music",
        "music.note.list": "playlist",
        "music.mic": "microphone-2",
        "music.note.house.fill": "home-filled",
        "server.rack": "server",
        "sparkles": "sparkles",
        "arrow.down.circle": "download",
        "arrow.down.circle.fill": "download",
        "square.stack": "disc",
        "square.stack.3d.up": "stack-3",
        "shuffle": "arrows-shuffle",
        "play.fill": "player-play",
        "forward.fill": "player-skip-forward",
        "backward.fill": "player-skip-back",
        "magnifyingglass": "search",
        "heart": "heart",
        "heart.fill": "heart-filled",
        "checkmark.circle.fill": "circle-check-filled",
        "checkmark": "check",
        "arrow.triangle.2.circlepath": "refresh",
        "xmark.circle.fill": "circle-x-filled",
        "xmark": "x",
        "waveform": "waveform",
        "text.quote": "quote",
        "wand.and.stars": "wand",
        // Play Next and Add to Queue are different actions and had been sharing
        // one glyph, so the menu offered the same picture twice and neither
        // said which was which. Play Next has its own now — the queue with the
        // play head arriving at the top of it — matching the desktop.
        "text.line.first.and.arrowtriangle.forward": "play-next",
        "text.append": "playlist-add",
        "tag": "tag",
        "stethoscope": "stethoscope",
        "star.slash": "star-off",
        "star": "star",
        "star.fill": "star-filled",
        "star.leadinghalf.filled": "star-half-filled",
        "checkmark.seal.fill": "circle-check-filled",
        "xmark.circle": "circle-x",
        "house.fill": "home",
        "square.stack.fill": "books",
        "pause.fill": "player-pause",
        "speedometer": "gauge",
        "speaker.wave.2.fill": "volume",
        "person.crop.circle.fill": "user-circle",
        "paintpalette": "palette",
        "number": "hash",
        "network": "network",
        "line.3.horizontal": "grip-horizontal",
        "internaldrive": "database",
        "info.circle": "info-circle",
        "house": "home",
        "guitars": "category",
        "exclamationmark.triangle": "alert-triangle",
        "ellipsis": "dots",
        "circle": "circle",
        "chevron.right": "chevron-right",
        "chevron.left.forwardslash.chevron.right": "code",
        "chevron.backward": "chevron-left",
        "arrow.forward": "arrow-right",
        "play.tv": "device-tv",
    ]
}

#endif
