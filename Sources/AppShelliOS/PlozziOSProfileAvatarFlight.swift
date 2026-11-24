#if os(iOS)
import SwiftUI
import UIKit

extension EnvironmentValues {
    @Entry var plozziOSPickerFlight: PlozziOSProfileAvatarFlight?
}

/// The name and artwork share one presentation layer throughout the flight.
@MainActor
final class PlozziOSProfileAvatarFlight {
    private let tiles = NSMapTable<NSString, UIView>.strongToWeakObjects()
    fileprivate weak var viewport: Viewport?
    private var placeCapturedIdentity: (() -> Void)?
    private(set) var profileID: String?
    private(set) var captionSpace: CGFloat = 0
    var landsAt: CFTimeInterval? { viewport?.landsAt }

    fileprivate func register(_ marker: UIView, for id: String) {
        tiles.setObject(marker, forKey: id as NSString)
    }

    func prepare(profileID: String, avatarSize: CGFloat, targetSize: CGFloat, reduceMotion: Bool,
               caption: (CGFloat) -> UIImage?) {
        guard let viewport, let marker = tiles.object(forKey: profileID as NSString),
              let window = marker.window, viewport.window === window else { return }
        viewport.layoutIfNeeded()
        let tile = marker.convert(marker.bounds, to: window)
        let crop = CGRect(x: tile.midX - avatarSize / 2, y: tile.minY, width: avatarSize, height: avatarSize)
        guard tile.width > 0, !viewport.bounds.isEmpty, window.bounds.contains(tile),
              let avatar = window.resizableSnapshotView(
                from: crop, afterScreenUpdates: false, withCapInsets: .zero
              ), let name = caption(tile.width) else { return }
        let identity = UIView(frame: CGRect(origin: .zero, size: crop.size))
        avatar.frame = identity.bounds
        avatar.layer.cornerRadius = crop.width / 2
        avatar.clipsToBounds = true
        identity.addSubview(avatar)
        let label = UIImageView(image: name)
        label.center = CGPoint(x: identity.bounds.midX, y: identity.bounds.maxY + 10 + name.size.height / 2)
        identity.addSubview(label)
        captionSpace = (10 + name.size.height) * targetSize / avatarSize
        self.profileID = profileID
        let source = viewport.convert(crop, from: window)
        // Capture on tap, but install the copy in the same update that hides
        // the original tile; otherwise both names can be visible for one frame.
        placeCapturedIdentity = { [weak viewport] in
            viewport?.fly(identity, from: source, targetSize: targetSize, reduceMotion: reduceMotion)
        }
    }

    fileprivate func update(selected: String?, showing: Bool) {
        guard let profileID else { return }
        if selected == profileID {
            if showing {
                placeCapturedIdentity?()
                placeCapturedIdentity = nil
            }
            viewport?.showSnapshot(showing)
        } else {
            placeCapturedIdentity = nil
            viewport?.clear()
            self.profileID = nil
        }
    }

    final class Viewport: UIView {
        fileprivate private(set) var landsAt: CFTimeInterval?
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
                flight.duration = 0.52
                position.duration = flight.duration
                size.duration = flight.duration
                flight.animations = [position, size]
                flight.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                let start = CACurrentMediaTime()
                flight.beginTime = snapshot.layer.convertTime(start, from: nil)
                landsAt = start + flight.duration
                snapshot.layer.add(flight, forKey: "profile-to-center")
                // Only the background color fades in. The moving identity stays
                // opaque while the rest of the still-mounted picker dissolves.
                let dissolve = CABasicAnimation(keyPath: "backgroundColor")
                let color = backdrop.resolvedColor(with: traitCollection)
                dissolve.fromValue = color.withAlphaComponent(0).cgColor
                dissolve.toValue = color.cgColor
                dissolve.duration = 0.36
                dissolve.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                layer.add(dissolve, forKey: "picker-dissolve")
            }
            CATransaction.commit()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            // Rotation / window resize during a hold. Don't restart the flight
            // for ordinary layout passes caused by Home appearing behind us.
            if let avatar, avatar.center != destination {
                landsAt = nil
                avatar.layer.removeAnimation(forKey: "profile-to-center")
                UIView.performWithoutAnimation { avatar.center = destination }
            }
        }

        fileprivate func showSnapshot(_ visible: Bool) {
            avatar?.isHidden = !visible
            if !visible {
                landsAt = nil
                avatar?.layer.removeAnimation(forKey: "profile-to-center")
                layer.removeAnimation(forKey: "picker-dissolve")
            }
            backgroundColor = visible ? backdrop : .clear
        }

        fileprivate func clear() {
            landsAt = nil
            layer.removeAnimation(forKey: "picker-dissolve")
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
