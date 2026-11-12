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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPresented = false

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .stroke(LinearGradient(colors: state.colors, startPoint: .leading, endPoint: .trailing), lineWidth: 96)
            .blur(radius: 96)
            .opacity(isPresented ? 0.36 : 0)
            .animation(reduceMotion ? nil : .easeInOut(duration: 1.5), value: isPresented)
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
