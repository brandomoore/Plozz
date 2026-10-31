#if os(iOS)
import SwiftUI
import UIKit
import CoreNetworking
import CoreUI

/// Lives behind the native controls, so their touches never become playback shortcuts.
public struct PlayerTouchGestureSurface: UIViewRepresentable {
    @Environment(\.playerTouchLevelControl) private var sharedLevelControl
    let state: PlayerTouchGestureState
    let shortcutsEnabled: Bool
    let levelsEnabled: Bool
    // Playback lifetime only: temporary gesture suppression must not restore brightness.
    let isActive: Bool
    let canSeek: Bool
    let canBoost: Bool
    let canZoom: Bool
    let onTap: () -> Void
    let onSkip: (PlayerTouchSkipDirection) -> Void
    let onBoostChanged: (Bool) -> Void
    let onZoom: (Bool) -> Void
    let onGestureStarted: () -> Void

    public init(
        state: PlayerTouchGestureState, shortcutsEnabled: Bool,
        levelsEnabled: Bool = false, isActive: Bool = true,
        canSeek: Bool, canBoost: Bool, canZoom: Bool,
        onTap: @escaping () -> Void,
        onSkip: @escaping (PlayerTouchSkipDirection) -> Void,
        onBoostChanged: @escaping (Bool) -> Void,
        onZoom: @escaping (Bool) -> Void,
        onGestureStarted: @escaping () -> Void
    ) {
        self.state = state
        self.shortcutsEnabled = shortcutsEnabled
        self.levelsEnabled = levelsEnabled
        self.isActive = isActive
        self.canSeek = canSeek
        self.canBoost = canBoost
        self.canZoom = canZoom
        self.onTap = onTap
        self.onSkip = onSkip
        self.onBoostChanged = onBoostChanged
        self.onZoom = onZoom
        self.onGestureStarted = onGestureStarted
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(self, sharedLevelControl: sharedLevelControl)
    }

    public func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isMultipleTouchEnabled = true
        context.coordinator.install(in: view)
        return view
    }

    public func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.update(self)
    }

    public static func dismantleUIView(_ view: UIView, coordinator: Coordinator) {
        coordinator.cancel()
    }

    @MainActor
    public final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        private var owner: PlayerTouchGestureSurface
        private var pendingTap: Task<Void, Never>?
        private var pendingDirection: PlayerTouchSkipDirection?
        private var lastTapAt: TimeInterval = 0
        private var holding = false
        private var pinchApplied = false
        private let hold = UILongPressGestureRecognizer()
        private let pinch = UIPinchGestureRecognizer()
        private let pan = UIPanGestureRecognizer()
        private let indicatorPress = UILongPressGestureRecognizer()
        private let levelControl: PlayerTouchLevelControl
        private let ownsLevelControl: Bool
        private var levelDrag: PlayerTouchLevelDrag?
        private var directLevelFrame: CGRect?

        init(_ owner: PlayerTouchGestureSurface, sharedLevelControl: PlayerTouchLevelControl?) {
            self.owner = owner
            levelControl = sharedLevelControl ?? PlayerTouchLevelControl()
            ownsLevelControl = sharedLevelControl == nil
        }

        func install(in view: UIView) {
            let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
            hold.addTarget(self, action: #selector(held(_:)))
            hold.minimumPressDuration = 1
            hold.allowableMovement = 12
            pinch.addTarget(self, action: #selector(pinched(_:)))
            pan.addTarget(self, action: #selector(panned(_:)))
            pan.maximumNumberOfTouches = 1
            indicatorPress.addTarget(self, action: #selector(adjustedIndicator(_:)))
            indicatorPress.minimumPressDuration = 0
            indicatorPress.allowableMovement = .greatestFiniteMagnitude
            for gesture in [tap, hold, pinch, pan, indicatorPress] {
                gesture.allowedPressTypes = []
                gesture.delegate = self
                view.addGestureRecognizer(gesture)
            }
            tap.require(toFail: hold)
            for gesture in [tap, hold, pinch, pan] {
                gesture.require(toFail: indicatorPress)
            }
            update(owner)
        }

        func update(_ owner: PlayerTouchGestureSurface) {
            self.owner = owner
            let enabled = owner.shortcutsEnabled && owner.isActive && !UIAccessibility.isVoiceOverRunning
            hold.isEnabled = enabled && owner.canBoost
            pinch.isEnabled = enabled && owner.canZoom
            pan.isEnabled = owner.levelsEnabled && owner.isActive && !UIAccessibility.isVoiceOverRunning
            indicatorPress.isEnabled = pan.isEnabled
            if !enabled {
                cancelPendingTap()
                finishHold()
                owner.state.isPinching = false
            }
            if !owner.isActive { cancel(restoringBrightness: true) }
        }

        func cancel(restoringBrightness: Bool = false) {
            cancelPendingTap()
            finishHold()
            levelDrag = nil
            directLevelFrame = nil
            if ownsLevelControl || restoringBrightness {
                levelControl.deactivate()
            } else {
                levelControl.endVolume()
            }
            owner.state.clearLevel()
            owner.state.isPinching = false
        }

        private func cancelPendingTap() {
            pendingTap?.cancel()
            pendingTap = nil
            pendingDirection = nil
        }

        @objc private func tapped(_ gesture: UITapGestureRecognizer) {
            guard let view = gesture.view else { return }
            owner.state.clearLevel()
            let x = gesture.location(in: view).x
            let direction: PlayerTouchSkipDirection? = x < view.bounds.width * 0.35
                ? .backward : (x > view.bounds.width * 0.65 ? .forward : nil)
            guard owner.shortcutsEnabled, owner.canSeek,
                  !UIAccessibility.isVoiceOverRunning, let direction else {
                cancelPendingTap()
                owner.state.clearSkip()
                owner.onTap()
                return
            }
            let now = ProcessInfo.processInfo.systemUptime
            if owner.state.skip != nil
                || (pendingTap != nil && pendingDirection == direction && now - lastTapAt <= 0.32) {
                cancelPendingTap()
                owner.onSkip(direction)
                return
            }
            if pendingTap != nil {
                cancelPendingTap()
                owner.onTap()
            }
            pendingDirection = direction
            lastTapAt = now
            pendingTap = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .milliseconds(320)) }
                catch { return }
                guard let self else { return }
                self.pendingTap = nil
                self.pendingDirection = nil
                self.owner.onTap()
            }
        }

        public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard gestureRecognizer === pan || gestureRecognizer === indicatorPress else { return true }
            guard owner.levelsEnabled, owner.isActive, !UIAccessibility.isVoiceOverRunning,
                  let view = gestureRecognizer.view else { return false }
            if gestureRecognizer === indicatorPress {
                guard let window = view.window else { return false }
                return canAdjustIndicator(at: indicatorPress.location(in: window))
            }
            let movement = pan.translation(in: view)
            let startX = pan.location(in: view).x - movement.x
            return abs(movement.y) > abs(movement.x) * 1.25
                && PlayerTouchLevelDrag.kind(at: Double(startX), width: Double(view.bounds.width)) != nil
        }

        private func canAdjustIndicator(at point: CGPoint) -> Bool {
            guard let level = owner.state.level, level.value != nil,
                  let region = owner.state.levelInteractionRegion, region.kind == level.kind else { return false }
            return region.frame.contains(point)
        }

        @objc private func panned(_ gesture: UIPanGestureRecognizer) {
            guard let view = gesture.view else { return }
            let movement = gesture.translation(in: view)
            switch gesture.state {
            case .began:
                guard let kind = PlayerTouchLevelDrag.kind(
                    at: Double(gesture.location(in: view).x - movement.x), width: Double(view.bounds.width)
                ) else { return }
                beginLevel(kind, in: view)
                updateLevel(translationY: Double(movement.y), in: view)
            case .changed:
                updateLevel(translationY: Double(movement.y), in: view)
            case .ended, .cancelled, .failed:
                if gesture.state == .ended { updateLevel(translationY: Double(movement.y), in: view) }
                finishLevelInteraction()
            default:
                break
            }
        }

        @objc private func adjustedIndicator(_ gesture: UILongPressGestureRecognizer) {
            guard let view = gesture.view else { return }
            switch gesture.state {
            case .began:
                guard let level = owner.state.level, level.value != nil,
                      let region = owner.state.levelInteractionRegion, region.kind == level.kind else { return }
                beginLevel(level.kind, in: view, indicatorFrame: region.frame)
                updateIndicator(gesture, in: view)
            case .changed:
                updateIndicator(gesture, in: view)
            case .ended, .cancelled, .failed:
                if gesture.state == .ended { updateIndicator(gesture, in: view) }
                finishLevelInteraction()
            default:
                break
            }
        }

        private func beginLevel(_ kind: PlayerTouchLevel, in view: UIView, indicatorFrame: CGRect? = nil) {
            cancelPendingTap()
            finishHold()
            owner.state.clearSkip()
            owner.onGestureStarted()
            do {
                let initial = try levelControl.begin(kind, in: view)
                directLevelFrame = indicatorFrame
                levelDrag = PlayerTouchLevelDrag(
                    kind: kind, startValue: indicatorFrame == nil ? initial : 1,
                    height: Double(indicatorFrame?.height ?? view.bounds.height), initialFeedbackValue: initial
                )
            } catch {
                levelUnavailable(kind)
            }
        }

        private func updateIndicator(_ gesture: UIGestureRecognizer, in view: UIView) {
            guard let frame = directLevelFrame else { return }
            updateLevel(translationY: Double(gesture.location(in: view.window).y - frame.minY), in: view)
        }

        private func finishLevelInteraction() {
            levelDrag = nil
            directLevelFrame = nil
            levelControl.endVolume()
            owner.state.finishLevel()
        }

        private func updateLevel(translationY: Double, in view: UIView) {
            guard var drag = levelDrag else { return }
            guard let adjustment = drag.adjustment(translationY: translationY) else {
                levelUnavailable(drag.kind)
                return
            }
            do {
                try levelControl.set(drag.kind, value: adjustment.value, in: view)
                if let feedback = drag.feedback(afterApplying: adjustment.value) {
                    TouchFeedback.shared.emit(feedback == .limit ? .impact : .selection)
                }
                levelDrag = drag
                owner.state.showLevel(
                    drag.kind, value: adjustment.value, overshoot: adjustment.overshoot,
                    isDirectInteraction: directLevelFrame != nil
                )
            } catch {
                levelUnavailable(drag.kind)
            }
        }

        private func levelUnavailable(_ kind: PlayerTouchLevel) {
            PlozzLog.playback.error("The player gesture could not adjust the device output.")
            levelDrag = nil
            directLevelFrame = nil
            levelControl.endVolume()
            owner.state.showLevel(kind, value: nil)
            owner.state.finishLevel()
        }

        @objc private func held(_ gesture: UILongPressGestureRecognizer) {
            switch gesture.state {
            case .began:
                cancelPendingTap()
                holding = true
                owner.onBoostChanged(true)
            case .ended, .cancelled, .failed:
                finishHold()
            default:
                break
            }
        }

        private func finishHold() {
            guard holding else { return }
            holding = false
            owner.onBoostChanged(false)
        }

        @objc private func pinched(_ gesture: UIPinchGestureRecognizer) {
            switch gesture.state {
            case .began:
                cancelPendingTap()
                finishHold()
                owner.state.clearSkip()
                owner.state.clearLevel()
                owner.state.isPinching = true
                pinchApplied = false
                owner.onGestureStarted()
            case .changed:
                guard !pinchApplied else { return }
                if gesture.scale > 1.12 || gesture.scale < 0.88 {
                    pinchApplied = true
                    owner.onZoom(gesture.scale > 1)
                }
            case .ended, .cancelled, .failed:
                owner.state.isPinching = false
            default:
                break
            }
        }

        public func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch
        ) -> Bool {
            guard let view = gestureRecognizer.view else { return false }
            if gestureRecognizer === indicatorPress {
                guard let window = view.window else { return false }
                return canAdjustIndicator(at: touch.location(in: window))
            }
            let point = touch.location(in: view)
            // Leave edge-origin system navigation and the home indicator alone.
            let edges = view.safeAreaInsets
            return point.x > max(16, edges.left) && point.x < view.bounds.width - max(16, edges.right)
                && point.y > max(12, edges.top) && point.y < view.bounds.height - max(12, edges.bottom)
        }
    }
}

public struct PlayerTouchGestureFeedbackView: View {
    let state: PlayerTouchGestureState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(state: PlayerTouchGestureState) { self.state = state }

    public var body: some View {
        PlayerTouchGestureFeedbackContent(state: state, reduceMotion: reduceMotion)
            .modifier(WindowSafeAreaPadding())
    }
}

struct PlayerTouchGestureFeedbackContent: View {
    let state: PlayerTouchGestureState
    let reduceMotion: Bool

    var body: some View {
        GeometryReader { geometry in
            if let skip = state.skip {
                HStack(spacing: 4) {
                    if skip.direction == .backward {
                        PlayerTouchSkipChevrons(direction: .backward, pulse: skip.pulse, reduceMotion: reduceMotion)
                    }
                    Text(skip.seconds, format: .number.sign(strategy: .always()).precision(.fractionLength(0)))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: skip.seconds)
                        .accessibilityIdentifier("player-gesture-skip-total")
                    if skip.direction == .forward {
                        PlayerTouchSkipChevrons(direction: .forward, pulse: skip.pulse, reduceMotion: reduceMotion)
                    }
                }
                .modifier(PlayerTouchFeedbackPill())
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("player-gesture-skip-pill")
                .position(x: geometry.size.width * (skip.direction == .backward ? 0.22 : 0.78),
                          y: geometry.size.height / 2)
                .environment(\.layoutDirection, .leftToRight)
            }
            if let rate = state.boostRate {
                HStack(spacing: 8) {
                    Text(verbatim: rate.formatted(.number.precision(.fractionLength(0...2))) + "×")
                        .monospacedDigit()
                        .accessibilityIdentifier("player-gesture-speed")
                    Image(systemName: "forward.fill")
                        .accessibilityHidden(true)
                }
                .modifier(PlayerTouchFeedbackPill())
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("player-gesture-speed-pill")
                .padding(.top, 16)
                .frame(maxWidth: .infinity)
            }
            ZStack {
                if let level = state.level {
                    let inset = level.value == nil ? geometry.size.width * 0.22 : 8 + 44 / 2
                    let x = level.kind == .brightness ? inset : geometry.size.width - inset
                    Group {
                        if let value = level.value {
                            PlayerTouchLevelMeter(
                                kind: level.kind, value: value, overshoot: level.overshoot,
                                isDragging: level.isDragging, isDirectInteraction: level.isDirectInteraction,
                                reduceMotion: reduceMotion,
                                onFrameChange: { state.levelInteractionRegion = (level.kind, $0) }
                            )
                        } else {
                            HStack(spacing: 8) {
                                Image(systemName: level.kind == .brightness ? "sun.max.fill" : "speaker.wave.2.fill")
                                    .accessibilityHidden(true)
                                Text(level.kind == .brightness ? "Brightness unavailable" : "Volume unavailable")
                                    .accessibilityIdentifier("player-gesture-level-unavailable")
                            }
                            .modifier(PlayerTouchFeedbackPill())
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("player-gesture-level-pill")
                    .position(x: x, y: geometry.size.height / 2)
                    .transition(level.value == nil ? .opacity : reduceMotion ? .identity : .offset(
                        x: level.kind == .brightness ? -60 : 60
                    ).combined(with: .scale(
                        scale: 0.8, anchor: UnitPoint(x: x / max(geometry.size.width, 1), y: 0.5)
                    )))
                    .environment(\.layoutDirection, .leftToRight)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
            .animation(.easeInOut(duration: 0.24), value: state.level != nil)
        }
        .foregroundStyle(.white)
        .allowsHitTesting(false)
    }
}

private struct PlayerTouchLevelMeter: View {
    let kind: PlayerTouchLevel
    let value: Double
    let overshoot: Double
    let isDragging: Bool
    let isDirectInteraction: Bool
    let reduceMotion: Bool
    let onFrameChange: (CGRect) -> Void

    var body: some View {
        let stretch = reduceMotion ? 0 : 20 * (overshoot / (abs(overshoot) + 80))
        let height = 156 + abs(stretch)
        let width: Double = isDirectInteraction ? 44 : 32
        ZStack(alignment: .bottom) {
            PlayerScrubTrackSurface(height: height)
            PlayerTouchProgressFill(isActive: isDragging)
                .frame(height: height * value)
            icon.foregroundStyle(.white)
            icon.foregroundStyle(.black)
                .mask(alignment: .bottom) {
                    Rectangle().frame(height: height * value)
                }
        }
        .frame(width: width * 156 / height, height: height)
        .clipShape(Capsule())
        .offset(y: -stretch / 2)
        .frame(width: width, height: 156)
        .frame(width: 44, height: 156, alignment: kind == .brightness ? .leading : .trailing)
        .animation(
            .spring(response: 0.35, dampingFraction: 0.72),
            value: animationPhase
        )
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { onFrameChange($0) }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(kind == .brightness ? "Brightness" : "Volume")
        .accessibilityValue(Text(value, format: .percent.precision(.fractionLength(0))))
        .accessibilityIdentifier("player-gesture-level-value")
    }

    private var animationPhase: Int? {
        guard !reduceMotion else { return nil }
        if isDirectInteraction { return 1 }
        return isDragging ? nil : 0
    }

    private var icon: some View {
        Image(systemName: kind.systemImage(at: value))
            .font(.system(size: 16, weight: .semibold))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, 18)
            .accessibilityHidden(true)
    }
}

private struct PlayerTouchFeedbackPill: ViewModifier {
    @Environment(\.playerControlForeground) private var foreground

    func body(content: Content) -> some View {
        content
            .font(.callout.weight(.semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .modifier(PanelGlassBackground(cornerRadius: 999, mediaGlass: true))
    }
}

private struct PlayerTouchSkipChevrons: View {
    let direction: PlayerTouchSkipDirection
    let pulse: Int
    let reduceMotion: Bool
    @State private var activePulses: [Int] = []

    var body: some View {
        Image(systemName: "chevron.right")
            .hidden()
            .frame(height: 30)
            .overlay {
                ZStack {
                    if reduceMotion {
                        Image(systemName: "chevron.right")
                    } else {
                        ForEach(activePulses, id: \.self) { id in
                            PlayerTouchSkipChevronFlight {
                                activePulses.removeAll { $0 == id }
                            }
                            .transition(.identity)
                        }
                    }
                }
                .scaleEffect(x: direction == .forward ? 1 : -1, y: 1)
            }
            .padding(
                direction == .forward ? .trailing : .leading,
                reduceMotion ? 0 : PlayerTouchSkipChevronFlight.travelDistance
            )
            .onChange(of: pulse, initial: true) {
                guard !reduceMotion else { return }
                activePulses.append(pulse)
            }
            .onChange(of: reduceMotion) { activePulses.removeAll() }
            .onDisappear { activePulses.removeAll() }
            .accessibilityHidden(true)
    }
}

private struct PlayerTouchSkipChevronFlight: View {
    static let travelDistance: CGFloat = 20
    private static let travelDuration = 0.25
    private static let holdDuration = 0.5
    private static let fadeDuration = 0.3

    let onCompletion: () -> Void
    @State private var isTraveling = false

    var body: some View {
        Image(systemName: "chevron.right")
            .scaleEffect(x: isTraveling ? 1 : 0.45, y: 1)
            .offset(x: isTraveling ? Self.travelDistance : 0)
            .animation(.easeOut(duration: Self.travelDuration), value: isTraveling)
            .opacity(isTraveling ? 0 : 1)
            .onAppear {
                withAnimation(
                    .easeIn(duration: Self.fadeDuration).delay(Self.travelDuration + Self.holdDuration),
                    completionCriteria: .removed
                ) {
                    isTraveling = true
                } completion: {
                    onCompletion()
                }
            }
    }
}
#endif
