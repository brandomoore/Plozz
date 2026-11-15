#if canImport(SwiftUI)
import Foundation
#if os(iOS)
import UIKit
#endif

@MainActor
public final class TouchFeedback: NSObject {
    public enum Event: Equatable, Sendable {
        case impact
        case selection
        case confirmation
        case error
        case tension(intensity: Double)
        case pop
    }

    public static let shared = TouchFeedback()
    private let output: (Event) -> Void
    private let isActive: () -> Bool
    private var activityGeneration: UInt64 = 0

    init(
        output: @escaping (Event) -> Void,
        isActive: @escaping () -> Bool
    ) {
        self.output = output
        self.isActive = isActive
        super.init()
        #if os(iOS)
        NotificationCenter.default.addObserver(
            self, selector: #selector(invalidatePendingConfirmations),
            name: UIApplication.willResignActiveNotification, object: nil
        )
        #endif
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    private override convenience init() {
        #if os(iOS)
        let impact = UIImpactFeedbackGenerator(style: .light)
        let selection = UISelectionFeedbackGenerator()
        let confirmation = UINotificationFeedbackGenerator()
        let tension = UIImpactFeedbackGenerator(style: .heavy)
        let pop = UIImpactFeedbackGenerator(style: .rigid)
        #endif
        self.init(output: { event in
            #if os(iOS)
            switch event {
            case .impact: impact.impactOccurred(intensity: 0.6)
            case .selection: selection.selectionChanged()
            case .confirmation: confirmation.notificationOccurred(.success)
            case .error: confirmation.notificationOccurred(.error)
            case .tension(let intensity):
                tension.impactOccurred(intensity: CGFloat(intensity))
                tension.prepare()
                pop.prepare()
            case .pop: pop.impactOccurred(intensity: 1)
            }
            #endif
        }, isActive: {
            #if os(iOS)
            UIApplication.shared.applicationState == .active
            #else
            false
            #endif
        })
    }

    public func emit(_ event: Event) {
        guard isActive() else { return }
        output(event)
    }

    @objc public func invalidatePendingConfirmations() {
        activityGeneration &+= 1
    }

    public func acknowledgeAction(
        onCompletion event: Event = .confirmation,
        isRelevant: @escaping () -> Bool = { true }
    ) -> @MainActor @Sendable () -> Void {
        let complete = completionFeedback(event, isRelevant: isRelevant)
        emit(.impact)
        return complete
    }

    /// Capture at the gesture, invoke only after success in the same foreground session.
    public func confirmation(isRelevant: @escaping () -> Bool = { true }) -> @MainActor @Sendable () -> Void {
        completionFeedback(.confirmation, isRelevant: isRelevant)
    }

    private func completionFeedback(
        _ event: Event,
        isRelevant: @escaping () -> Bool
    ) -> @MainActor @Sendable () -> Void {
        let generation = activityGeneration
        let beganWhileActive = isActive()
        var consumed = false
        return { [weak self] in
            guard !consumed else { return }
            consumed = true
            guard let self, beganWhileActive,
                  self.activityGeneration == generation, isRelevant() else { return }
            self.emit(event)
        }
    }
}
#endif
