#if os(iOS)
import SwiftUI
import UIKit

/// Selection artwork only. Neither the snapshot nor either of its endpoints
/// depends on a SwiftUI update after the button fires.
@MainActor
final class PlozziOSProfileAvatarFlight {
    private let tiles = NSMapTable<NSString, UIView>.strongToWeakObjects()
    fileprivate weak var viewport: Viewport?
    private(set) var profileID: String?

    fileprivate func register(_ marker: UIView, for id: String) {
        tiles.setObject(marker, forKey: id as NSString)
    }

    func start(profileID: String, targetSize: CGFloat, reduceMotion: Bool) {
        guard let viewport, let marker = tiles.object(forKey: profileID as NSString),
              let window = marker.window, viewport.window === window else { return }
        viewport.layoutIfNeeded()
        let crop = marker.convert(marker.bounds, to: window)
        guard crop.width > 0, crop.height > 0, !viewport.bounds.isEmpty,
              window.bounds.contains(crop),
              let avatar = window.resizableSnapshotView(
                from: crop, afterScreenUpdates: false, withCapInsets: .zero
              ) else { return }
        self.profileID = profileID
        viewport.fly(avatar, from: viewport.convert(crop, from: window), targetSize: targetSize,
                     reduceMotion: reduceMotion)
    }

    fileprivate func update(selected: String?, showing: Bool) {
        guard let profileID else { return }
        if selected == profileID {
            viewport?.showSnapshot(showing)
        } else {
            viewport?.clear()
            self.profileID = nil
        }
    }

    final class Viewport: UIView {
        fileprivate var backdrop = UIColor.clear
        private var avatar: UIView?
        private var destination: CGPoint { CGPoint(x: bounds.midX, y: bounds.midY) }

        fileprivate func fly(_ snapshot: UIView, from source: CGRect, targetSize: CGFloat, reduceMotion: Bool) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            clear()
            avatar = snapshot
            snapshot.isAccessibilityElement = false
            snapshot.bounds = CGRect(origin: .zero, size: source.size)
            snapshot.layer.cornerRadius = source.width / 2
            snapshot.layer.masksToBounds = true
            backgroundColor = backdrop
            addSubview(snapshot)
            let scale = targetSize / source.width
            snapshot.center = destination
            snapshot.transform = CGAffineTransform(scaleX: scale, y: scale)
            snapshot.layoutIfNeeded()
            if !reduceMotion {
                let position = CABasicAnimation(keyPath: "position")
                position.fromValue = NSValue(cgPoint: CGPoint(x: source.midX, y: source.midY))
                position.toValue = NSValue(cgPoint: destination)
                let size = CABasicAnimation(keyPath: "transform.scale")
                size.fromValue = 1
                size.toValue = scale
                let flight = CAAnimationGroup()
                flight.duration = 0.36
                position.duration = flight.duration
                size.duration = flight.duration
                flight.animations = [position, size]
                flight.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                snapshot.layer.add(flight, forKey: "profile-to-center")
            }
            CATransaction.commit()
            // Publish the endpoint and explicit animation together *before*
            // the caller changes picker state or schedules authorization.
            CATransaction.flush()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            // Rotation / window resize during a hold. Don't restart the flight
            // for ordinary layout passes caused by Home appearing behind us.
            if let avatar, avatar.center != destination {
                avatar.layer.removeAnimation(forKey: "profile-to-center")
                UIView.performWithoutAnimation { avatar.center = destination }
            }
        }

        fileprivate func showSnapshot(_ visible: Bool) {
            avatar?.isHidden = !visible
            if !visible { avatar?.layer.removeAnimation(forKey: "profile-to-center") }
            backgroundColor = visible ? backdrop : .clear
        }

        fileprivate func clear() {
            avatar?.layer.removeAllAnimations()
            avatar?.removeFromSuperview()
            avatar = nil
            backgroundColor = .clear
        }
    }
}

/// The marker never renders the artwork. It only locates the tile in the
/// correct scene's window when tapped, including scrolled or RTL layouts.
struct PlozziOSAvatarCaptureMarker: UIViewRepresentable {
    let flight: PlozziOSProfileAvatarFlight
    let profileID: String

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        flight.register(view, for: profileID)
    }
}

struct PlozziOSAvatarFlightSurface: UIViewRepresentable {
    let flight: PlozziOSProfileAvatarFlight
    let selected: String?
    let showing: Bool
    let backdrop: UIColor

    func makeUIView(context: Context) -> PlozziOSProfileAvatarFlight.Viewport {
        let view = PlozziOSProfileAvatarFlight.Viewport()
        view.isUserInteractionEnabled = false
        view.accessibilityElementsHidden = true
        return view
    }

    func updateUIView(_ view: PlozziOSProfileAvatarFlight.Viewport, context: Context) {
        flight.viewport = view
        view.backdrop = backdrop
        flight.update(selected: selected, showing: showing)
    }

    static func dismantleUIView(_ view: PlozziOSProfileAvatarFlight.Viewport, coordinator: ()) {
        view.clear()
    }
}
#endif
