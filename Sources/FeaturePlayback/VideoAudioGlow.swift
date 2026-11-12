#if os(tvOS)
import Observation
import SwiftUI

@MainActor
@Observable
final class VideoAudioGlowState {
    private(set) var colors: [Color] = Array(repeating: .white.opacity(0.2), count: 3)
    private var sampler: VideoPreviewColorSampler?
    var sampleCount: Int { sampler?.sampleCount ?? 0 }
    var isSampling: Bool { sampler?.isRunning ?? false }

    func update(engine: any VideoEngine, enabled: Bool) {
        guard enabled || sampler != nil else { return }
        if sampler == nil {
            sampler = VideoPreviewColorSampler { [weak self] samples in
                guard !samples.isEmpty else { return }
                self?.colors = samples.map {
                    $0.w > 0
                        ? Color(red: Double($0.x), green: Double($0.y), blue: Double($0.z)).opacity(Double($0.w))
                        : .white.opacity(0.2)
                }
            }
        }
        sampler?.update(engine: engine, enabled: enabled)
    }

    func stop() { sampler?.stop() }
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
        let borderWidth = 2 / displayScale
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(gradient, lineWidth: 96)
                .blur(radius: 96)
                .opacity(0.36)
            RoundedRectangle(cornerRadius: cornerRadius + borderWidth / 2, style: .continuous)
                .stroke(gradient, lineWidth: borderWidth)
                .padding(-borderWidth / 2)
                .opacity(isFocused ? 0 : 0.32)
        }
        .opacity(isPresented ? 1 : 0)
        .animation(reduceMotion ? nil : .easeInOut(duration: isPresented ? 3 : 1.5), value: isPresented)
        .animation(reduceMotion ? nil : .easeInOut(duration: 1.5), value: state.colors)
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
