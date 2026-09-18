#if canImport(SwiftUI)
import SwiftUI

/// Decorative startup mark. Its animation lifetime belongs to this leaf, never
/// to the app's startup work or readiness state.
public struct PlozzStartupLogo: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    public init() {}

    public var body: some View {
        Group {
            if !PlozzStartupLogoMotion.shouldAnimate(reduceMotion: reduceMotion, scenePhase: scenePhase) {
                PlozzStartupLogoArtwork(pose: .rest)
            } else {
                Color.clear
                    .keyframeAnimator(initialValue: PlozzStartupLogoMotion.Pose.rest) { _, pose in
                        PlozzStartupLogoArtwork(pose: pose)
                    } keyframes: { _ in
                        PlozzStartupLogoMotion.keyframes
                    }
            }
        }
        #if os(tvOS)
        .frame(width: 192, height: 192)
        #else
        .frame(width: 128, height: 128)
        #endif
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

struct PlozzStartupLogoArtwork: View {
    let pose: PlozzStartupLogoMotion.Pose

    var body: some View {
        ZStack {
            face("PlozzStartupSmile")
            face("PlozzStartupWink")
                .opacity(pose.wink)
            face("PlozzStartupDelight")
                .opacity(pose.delight)
        }
        .rotationEffect(.degrees(pose.tilt + pose.turn))
    }

    private func face(_ name: String) -> some View {
        Image(name, bundle: .module)
            .renderingMode(.original)
            .resizable()
            .interpolation(.none)
            .scaledToFit()
    }
}

enum PlozzStartupLogoMotion {
    static func shouldAnimate(reduceMotion: Bool, scenePhase: ScenePhase) -> Bool {
        !reduceMotion && scenePhase == .active
    }

    struct Pose: Equatable {
        var wink = 0.0
        var delight = 0.0
        var tilt = 0.0
        var turn = 0.0

        static let rest = Pose()
    }

    // All tracks last eight seconds. The final full turn is visually identical
    // to zero, so repeating never rewinds. Keeping the smile opaque underneath
    // each expression also prevents the shared pixel outline from fading.
    @KeyframesBuilder<Pose>
    static var keyframes: some Keyframes<Pose> {
        KeyframeTrack(\.wink) {
            LinearKeyframe(0, duration: 0.9)
            LinearKeyframe(1, duration: 0.15)
            LinearKeyframe(1, duration: 0.55)
            LinearKeyframe(0, duration: 0.15)
            LinearKeyframe(0, duration: 6.25)
        }
        KeyframeTrack(\.delight) {
            LinearKeyframe(0, duration: 1.7)
            LinearKeyframe(1, duration: 0.15)
            LinearKeyframe(1, duration: 3.95)
            LinearKeyframe(0, duration: 0.2)
            LinearKeyframe(0, duration: 2)
        }
        KeyframeTrack(\.tilt) {
            LinearKeyframe(0, duration: 0.8)
            CubicKeyframe(-6, duration: 0.35, startVelocity: 0, endVelocity: 0)
            LinearKeyframe(-6, duration: 0.55)
            CubicKeyframe(0, duration: 0.35, startVelocity: 0, endVelocity: 0)
            LinearKeyframe(0, duration: 5.95)
        }
        KeyframeTrack(\.turn) {
            LinearKeyframe(0, duration: 3.5)
            CubicKeyframe(-12, duration: 0.25, startVelocity: 0, endVelocity: 0)
            CubicKeyframe(360, duration: 0.9, startVelocity: 0, endVelocity: 0)
            LinearKeyframe(360, duration: 3.35)
        }
    }
}
#endif
