#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UIKit

#if DEBUG
import CoreModels
import CoreNetworking
import notify

enum DiagnosticRecordingPhase: String, CaseIterable {
    case preparing, ready, recording, saving, finished, failed

    var notification: String { "\(Bundle.main.bundleIdentifier ?? "com.thatcube.Plozz").Diagnostics.\(rawValue)" }
    var acknowledgement: String { notification + ".visible" }
    var lifetime: TimeInterval {
        switch self {
        case .preparing, .ready, .recording, .saving: 15
        case .finished, .failed: 8
        }
    }

    var text: LocalizedStringResource {
        switch self {
        case .preparing:
            LocalizedStringResource("Preparing recording - please wait", comment: "Diagnostic recording status. Wait before performing the action being recorded.")
        case .recording:
            LocalizedStringResource("Recording", comment: "Diagnostic recording status beside a red recording dot. Recording is active and the requested action can now be performed.")
        case .ready:
            LocalizedStringResource("Ready to record", comment: "Diagnostic recorder is ready and waiting for the user to confirm starting the capture.")
        case .saving:
            LocalizedStringResource("Saving recording", comment: "The diagnostic capture has stopped and is being saved and verified.")
        case .finished:
            LocalizedStringResource("Recording finished", comment: "Diagnostic recording has completed.")
        case .failed:
            LocalizedStringResource("Recording failed", comment: "The diagnostic recording could not start or did not produce a verified capture.")
        }
    }
}

@MainActor
final class DiagnosticRecordingController {
    private weak var scene: UIWindowScene?
    private var tokens: [Int32] = []
    private var expiry: Task<Void, Never>?
    private var acknowledgement: Task<Void, Never>?
    private(set) var overlayWindow: UIWindow?
    private(set) var phase: DiagnosticRecordingPhase?
    private(set) var badge: UILabel?

    deinit {
        expiry?.cancel()
        acknowledgement?.cancel()
        for token in tokens { notify_cancel(token) }
    }

    func attach(to window: UIWindow?) {
        // Full-screen presentation can detach the probe or replace its window.
        // The receiver and non-key overlay belong to the scene, not that surface.
        guard let scene = window?.windowScene else { return }
        guard self.scene !== scene else { return }
        invalidate()
        self.scene = scene
        for phase in DiagnosticRecordingPhase.allCases {
            var token: Int32 = 0
            let status = notify_register_dispatch(phase.notification, &token, .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.receive(phase) }
            }
            guard status == UInt32(NOTIFY_STATUS_OK) else {
                PlozzLog.boot("diagnostic recording notification registration failed: \(status)")
                invalidate()
                return
            }
            tokens.append(token)
        }
    }

    func receive(_ phase: DiagnosticRecordingPhase) {
        guard let scene, scene.activationState == .foregroundActive else { return }
        expiry?.cancel()
        let changed = self.phase != phase
        self.phase = phase
        if changed, let imagePhase = DiagnosticImageMap.Phase(rawValue: phase.rawValue) {
            DiagnosticImageMap.record(imagePhase)
        }
        let label: UILabel
        if let badge {
            label = badge
        } else {
            let window = DiagnosticRecordingWindow(windowScene: scene)
            window.windowLevel = .alert + 1
            window.backgroundColor = .clear
            window.isUserInteractionEnabled = false
            let host = UIViewController()
            host.view.backgroundColor = .clear
            host.view.isUserInteractionEnabled = false
            window.rootViewController = host
            overlayWindow = window
            label = UILabel()
            label.isUserInteractionEnabled = false
            label.accessibilityIdentifier = "diagnostic-recording-status"
            label.textAlignment = .center
            label.numberOfLines = 2
            #if os(tvOS)
            label.font = .systemFont(ofSize: 25, weight: .semibold)
            #else
            label.font = .systemFont(ofSize: 15, weight: .semibold)
            #endif
            label.textColor = .white
            label.layer.cornerRadius = 12
            label.clipsToBounds = true
            label.translatesAutoresizingMaskIntoConstraints = false
            host.view.addSubview(label)
            NSLayoutConstraint.activate([
                label.topAnchor.constraint(equalTo: host.view.safeAreaLayoutGuide.topAnchor, constant: 16),
                label.trailingAnchor.constraint(equalTo: host.view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
                label.leadingAnchor.constraint(greaterThanOrEqualTo: host.view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
                label.widthAnchor.constraint(lessThanOrEqualToConstant: 600),
                label.heightAnchor.constraint(greaterThanOrEqualToConstant: 64)
            ])
            badge = label
            window.isHidden = false
        }
        if changed {
            let text = String(localized: phase.text) // l10n:content - UIKit status boundary; resolved when the diagnostic phase changes.
            let indicator = phase == .recording ? "\u{25CF}  " : ""
            let status = NSMutableAttributedString(string: "  \(indicator)\(text)  ") // l10n:content — localized UIKit status label
            if phase == .recording {
                status.addAttribute(.foregroundColor, value: UIColor.systemRed, range: NSRange(location: 2, length: 1))
            }
            label.attributedText = status
            label.accessibilityLabel = text
            label.backgroundColor = UIColor(white: 0.12, alpha: 1)
            overlayWindow?.layoutIfNeeded()
            overlayWindow?.rootViewController?.view.layoutIfNeeded()
        }
        label.layer.removeAnimation(forKey: "recording-expiry")
        label.layer.opacity = 1
        // The render server expires a stale "recording" badge even if the app's
        // main thread freezes before it can handle the stop notification.
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [1, 1, 0]
        fade.keyTimes = [0, 0.99, 1]
        fade.duration = phase.lifetime
        fade.fillMode = .forwards
        fade.isRemovedOnCompletion = false
        label.layer.add(fade, forKey: "recording-expiry")
        acknowledgement?.cancel()
        acknowledgement = Task { [weak self, weak label] in
            await Task.yield()
            guard !Task.isCancelled, let self, let label,
                  self.phase == phase, self.badge === label,
                  let window = self.overlayWindow,
                  window.windowScene?.activationState == .foregroundActive,
                  !window.isHidden, window.alpha > 0, label.window === window,
                  !label.bounds.isEmpty,
                  window.bounds.contains(label.convert(label.bounds, to: window)) else { return }
            let status = notify_post(phase.acknowledgement)
            if status != UInt32(NOTIFY_STATUS_OK) {
                PlozzLog.boot("diagnostic recording acknowledgement failed: \(status)")
            }
        }
        expiry = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(phase.lifetime))
            } catch is CancellationError {
                return
            } catch {
                PlozzLog.boot("diagnostic recording expiry failed: \(error)")
            }
            self?.clearBadge()
        }
    }

    func clearBadge() {
        acknowledgement?.cancel()
        acknowledgement = nil
        badge?.removeFromSuperview()
        badge = nil
        overlayWindow?.isHidden = true
        overlayWindow?.rootViewController = nil
        overlayWindow = nil
        phase = nil
    }

    func invalidate() {
        expiry?.cancel()
        expiry = nil
        for token in tokens { notify_cancel(token) }
        tokens.removeAll()
        clearBadge()
        scene = nil
    }
}

private final class DiagnosticRecordingWindow: UIWindow {
    override var canBecomeKey: Bool { false }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }
}

private struct DiagnosticRecordingInstaller: UIViewRepresentable {
    func makeCoordinator() -> DiagnosticRecordingController { DiagnosticRecordingController() }

    func makeUIView(context: Context) -> WindowProbe {
        let probe = WindowProbe()
        probe.isUserInteractionEnabled = false
        probe.onWindowChange = { [weak coordinator = context.coordinator] window in
            coordinator?.attach(to: window)
        }
        return probe
    }

    func updateUIView(_ view: WindowProbe, context: Context) {}

    static func dismantleUIView(_ view: WindowProbe, coordinator: DiagnosticRecordingController) {
        view.onWindowChange = nil
        coordinator.invalidate()
    }

    final class WindowProbe: UIView {
        var onWindowChange: ((UIWindow?) -> Void)?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            onWindowChange?(window)
        }
    }
}
#endif

public extension View {
    /// A local-build-only status receiver; it never starts recording or accepts input.
    func diagnosticRecordingStatus() -> some View {
        #if DEBUG
        background(DiagnosticRecordingInstaller().frame(width: 0, height: 0))
        #else
        self
        #endif
    }
}
#endif
