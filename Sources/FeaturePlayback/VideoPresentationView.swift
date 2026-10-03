#if canImport(UIKit)
import UIKit

/// Crops only the engine's surface. AVKit's external/PiP presentation keeps
/// owning its own sizing, and no video frames are copied or decoded here.
final class VideoPresentationView: UIView {
    private var engine: (any VideoEngine)?
    private var surface: UIView?
    private var zoom = PlayerVideoZoom()
    private var aspectRatio: Double?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        clipsToBounds = true
        isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func attach(_ engine: any VideoEngine) {
        let output = engine.makeVideoOutputView()
        self.engine = engine
        guard output.superview !== self else { return }
        if surface?.superview === self { surface?.removeFromSuperview() }
        output.removeFromSuperview()
        output.autoresizingMask = []
        output.isUserInteractionEnabled = false
        surface = output
        addSubview(output)
        setNeedsLayout()
    }

    func update(zoom: PlayerVideoZoom) {
        let ratio = engine?.videoAspectRatio
        guard self.zoom != zoom || aspectRatio != ratio else { return }
        self.zoom = zoom
        aspectRatio = ratio
        setNeedsLayout()
        layoutIfNeeded()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        aspectRatio = engine?.videoAspectRatio
        guard let surface, surface.superview === self else { return }
        let contentBounds = CGRect(origin: .zero, size: bounds.size)
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let scale = zoom.scaleFactors(in: bounds, aspectRatio: aspectRatio)
        let transform = CGAffineTransform(scaleX: scale.dx, y: scale.dy)
        if surface.bounds != contentBounds || surface.center != center || surface.transform != transform {
            UIView.performWithoutAnimation {
                surface.transform = .identity
                surface.bounds = contentBounds
                surface.center = center
                surface.transform = transform
                surface.layoutIfNeeded()
            }
        }
    }

    var videoRect: CGRect? { zoom.videoRect(in: bounds, aspectRatio: aspectRatio) }
    var sourceAspectRatio: Double? { aspectRatio }
}
#endif
