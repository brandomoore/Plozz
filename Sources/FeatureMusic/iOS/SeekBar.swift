// Adapted from brandomoore/Mozz at 58dab0015d09a4978f2c484e072d1bc0e30f69dc.
// Copyright (C) 2026 Mozz contributors. GPL-3.0-only with Apple distribution permission.
// See Mozz-NOTICE.txt. Plozz adapters retain the original player motion and geometry.
#if os(iOS)
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// The now-playing seek bar: a knob-less capsule that fills to the current
/// position. At rest — and while playing — it looks identical. While you
/// press-and-drag to seek, the bar grows taller and brightens, and both time
/// labels (elapsed on the left, remaining on the right) brighten and scale up.
/// Apple-Music style.
struct SeekBar: View {
    let elapsed: Double
    let duration: Double
    let trackID: String?
    let formatLabel: String?
    /// Called once, on release, with the target time to seek to.
    let onSeek: (Double) -> Void

    // MARK: Tunables
    private let restHeight: CGFloat = 10
    private let seekHeight: CGFloat = 20
    private let seekScale: CGFloat = 1.015
    private let restFillOpacity: CGFloat = 0.82
    private let restTrackOpacity: CGFloat = 0.30
    private let seekTrackOpacity: CGFloat = 0.42
    private let restLabelOpacity: CGFloat = 0.5
    private let seekLabelScale: CGFloat = 1.14
    private let labelSpacing: CGFloat = 10
    private let anim: Animation = .smooth(duration: 0.34)

    @State private var scrubbing = false
    @State private var scrubValue = 0.0
    @State private var settlingValue: Double?
    @State private var settleGeneration = 0

    private var current: Double {
        if scrubbing { return scrubValue }
        return settlingValue ?? elapsed
    }
    private var progress: Double {
        guard duration > 0 else { return 0 }
        return min(max(current / duration, 0), 1)
    }
    private var remaining: Double { max(duration - current, 0) }

    var body: some View {
        VStack(spacing: labelSpacing) {
            bar
            labels
        }
        .onChange(of: elapsed) { _, newElapsed in
            guard let settlingValue,
                  abs(newElapsed - settlingValue) <= 1 else { return }
            settleGeneration &+= 1
            self.settlingValue = nil
        }
        .onChange(of: trackID) { _, _ in
            settleGeneration &+= 1
            settlingValue = nil
            scrubbing = false
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Playback position")
        .accessibilityValue("\(Int(current)) of \(Int(max(0, duration))) seconds")
        .accessibilityAdjustableAction { direction in
            let step: Double = direction == .increment ? 10 : -10
            onSeek(min(max(0, elapsed + step), duration))
        }
    }

    // MARK: Bar

    private var bar: some View {
        GeometryReader { geo in
            let h = scrubbing ? seekHeight : restHeight
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.primary.opacity(scrubbing ? seekTrackOpacity : restTrackOpacity))
                Capsule()
                    .fill(.primary.opacity(scrubbing ? 1 : restFillOpacity))
                    .frame(width: min(w, max(h, w * progress)))
            }
            .frame(width: w, height: h)
            // Scale the complete painted bar inside its fixed 20-point layout
            // reservation, so pickup feels responsive without moving the labels.
            .scaleEffect(scrubbing ? seekScale : 1)
            .frame(width: w, height: geo.size.height, alignment: .center)
            .overlay {
                Color.clear
                    .frame(height: 44)
                    .contentShape(Rectangle())
                    .gesture(seekGesture(width: w))
            }
            .animation(anim, value: scrubbing)
        }
        // Reserve the taller (seeking) height so the labels below don't shift
        // when the bar grows.
        .frame(height: seekHeight)
    }

    private func seekGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if !scrubbing {
                    settleGeneration &+= 1
                    settlingValue = nil
                    scrubbing = true
                    impact()
                }
                scrubValue = time(atX: value.location.x, width: width)
            }
            .onEnded { value in
                let target = time(atX: value.location.x, width: width)
                scrubValue = target
                // Keep displaying the released target until the player's periodic
                // snapshot catches up. Handing control straight back to `elapsed`
                // exposes its pre-seek value for up to one tick and makes the fill
                // spring away, then back.
                settleGeneration &+= 1
                let generation = settleGeneration
                settlingValue = target
                onSeek(target)
                scrubbing = false
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    guard settleGeneration == generation else { return }
                    settlingValue = nil
                }
            }
    }

    private func time(atX x: CGFloat, width: CGFloat) -> Double {
        guard width > 0, duration > 0 else { return 0 }
        return min(max(x / width, 0), 1) * duration
    }

    // MARK: Labels

    private var labels: some View {
        ZStack {
            HStack(spacing: 0) {
                timeLabel(Format.duration(current))
                    .scaleEffect(scrubbing ? seekLabelScale : 1, anchor: .leading)
                Spacer(minLength: 0)
                timeLabel("\u{2212}" + Format.duration(remaining))
                    .scaleEffect(scrubbing ? seekLabelScale : 1, anchor: .trailing)
            }
            .foregroundStyle(.primary.opacity(scrubbing ? 1 : restLabelOpacity))
            .animation(anim, value: scrubbing)

            if let formatLabel {
                AudioFormatBadge(label: formatLabel)
            }
        }
    }

    private func timeLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption.monospacedDigit())
            .fontWeight(scrubbing ? .semibold : .regular)
    }

    // MARK: Haptics

    private func impact() {
#if canImport(UIKit)
        let generator = UIImpactFeedbackGenerator(style: .soft)
        generator.impactOccurred(intensity: 0.7)
#endif
    }
}

private struct AudioFormatBadge: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.caption2.weight(.semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .foregroundStyle(.primary.opacity(0.72))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            // A fixed light wash stays luminous across artwork colors. Material
            // sampled dark backdrops and made this pill look muddy.
            .background {
                Capsule().fill(.primary.opacity(0.16))
            }
            .overlay {
                Capsule().stroke(.primary.opacity(0.12), lineWidth: 0.5)
            }
            .frame(maxWidth: 180)
            .accessibilityLabel(Text("Audio format \(label)"))
    }
}

#endif
