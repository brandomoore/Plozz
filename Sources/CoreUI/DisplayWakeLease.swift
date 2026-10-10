#if canImport(UIKit)
import UIKit

@MainActor
final class DisplayWakeGroup {
    private var holders: Set<UUID> = []
    private let updateIdleTimer: @MainActor (Bool) -> Void

    init(updateIdleTimer: @escaping @MainActor (Bool) -> Void) {
        self.updateIdleTimer = updateIdleTimer
    }

    fileprivate func setAwake(_ awake: Bool, holder: UUID) {
        if awake { holders.insert(holder) }
        else { holders.remove(holder) }
        updateIdleTimer(!holders.isEmpty)
    }
}

/// Each surface releases only its own assertion, never another activity's wake lock.
@MainActor
public final class DisplayWakeLease {
    private static let sharedGroup = DisplayWakeGroup { awake in
        if UIApplication.shared.isIdleTimerDisabled != awake {
            UIApplication.shared.isIdleTimerDisabled = awake
        }
    }
    let group: DisplayWakeGroup
    private let id = UUID()

    public init() {
        group = Self.sharedGroup
    }

    init(group: DisplayWakeGroup) {
        self.group = group
    }

    public func keepAwake(_ awake: Bool) {
        group.setAwake(awake, holder: id)
    }

    public func allowSleep() { keepAwake(false) }

    deinit {
        let id = id
        let group = group
        Task { @MainActor in
            group.setAwake(false, holder: id)
        }
    }
}
#endif
