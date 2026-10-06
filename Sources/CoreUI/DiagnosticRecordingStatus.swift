#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UIKit

#if DEBUG
import CoreModels
import CoreNetworking
import notify

enum DiagnosticRecordingPhase: String, CaseIterable {
    case preparing, recording, finished, failed

    var notification: String { "\(Bundle.main.bundleIdentifier ?? "com.thatcube.Plozz").Diagnostics.\(rawValue)" }
    var acknowledgement: String { notification + ".visible" }
    var lifetime: TimeInterval { self == .preparing ? 30 : self == .recording ? 15 : 8 }

    var text: LocalizedStringResource {
        switch self {
        case .preparing:
            LocalizedStringResource("Preparing recording - please wait", comment: "Diagnostic recording status. Wait before performing the action being recorded.")
        case .recording:
            LocalizedStringResource("Recording", comment: "Diagnostic recording status beside a red recording dot. Recording is active and the requested action can now be performed.")
        case .finished:
            LocalizedStringResource("Recording finished", comment: "Diagnostic recording has completed.")
        case .failed:
            LocalizedStringResource("Recording stopped - do not repeat", comment: "Diagnostic recording stopped unexpectedly. Do not repeat the requested action until another recording is ready.")
        }
    }
}

@MainActor
final class DiagnosticRecordingController {
    private weak var window: UIWindow?
    private var tokens: [Int32] = []
    private var expiry: Task<Void, Never>?
    private(set) var phase: DiagnosticRecordingPhase?
    private(set) var badge: UILabel?

    deinit {
        expiry?.cancel()
        for token in tokens { notify_cancel(token) }
    }

    func attach(to window: UIWindow?) {
        // UIKit removes the presenting view during a full-screen cover.
        // The window and this receiver must outlive that temporary detachment.
        guard let window else { return }
        guard self.window !== window else { return }
        invalidate()
        self.window = window
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
        guard let window, window.windowScene?.activationState == .foregroundActive else { return }
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
            label.layer.zPosition = 100_000
            label.translatesAutoresizingMaskIntoConstraints = false
            window.addSubview(label)
            NSLayoutConstraint.activate([
                label.topAnchor.constraint(equalTo: window.safeAreaLayoutGuide.topAnchor, constant: 16),
                label.trailingAnchor.constraint(equalTo: window.safeAreaLayoutGuide.trailingAnchor, constant: -20),
                label.leadingAnchor.constraint(greaterThanOrEqualTo: window.safeAreaLayoutGuide.leadingAnchor, constant: 20),
                label.widthAnchor.constraint(lessThanOrEqualToConstant: 600),
                label.heightAnchor.constraint(greaterThanOrEqualToConstant: 64)
            ])
            badge = label
        }
        if changed {
            let text = String(localized: phase.text)
            let indicator = phase == .recording ? "\u{25CF}  " : ""
            let status = NSMutableAttributedString(string: "  \(indicator)\(text)  ") // l10n:content — localized UIKit status label
            if phase == .recording {
                status.addAttribute(.foregroundColor, value: UIColor.systemRed, range: NSRange(location: 2, length: 1))
            }
            label.attributedText = status
            label.accessibilityLabel = text
            label.backgroundColor = UIColor(white: 0.12, alpha: 1)
            window.layoutIfNeeded()
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
        let status = notify_post(phase.acknowledgement)
        if status != UInt32(NOTIFY_STATUS_OK) {
            PlozzLog.boot("diagnostic recording acknowledgement failed: \(status)")
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
        badge?.removeFromSuperview()
        badge = nil
        phase = nil
    }

    func invalidate() {
        expiry?.cancel()
        expiry = nil
        for token in tokens { notify_cancel(token) }
        tokens.removeAll()
        clearBadge()
        window = nil
    }
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
