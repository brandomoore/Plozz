#if os(iOS)
import CoreMotion
import CoreNetworking
import UIKit

struct PlozziOSLandscapeDirection {
    private var candidate: UIInterfaceOrientation?

    mutating func update(x: Double, y: Double, z: Double) -> UIInterfaceOrientation? {
        guard x.isFinite, y.isFinite, z.isFinite,
              abs(x) > 0.75, abs(y) < 0.6, abs(z) < 0.7 else {
            candidate = nil
            return nil
        }
        // Gravity is in device coordinates; interface left/right use the opposite convention.
        let direction: UIInterfaceOrientation = x > 0 ? .landscapeLeft : .landscapeRight
        defer { candidate = direction }
        return candidate == direction ? direction : nil
    }
}

/// One sensor source, leased only by the active compact-phone landscape player.
@MainActor
final class PlozziOSLandscapeMotion {
    static let shared = PlozziOSLandscapeMotion()
    private let manager = CMMotionManager()
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "Plozz.player-orientation"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        return queue
    }()
    private weak var owner: PlozziOSOrientationHostingController?
    private var generation = 0

    func start(for owner: PlozziOSOrientationHostingController) {
        guard self.owner !== owner else { return }
        stopUpdates()
        self.owner = owner
        guard manager.isDeviceMotionAvailable else {
            PlozzLog.playback.info("Landscape motion unavailable; using system landscape rotation.")
            return
        }
        let generation = generation
        manager.deviceMotionUpdateInterval = 0.2
        manager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: queue) { [weak self, weak owner] motion, error in
            let gravity = motion?.gravity
            let failure = error?.localizedDescription
            Task { @MainActor [weak self, weak owner] in
                guard let self, self.generation == generation else { return }
                guard let owner, self.owner === owner else {
                    self.stopUpdates()
                    return
                }
                if let failure {
                    PlozzLog.playback.error("Landscape motion failed: \(failure)")
                    self.stopUpdates()
                    return
                }
                guard owner.tracksLandscapeMotion else {
                    self.stop(for: owner)
                    return
                }
                if let gravity {
                    owner.receiveLandscapeGravity(x: gravity.x, y: gravity.y, z: gravity.z)
                }
            }
        }
    }

    func stop(for owner: PlozziOSOrientationHostingController) {
        guard self.owner === owner else { return }
        stopUpdates()
        self.owner = nil
    }

    private func stopUpdates() {
        generation += 1
        manager.stopDeviceMotionUpdates()
    }
}
#endif
