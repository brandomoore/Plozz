#if canImport(SwiftUI)
import CoreModels
import CoreNetworking
import Foundation
import SwiftUI

/// Main-actor wake-up delay. Scheduling overshoot is neither presented-frame
/// timing nor proof that the main thread was blocked for that entire interval.
/// The legacy console probe is separately opt-in through `PLZSTALL=1`.
@MainActor
public enum MainThreadStallProbe {
    /// Coarse scheduling samples, deliberately slower than display refresh.
    private static let interval: Duration = .milliseconds(100)

    /// Only overshoots beyond this are worth a line. One frame at 60 Hz is
    /// ~16 ms; 150 ms is already a visible stutter rather than scheduling noise.
    private static let reportThreshold: Duration = .milliseconds(150)

    private static var running = false

    /// Whether `Self._printChanges()` probes in view bodies should run. Same
    /// opt-in switch as the stall probe, so a diagnosis session turns on both
    /// and a shipping run pays for neither.
    public static let printsChanges: Bool =
        ProcessInfo.processInfo.environment["PLZSTALL"] == "1"

    /// The app shell listens for screen changes to update the opt-in crash
    /// reporter's fixed-category tag, even when the local stall probe is off.
    public static let contextDidChange = Notification.Name("PlozzScreenContextDidChange")

    /// What the app believes is on screen, so a stall can be attributed without
    /// a symbolicated stack. Set by screens that opt in; free-form and
    /// developer-facing only.
    public static var context: String = "startup" {  // l10n:content — developer-facing diagnostic
        didSet {
            if context != oldValue {
                NotificationCenter.default.post(name: contextDidChange, object: nil)
            }
        }
    }

    /// A passive sink, deliberately not observable: samples must not invalidate Home.
    @MainActor
    final class HomeResponsivenessProbe {
        var isScrolling = false
        var isLoading = false
        private var observation: PerformanceDiagnostics.HomeObservation?
        private var metrics = PerformanceDiagnostics.HomeUIMetrics()

        func noteHeight(from old: CGFloat, to new: CGFloat) {
            guard observation?.isCurrent == true, old.isFinite, new.isFinite, old > 0, new >= 0 else { return }
            let delta = abs(new - old)
            guard delta >= 0.5 else { return }
            metrics.heightChanges = min(PerformanceDiagnostics.maximumCount, metrics.heightChanges + 1)
            metrics.maximumHeightDeltaPoints = max(
                metrics.maximumHeightDeltaPoints,
                Int(min(CGFloat(PerformanceDiagnostics.maximumCount), delta.rounded(.up)))
            )
        }

        func run(diagnostics: PerformanceDiagnostics) async {
            guard !Task.isCancelled, let observation = diagnostics.beginHomeObservation() else { return }
            self.observation = observation
            metrics = .init()
            defer {
                if self.observation === observation {
                    if metrics.samples > 0 { observation.record(metrics) }
                    observation.stop()
                    self.observation = nil
                    metrics = .init()
                }
            }
            let clock = ContinuousClock()
            var windowStarted = clock.now
            while !Task.isCancelled, observation.isCurrent {
                let started = clock.now
                do { try await Task.sleep(for: MainThreadStallProbe.interval) } catch { return }
                guard !Task.isCancelled, observation.isCurrent else { return }
                let now = clock.now
                let delay = max(0, min(
                    PerformanceDiagnostics.maximumMilliseconds,
                    (started.duration(to: now) - MainThreadStallProbe.interval).milliseconds
                ))
                metrics.samples += 1
                if delay >= PerformanceDiagnostics.homeDelayThresholdMilliseconds { metrics.delayedSamples += 1 }
                metrics.maximumDelayMilliseconds = max(metrics.maximumDelayMilliseconds, delay)
                if isScrolling { metrics.scrollingSamples += 1 }
                if isLoading { metrics.loadingSamples += 1 }
                let shares = ShareBackgroundActivity.snapshot()
                metrics.maximumActiveScans = max(metrics.maximumActiveScans, shares.scans)
                metrics.maximumActiveListers = max(metrics.maximumActiveListers, shares.activeListers)
                if windowStarted.duration(to: now) >= .seconds(1) {
                    guard observation.record(metrics) else { return }
                    metrics = .init()
                    windowStarted = now
                }
            }
        }
    }

    @MainActor
    struct HomeResponsivenessModifier: ViewModifier {
        let isEnabled: Bool
        let scope: ObjectIdentifier
        let isScrolling: Bool
        let isLoading: Bool
        let diagnostics: PerformanceDiagnostics
        @Environment(\.scenePhase) private var scenePhase
        @State private var probe = HomeResponsivenessProbe()

        init(
            isEnabled: Bool, scope: ObjectIdentifier, isScrolling: Bool, isLoading: Bool,
            diagnostics: PerformanceDiagnostics = .shared
        ) {
            self.isEnabled = isEnabled
            self.scope = scope
            self.isScrolling = isScrolling
            self.isLoading = isLoading
            self.diagnostics = diagnostics
        }

        private struct TaskKey: Equatable {
            let enabled: Bool
            let scope: ObjectIdentifier
        }

        func body(content: Content) -> some View {
            let key = TaskKey(enabled: isEnabled && scenePhase == .active, scope: scope)
            content
                .onChange(of: isScrolling, initial: true) { _, value in probe.isScrolling = value }
                .onChange(of: isLoading, initial: true) { _, value in probe.isLoading = value }
                .onScrollGeometryChange(for: CGFloat.self) { $0.contentSize.height } action: { old, new in
                    probe.noteHeight(from: old, to: new)
                }
                .task(id: key) {
                    guard key.enabled else { return }
                    await probe.run(diagnostics: diagnostics)
                }
        }
    }

    public static func startIfRequested() {
        guard ProcessInfo.processInfo.environment["PLZSTALL"] == "1", !running else { return }
        running = true
        PlozzLog.boot("stall-probe armed (interval 100ms, report >150ms)")
        Task { @MainActor in
            let clock = ContinuousClock()
            var last = clock.now
            var worst = Duration.zero
            while true {
                try? await Task.sleep(for: interval)
                let now = clock.now
                let overshoot = last.duration(to: now) - interval
                last = now
                guard overshoot >= reportThreshold else { continue }
                if overshoot > worst { worst = overshoot }
                PlozzLog.boot(
                    "STALL \(overshoot.milliseconds)ms (worst \(worst.milliseconds)ms) "
                        + "screen=\(context)"
                )
            }
        }
    }
}

private extension Duration {
    /// Whole milliseconds, for log lines.
    var milliseconds: Int { Int(components.seconds * 1000 + components.attoseconds / 1_000_000_000_000_000) }
}

/// Runs `dump` (normally `Self._printChanges()`) only when the diagnostic flag
/// is set.
///
/// Written to be called as `let _ = plozzPrintChanges { … }` inside a `body`.
/// The obvious `if flag { Self._printChanges() }; return someView` form is a
/// trap: an explicit `return` **disables the `ViewBuilder`**, so the whole view
/// tree becomes one expression and the Swift type-checker gives up on any body
/// of real size.
@inlinable
public func plozzPrintChanges(_ dump: () -> Void) {
    if MainThreadStallProbe.printsChanges { dump() }
}

public extension View {
    @MainActor
    func homeResponsivenessDiagnostics(
        isEnabled: Bool, scope: ObjectIdentifier, isScrolling: Bool, isLoading: Bool
    ) -> some View {
        modifier(MainThreadStallProbe.HomeResponsivenessModifier(
            isEnabled: isEnabled, scope: scope, isScrolling: isScrolling, isLoading: isLoading
        ))
    }

    /// Names the screen a main-thread stall should be attributed to. No-op
    /// unless the probe is armed.
    func plozzStallContext(_ name: String) -> some View {
        onAppear { MainThreadStallProbe.context = name }
    }
}
#endif
