#if os(tvOS)
import Observation
import SwiftUI

@MainActor
@Observable
final class VideoAudioGlowState {
    private(set) var colors: [Color] = Array(repeating: .white.opacity(0.2), count: 3)
    private(set) var borderColors: [Color] = Array(repeating: .white, count: 3)
    private var sampler: VideoPreviewColorSampler?
    var sampleCount: Int { sampler?.sampleCount ?? 0 }
    var isSampling: Bool { sampler?.isRunning ?? false }

    func update(engine: any VideoEngine, enabled: Bool) {
        guard enabled || sampler != nil else { return }
        if sampler == nil {
            sampler = VideoPreviewColorSampler { [weak self] samples in
                self?.updatePalette(samples)
            }
        }
        sampler?.update(engine: engine, enabled: enabled)
    }

    func stop() { sampler?.stop() }

    func updatePalette(_ samples: [SIMD4<Float>]) {
        guard !samples.isEmpty else { return }
        colors = samples.map {
            $0.w > 0
                ? Color(red: Double($0.x), green: Double($0.y), blue: Double($0.z)).opacity(Double($0.w))
                : .white.opacity(0.2)
        }
        borderColors = samples.map {
            guard $0.w > 0 else { return .white }
            return Color(red: Double($0.x) * 0.75 + 0.25,
                         green: Double($0.y) * 0.75 + 0.25,
                         blue: Double($0.z) * 0.75 + 0.25)
        }
    }
}

struct VideoAudioGlow: View {
    let state: VideoAudioGlowState
    let isActive: Bool
    let cornerRadius: CGFloat
    let isFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale
    @State private var isPresented = false

    var body: some View {
        let gradient = LinearGradient(colors: state.colors, startPoint: .leading, endPoint: .trailing)
        let borderWidth = 2 / displayScale + 1
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(gradient, lineWidth: 96)
                .blur(radius: 96)
                .opacity(0.36)
            RoundedRectangle(cornerRadius: cornerRadius + borderWidth, style: .continuous)
                .strokeBorder(LinearGradient(colors: state.borderColors, startPoint: .leading, endPoint: .trailing),
                              lineWidth: borderWidth)
                .padding(-borderWidth)
                .shadow(color: .black.opacity(0.85), radius: 1 / displayScale)
                .opacity(isFocused ? 0 : 0.44)
        }
        .opacity(isPresented ? 1 : 0)
        .animation(reduceMotion ? nil : .easeInOut(duration: isPresented ? 3 : 1.5), value: isPresented)
        .animation(reduceMotion ? nil : .easeInOut(duration: 1.5), value: state.colors)
        .animation(reduceMotion ? nil : .easeInOut(duration: 1.5), value: state.borderColors)
        .task(id: isActive) {
            if isActive {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
            }
            isPresented = isActive
        }
        .onDisappear { isPresented = false }
    }
}
#endif
