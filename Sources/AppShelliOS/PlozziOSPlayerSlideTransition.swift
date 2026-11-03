#if os(iOS)
import CoreNetworking
import UIKit

@MainActor
final class PlozziOSPlayerSlideTransition: NSObject, UIViewControllerTransitioningDelegate,
    UIViewControllerAnimatedTransitioning {
    private var snapshot: UIView?
    private var sourceSize = CGSize.zero
    private var sourcePoints: [CGPoint] = []
    private var coordinateSpace: (any UICoordinateSpace)?

    func prepare(_ view: UIView) -> Bool {
        guard let window = view.window, let snapshot = view.snapshotView(afterScreenUpdates: false) else {
            PlozzLog.playback.error("Could not capture the outgoing player for its slide transition.")
            return false
        }
        sourceSize = view.bounds.size
        guard sourceSize.width > 0, sourceSize.height > 0 else {
            PlozzLog.playback.error("The outgoing player has no visible transition bounds.")
            return false
        }
        let space = window.screen.fixedCoordinateSpace
        sourcePoints = [
            CGPoint.zero, CGPoint(x: sourceSize.width, y: 0), CGPoint(x: 0, y: sourceSize.height)
        ].map { window.convert(view.convert($0, to: window), to: space) }
        coordinateSpace = space
        snapshot.accessibilityIdentifier = "player-transition-snapshot"
        snapshot.accessibilityElementsHidden = true
        snapshot.isUserInteractionEnabled = false
        self.snapshot = snapshot
        return true
    }

    func animationController(forDismissed dismissed: UIViewController) -> (any UIViewControllerAnimatedTransitioning)? {
        snapshot == nil ? nil : self
    }

    func transitionDuration(using transitionContext: (any UIViewControllerContextTransitioning)?) -> TimeInterval {
        0.35
    }

    func animateTransition(using context: any UIViewControllerContextTransitioning) {
        guard let snapshot, let coordinateSpace, sourcePoints.count == 3,
              let outgoing = context.view(forKey: .from),
              let incoming = context.view(forKey: .to),
              let destination = context.viewController(forKey: .to) else {
            PlozzLog.playback.error("Player slide transition is missing its presentation context.")
            self.snapshot = nil
            self.coordinateSpace = nil
            sourcePoints = []
            context.completeTransition(!context.transitionWasCancelled)
            return
        }
        let container = context.containerView
        let points = sourcePoints.map { container.convert($0, from: coordinateSpace) }
        let origin = points[0]
        let across = CGPoint(x: points[1].x - origin.x, y: points[1].y - origin.y)
        let down = CGPoint(x: points[2].x - origin.x, y: points[2].y - origin.y)
        incoming.frame = context.finalFrame(for: destination)
        container.insertSubview(incoming, belowSubview: outgoing)
        snapshot.bounds = CGRect(origin: .zero, size: sourceSize)
        snapshot.transform = CGAffineTransform(
            a: across.x / sourceSize.width, b: across.y / sourceSize.width,
            c: down.x / sourceSize.height, d: down.y / sourceSize.height, tx: 0, ty: 0
        )
        snapshot.center = CGPoint(x: origin.x + (across.x + down.x) / 2,
                                  y: origin.y + (across.y + down.y) / 2)
        container.addSubview(snapshot)
        outgoing.isHidden = true
        let start = snapshot.center
        UIView.animate(withDuration: transitionDuration(using: context), delay: 0, options: [.curveEaseInOut]) {
            snapshot.center = CGPoint(x: start.x + down.x, y: start.y + down.y)
        } completion: { [weak self] _ in
            outgoing.isHidden = false
            context.completeTransition(!context.transitionWasCancelled)
            snapshot.removeFromSuperview()
            self?.snapshot = nil
            self?.coordinateSpace = nil
            self?.sourcePoints = []
        }
    }
}
#endif
