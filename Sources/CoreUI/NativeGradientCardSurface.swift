#if os(tvOS)
import CoreNetworking
import SwiftUI
import UIKit

@MainActor
final class NativeGradientCardSurface {
    struct Style: Equatable {
        let colors: [Color]
        let palette: ThemePalette
    }

    private(set) weak var viewport: UIView?
    private(set) var image: CGImage?
    private var renderedStyle: Style?
    private var renderedSize = CGSize.zero
    private var style: Style?
    private var reduceMotion = false
    private let cards = NSHashTable<NativeGradientCardFill.View>.weakObjects()

    func configure(viewport: UIView, style: Style, reduceMotion: Bool) {
        self.viewport = viewport
        self.style = style
        self.reduceMotion = reduceMotion
        refresh()
    }

    func detach(viewport: UIView) {
        guard self.viewport === viewport else { return }
        self.viewport = nil
        cards.allObjects.forEach { $0.refresh() }
    }

    func register(_ card: NativeGradientCardFill.View) {
        cards.add(card)
        refresh()
        card.refresh()
    }

    func unregister(_ card: NativeGradientCardFill.View) {
        cards.remove(card)
    }

    func refresh() {
        let activeCards = cards.allObjects
        guard !activeCards.isEmpty, let viewport, viewport.window != nil, let style else { return }
        let size = viewport.bounds.size
        guard size.width > 0, size.height > 0, size.width.isFinite, size.height.isFinite else { return }
        let changed = renderedStyle != style || renderedSize != size
        if changed {
            let renderer = ImageRenderer(content:
                AmbientGradientBackground.mesh(colors: style.colors)
                    .overlay(style.palette.informationSurface.opacity(DetailInformationSections.bandFillOpacity))
                    .overlay(style.palette.gradientSurface.fill)
                    .frame(width: size.width, height: size.height)
                    .environment(\.colorScheme, style.palette.isLight ? .light : .dark)
            )
            // One small texture per page/palette; scrolling changes only each card's sampling rectangle.
            renderer.scale = min(1, 480 / max(size.width, size.height))
            guard let rendered = renderer.cgImage else {
                PlozzLog.app.error("Could not render the native gradient card surface")
                return
            }
            image = rendered
            renderedStyle = style
            renderedSize = size
        }
        activeCards.forEach { $0.refresh(animated: changed && !reduceMotion) }
    }
}

struct NativeGradientViewport: UIViewRepresentable {
    let surface: NativeGradientCardSurface
    let style: NativeGradientCardSurface.Style
    let reduceMotion: Bool

    func makeUIView(context: Context) -> View { View() }

    func updateUIView(_ view: View, context: Context) {
        if view.surface !== surface { view.surface?.detach(viewport: view) }
        view.surface = surface
        surface.configure(
            viewport: view, style: style,
            reduceMotion: reduceMotion || context.transaction.disablesAnimations
        )
    }

    static func dismantleUIView(_ view: View, coordinator: ()) {
        view.surface?.detach(viewport: view)
    }

    final class View: UIView {
        weak var surface: NativeGradientCardSurface?

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            isAccessibilityElement = false
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func layoutSubviews() {
            super.layoutSubviews()
            surface?.refresh()
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            surface?.refresh()
        }
    }
}

struct NativeGradientCardFill: UIViewRepresentable {
    let surface: NativeGradientCardSurface?

    func makeUIView(context: Context) -> View { View() }

    func updateUIView(_ view: View, context: Context) {
        view.configure(surface: surface)
    }

    static func dismantleUIView(_ view: View, coordinator: ()) {
        view.configure(surface: nil)
    }

    final class View: UIView {
        private weak var surface: NativeGradientCardSurface?
        private var image: CGImage?
        private var scrollIDs: [ObjectIdentifier] = []
        private var observations: [NSKeyValueObservation] = []

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            isAccessibilityElement = false
            layer.contentsGravity = .resize
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        func configure(surface: NativeGradientCardSurface?) {
            if self.surface !== surface {
                self.surface?.unregister(self)
                self.surface = surface
                if window != nil { surface?.register(self) }
            }
            if surface == nil {
                observations.removeAll()
                scrollIDs.removeAll()
                image = nil
                layer.contents = nil
            } else {
                observeScrolling()
            }
            refresh()
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil {
                surface?.unregister(self)
                observations.removeAll()
                scrollIDs.removeAll()
            } else {
                surface?.register(self)
                observeScrolling()
            }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            observeScrolling()
            refresh()
        }

        func refresh(animated: Bool = false) {
            guard let surface, let viewport = surface.viewport, let image = surface.image,
                  let window, viewport.window === window, !bounds.isEmpty, !viewport.bounds.isEmpty else {
                isHidden = true
                return
            }
            isHidden = false
            let rect = convert(bounds, to: viewport)
            let samplingRect = CGRect(
                x: (rect.minX - viewport.bounds.minX) / viewport.bounds.width,
                y: (rect.minY - viewport.bounds.minY) / viewport.bounds.height,
                width: rect.width / viewport.bounds.width,
                height: rect.height / viewport.bounds.height
            )
            guard self.image !== image || layer.contentsRect != samplingRect else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            if self.image !== image {
                if animated, self.image != nil {
                    let fade = CATransition()
                    fade.type = .fade
                    fade.duration = 0.8
                    layer.add(fade, forKey: "gradientPalette")
                }
                self.image = image
                layer.contents = image
            }
            layer.contentsRect = samplingRect
            CATransaction.commit()
        }

        private func observeScrolling() {
            guard surface != nil, window != nil else { return }
            var scrolls: [UIScrollView] = []
            var ancestor = superview
            while let view = ancestor {
                if let scroll = view as? UIScrollView { scrolls.append(scroll) }
                ancestor = view.superview
            }
            let ids = scrolls.map(ObjectIdentifier.init)
            guard ids != scrollIDs else { return }
            scrollIDs = ids
            observations = scrolls.map { scroll in
                scroll.observe(\.contentOffset) { [weak self] _, _ in
                    MainActor.assumeIsolated { self?.refresh() }
                }
            }
        }
    }
}
#endif
