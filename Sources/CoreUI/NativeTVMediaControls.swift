#if os(tvOS)
import CoreModels
import CoreNetworking
import Observation
import SwiftUI
import TVUIKit
import UIKit

enum NativePosterText {
    case content(String)
    case localized(LocalizedStringResource)

    func resolve(locale: Locale) -> String {
        switch self {
        case .content(let value): return value
        case .localized(var value):
            value.locale = locale
            return String(localized: value) // l10n:content — UIKit boundary; resolved with the current environment locale on every update
        }
    }
}

@MainActor
final class NativeTVMediaCoordinator {
    var focus: PlozzCardFocus.Binding
    var action: () -> Void
    private var handledGeneration: UInt64 = 0
    private var isRequestScheduled = false

    init(focus: PlozzCardFocus.Binding, action: @escaping () -> Void) {
        self.focus = focus
        self.action = action
    }

    func update(focus: PlozzCardFocus.Binding, action: @escaping () -> Void, view: TVLockupView) {
        self.focus = focus
        self.action = action
        requestFocusIfReady(in: view)
    }

    private var hasPendingRequest: Bool {
        let request = focus.request.wrappedValue
        return request.wantsFocus && request.generation != handledGeneration
    }

    func requestFocusIfReady(in view: TVLockupView) {
        guard hasPendingRequest, !isRequestScheduled,
              view.window != nil, view.isEnabled, view.canBecomeFocused, !view.bounds.isEmpty else { return }
        isRequestScheduled = true
        DispatchQueue.main.async { [weak self, weak view] in
            guard let self else { return }
            defer { isRequestScheduled = false }
            guard hasPendingRequest, let view, let window = view.window,
                  view.isEnabled, view.canBecomeFocused, !view.bounds.isEmpty,
                  let system = UIFocusSystem.focusSystem(for: view) else { return }
            if focus.request.wrappedValue.animated {
                applyFocus(to: view, in: window, using: system)
            } else {
                UIView.performWithoutAnimation {
                    var transaction = Transaction(animation: nil)
                    transaction.disablesAnimations = true
                    withTransaction(transaction) { self.applyFocus(to: view, in: window, using: system) }
                }
            }
        }
    }

    private func applyFocus(to view: TVLockupView, in window: UIWindow, using system: UIFocusSystem) {
        focus.focusState.wrappedValue = true
        window.layoutIfNeeded()
        guard hasPendingRequest, view.window === window, view.isEnabled, view.canBecomeFocused else { return }
        var request = focus.request.wrappedValue
        handledGeneration = request.generation
        request.wantsFocus = false
        focus.request.wrappedValue = request
        guard !view.isFocused else { return }
        system.requestFocusUpdate(to: window)
        system.updateFocusIfNeeded()
        if !view.isFocused {
            PlozzLog.app.debug("Native media focus request was not accepted by the current focus scope")
        }
    }

    func observe(_ focused: Bool) {
        if focus.observation.isFocused != focused { focus.observation.isFocused = focused }
    }

    func activate() { action() }
}

struct NativeTVCard<Content: View>: UIViewRepresentable {
    let content: Content
    let focus: PlozzCardFocus.Binding
    let isEnabled: Bool
    let action: () -> Void
    var accessibilityLabel: String? = nil
    var accessibilityValue: String? = nil

    func makeCoordinator() -> NativeTVMediaCoordinator {
        NativeTVMediaCoordinator(focus: focus, action: action)
    }

    func makeUIView(context: Context) -> Container {
        let view = Card()
        view.defaultAccessibilityElement = view.isAccessibilityElement
        view.cardBackgroundColor = UIColor(context.environment.themePalette.opaqueRaisedFill)
        let host = configuration(in: context).makeContentView()
        view.hostedContent = host
        view.contentView.addSubview(host)
        host.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: view.contentView.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: view.contentView.trailingAnchor),
            host.topAnchor.constraint(equalTo: view.contentView.topAnchor),
            host.bottomAnchor.constraint(equalTo: view.contentView.bottomAnchor)
        ])
        view.onFocus = { [weak coordinator = context.coordinator] in coordinator?.observe($0) }
        view.onAvailable = { [weak coordinator = context.coordinator, weak view] in
            if let view { coordinator?.requestFocusIfReady(in: view) }
        }
        view.addAction(UIAction { [weak coordinator = context.coordinator] _ in coordinator?.activate() },
                       for: .primaryActionTriggered)
        return Container(card: view)
    }

    func updateUIView(_ container: Container, context: Context) {
        let view = container.card
        view.isAccessibilityElement = view.defaultAccessibilityElement || accessibilityLabel != nil
        view.accessibilityLabel = accessibilityLabel
        view.accessibilityValue = accessibilityValue
        view.accessibilityTraits.insert(.button)
        let background = UIColor(context.environment.themePalette.opaqueRaisedFill)
        if view.cardBackgroundColor != background { view.cardBackgroundColor = background }
        view.hostedContent?.configuration = configuration(in: context)
        view.isEnabled = isEnabled && context.environment.isEnabled
        if view.usesInformationFocus != context.environment.plozzNativeInformationFocus {
            view.usesInformationFocus = context.environment.plozzNativeInformationFocus
            container.setNeedsLayout()
        }
        context.coordinator.update(focus: focus, action: action, view: view)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: Container, context: Context) -> CGSize? {
        let card = uiView.card
        guard let content = card.hostedContent else { return nil }
        let width = proposal.width.flatMap { width in
            width.isFinite && width > 0 ? width : nil
        }
        let contentHeight = proposal.height.flatMap { height in
            height.isFinite ? max(0, height) : nil
        }
        // An unspecified height is an intrinsic-height query, not a 10,000pt
        // offer. Flexible rating labels otherwise stretch and inflate About's
        // cross-column text measurements.
        // Horizontal music rails propose no width. Measure their fixed artwork
        // and captions instead of returning the native container's initial zero size.
        let size = content.systemLayoutSizeFitting(
            CGSize(width: width ?? 0, height: contentHeight ?? 0),
            withHorizontalFittingPriority: width == nil ? .fittingSizeLevel : .required,
            verticalFittingPriority: (contentHeight ?? 0) > 0 ? .required : .fittingSizeLevel
        )
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height >= 0 else {
            PlozzLog.app.error("Native card content returned invalid fitting dimensions")
            return nil
        }
        // SwiftUI probes several candidate sizes; none is necessarily the placed size.
        return CGSize(width: width ?? size.width, height: size.height)
    }

    private func configuration(in context: Context) -> any UIContentConfiguration {
        UIHostingConfiguration {
            content
                .environment(\.plozzNativeArtworkSurface, false)
                .environment(\.plozzNativeFocusSurface, true)
                .environment(\.self, context.environment)
        }
        .margins(.all, 0)
    }

    final class Container: UIView {
        let card: Card

        init(card: Card) {
            self.card = card
            super.init(frame: .zero)
            addSubview(card)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override var intrinsicContentSize: CGSize { card.contentSize }
        override var preferredFocusEnvironments: [any UIFocusEnvironment] { [card] }

        override func layoutSubviews() {
            super.layoutSubviews()
            guard !bounds.isEmpty else { return }
            if card.contentSize != bounds.size {
                card.contentSize = bounds.size
            }
            card.updateFocusSize()
            // TVCardView reserves symmetric space for its focus expansion.
            // Keep that invisible space outside the visible surface's layout slot.
            let intrinsic = card.intrinsicContentSize
            let horizontal = max(0, intrinsic.width - card.contentSize.width) / 2
            let vertical = max(0, intrinsic.height - card.contentSize.height) / 2
            let frame = bounds.insetBy(dx: -horizontal, dy: -vertical)
            if card.frame != frame { card.frame = frame }
        }
    }

    final class Card: TVCardView {
        var usesInformationFocus = false
        private var systemFocusSizeIncrease: NSDirectionalEdgeInsets?
        var defaultAccessibilityElement = false
        var hostedContent: (UIView & UIContentView)?
        var onFocus: ((Bool) -> Void)?
        var onAvailable: (() -> Void)?

        func updateFocusSize() {
            guard usesInformationFocus else {
                if let systemFocusSizeIncrease {
                    focusSizeIncrease = systemFocusSizeIncrease
                    self.systemFocusSizeIncrease = nil
                }
                return
            }
            guard contentSize.width > 0, contentSize.height > 0 else { return }
            if systemFocusSizeIncrease == nil { systemFocusSizeIncrease = focusSizeIncrease }
            let fraction = min(
                (PlozzTheme.Metrics.readOnlyFocusedCardScale - 1) / 2,
                PlozzTheme.Metrics.informationFocusMaximumOutset / max(contentSize.width, contentSize.height)
            )
            let increase = NSDirectionalEdgeInsets(
                top: -contentSize.height * fraction, leading: -contentSize.width * fraction,
                bottom: -contentSize.height * fraction, trailing: -contentSize.width * fraction
            )
            if focusSizeIncrease != increase { focusSizeIncrease = increase }
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            onAvailable?()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            onAvailable?()
        }

        override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
            super.didUpdateFocus(in: context, with: coordinator)
            onFocus?(isFocused)
        }
    }
}

enum NativePosterImageTreatment: Equatable {
    case original, blurred, extended
    case upcoming(Color)
}

struct NativeTVPoster<Overlay: View>: UIViewRepresentable {
    let image: UIImage?
    let treatment: NativePosterImageTreatment
    let aspectRatio: CGFloat
    let fallbackWidth: CGFloat
    // Accessible metadata only. Visible captions must not inherit native image animation.
    let title: NativePosterText?
    let subtitle: String? // l10n:content — provider metadata and preformatted runtime
    let overlay: Overlay
    let focus: PlozzCardFocus.Binding
    var source: DetailTransitionSourceReference? = nil
    let action: () -> Void

    @MainActor
    final class Coordinator {
        let focus: NativeTVMediaCoordinator
        var original: UIImage?
        var treatment = NativePosterImageTreatment.original
        var imageSize = CGSize.zero
        var imageScale: CGFloat = 1
        var prepared: UIImage?
        private var placeholder: UIImage?
        private var placeholderSize = CGSize.zero
        private var placeholderScale: CGFloat = 1

        init(focus: PlozzCardFocus.Binding, action: @escaping () -> Void) {
            self.focus = NativeTVMediaCoordinator(focus: focus, action: action)
        }

        func presentationImage(_ image: UIImage?, treatment: NativePosterImageTreatment, size: CGSize, scale: CGFloat) -> UIImage {
            if let prepared = prepare(image, treatment: treatment, size: size, scale: scale) { return prepared }
            if let placeholder, placeholderSize == size, placeholderScale == scale { return placeholder }
            let format = UIGraphicsImageRendererFormat()
            format.scale = scale
            format.opaque = true
            let loadingImage = UIGraphicsImageRenderer(size: size, format: format).image {
                UIColor.darkGray.setFill()
                $0.fill(CGRect(origin: .zero, size: size))
            }
            placeholder = loadingImage
            placeholderSize = size
            placeholderScale = scale
            return loadingImage
        }

        func prepare(_ image: UIImage?, treatment: NativePosterImageTreatment, size: CGSize, scale: CGFloat) -> UIImage? {
            IOTimingDiagnostics.measure(.nativePosterPrepare, minimumDurationNanoseconds: 1_000_000) {
                prepareImage(image, treatment: treatment, size: size, scale: scale)
            }
        }

        private func prepareImage(_ image: UIImage?, treatment: NativePosterImageTreatment, size: CGSize, scale: CGFloat) -> UIImage? {
            guard let image else { return nil }
            if original === image, self.treatment == treatment, imageSize == size, imageScale == scale { return prepared }
            original = image
            self.treatment = treatment
            imageSize = size
            imageScale = scale
            if treatment == .original, let pixels = image.cgImage {
                prepared = UIImage(
                    cgImage: pixels,
                    scale: image.size.width * image.scale / size.width,
                    orientation: image.imageOrientation
                )
                return prepared
            }
            if treatment == .extended {
                prepared = ExtendedArtworkBitmap.render(image: image, size: size, scale: scale)
                if prepared == nil { original = nil }
                return prepared
            }
            // TVPosterView derives native focus growth from image.size in points,
            // not the cached bitmap's pixel dimensions.
            let renderer = ImageRenderer(content: Group {
                if case .upcoming(let background) = treatment {
                    Image(uiImage: image).resizable().scaledToFill()
                        .saturation(0)
                        .opacity(0.05)
                        .background(background)
                } else {
                    Image(uiImage: image).resizable().scaledToFill()
                        .blur(radius: treatment == .blurred ? 28 : 0)
                }
            }.frame(width: size.width, height: size.height).clipped())
            renderer.scale = scale
            renderer.isOpaque = true
            prepared = renderer.uiImage
            if prepared == nil {
                PlozzLog.app.error("Unable to prepare native poster artwork; keeping the protected placeholder")
            }
            return prepared
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(focus: focus, action: action) }

    func makeUIView(context: Context) -> Container {
        let size = CGSize(width: fallbackWidth, height: fallbackWidth / aspectRatio)
        let initialImage = context.coordinator.presentationImage(
            image, treatment: treatment, size: size, scale: context.environment.displayScale
        )
        // Materializing imageView with a nil image freezes TVUIKit's native
        // focus expansion at zero, even after an image arrives.
        let view = Poster(image: initialImage)
        view.updateImage(initialImage)
        view.defaultAccessibilityElement = view.isAccessibilityElement
        view.contentSize = size
        view.hostedOverlay = overlayConfiguration(in: context).makeContentView()
        if let overlay = view.hostedOverlay {
            // Native focus and row scrolling move the same logo/badge composite.
            overlay.layer.shouldRasterize = true
            overlay.layer.rasterizationScale = context.environment.displayScale
            let container = view.imageView.overlayContentView
            container.addSubview(overlay)
            overlay.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                overlay.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                overlay.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                overlay.topAnchor.constraint(equalTo: container.topAnchor),
                overlay.bottomAnchor.constraint(equalTo: container.bottomAnchor)
            ])
        }
        view.onFocus = { [weak coordinator = context.coordinator] in coordinator?.focus.observe($0) }
        view.onAvailable = { [weak coordinator = context.coordinator, weak view] in
            if let view { coordinator?.focus.requestFocusIfReady(in: view) }
        }
        view.addAction(UIAction { [weak coordinator = context.coordinator] _ in coordinator?.focus.activate() },
                       for: .primaryActionTriggered)
        return Container(poster: view)
    }

    func updateUIView(_ container: Container, context: Context) {
        IOTimingDiagnostics.measure(.nativePosterUpdate, minimumDurationNanoseconds: 1_000_000) {
            updatePoster(container, context: context)
        }
    }

    private func updatePoster(_ container: Container, context: Context) {
        let view = container.poster
        if view.contentSize.width <= 0 {
            view.contentSize = CGSize(width: fallbackWidth, height: fallbackWidth / aspectRatio)
        }
        let resolvedTitle = title?.resolve(locale: context.environment.locale)
        view.isAccessibilityElement = view.defaultAccessibilityElement || resolvedTitle != nil || subtitle != nil
        view.accessibilityLabel = resolvedTitle
        view.accessibilityValue = subtitle
        view.accessibilityTraits.insert(.button)
        view.hostedOverlay?.configuration = overlayConfiguration(in: context)
        view.hostedOverlay?.layer.rasterizationScale = context.environment.displayScale
        let prepared = context.coordinator.presentationImage(
            image, treatment: treatment, size: view.contentSize, scale: context.environment.displayScale
        )
        view.updateImage(prepared)
        view.isEnabled = context.environment.isEnabled
        source?.nativeArtworkView = view.imageView
        context.coordinator.focus.update(focus: focus, action: action, view: view)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: Container, context: Context) -> CGSize? {
        let width = proposal.width ?? fallbackWidth
        guard width.isFinite, width > 0 else { return nil }
        let size = CGSize(width: width, height: width / aspectRatio)
        let poster = uiView.poster
        if poster.contentSize != size {
            poster.contentSize = size
            uiView.invalidateIntrinsicContentSize()
            uiView.setNeedsLayout()
        }
        let prepared = context.coordinator.presentationImage(
            image, treatment: treatment, size: size, scale: context.environment.displayScale
        )
        poster.updateImage(prepared)
        return uiView.intrinsicContentSize
    }

    private func overlayConfiguration(in context: Context) -> any UIContentConfiguration {
        UIHostingConfiguration {
            overlay
                .environment(\.plozzNativeArtworkSurface, true)
                .environment(\.plozzNativeFocusSurface, true)
                .environment(\.self, context.environment)
        }
        .margins(.all, 0)
    }

    final class Container: UIView {
        let poster: Poster

        init(poster: Poster) {
            self.poster = poster
            super.init(frame: .zero)
            addSubview(poster)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override var intrinsicContentSize: CGSize {
            // SwiftUI must not round a fractional artwork height down into its caption.
            CGSize(width: poster.contentSize.width, height: ceil(poster.contentSize.height))
        }

        override var preferredFocusEnvironments: [any UIFocusEnvironment] { [poster] }

        func posterDidLayout() {
            let intrinsic = poster.intrinsicContentSize
            let size = CGSize(width: ceil(intrinsic.width), height: ceil(intrinsic.height))
            guard poster.bounds.size != size else { return }
            // Focus clearance settles after realization, but is drawing overflow,
            // not a change to the artwork slot in the containing lazy row.
            setNeedsLayout()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            // Keep both native focus margins outside the artwork's layout slot.
            let intrinsic = poster.intrinsicContentSize
            let size = CGSize(width: ceil(intrinsic.width), height: ceil(intrinsic.height))
            poster.frame = CGRect(x: (bounds.width - size.width) / 2,
                                  y: (bounds.height - size.height) / 2,
                                  width: size.width, height: size.height)
        }
    }

    final class Poster: TVPosterView {
        var defaultAccessibilityElement = false
        var hostedOverlay: (UIView & UIContentView)?
        var onFocus: ((Bool) -> Void)?
        var onAvailable: (() -> Void)?

        func updateImage(_ image: UIImage) {
            if self.image !== image { self.image = image }
            // Transparent covers remain rounded posters, not alpha-shaped cutouts.
            if imageView.masksFocusEffectToContents {
                imageView.masksFocusEffectToContents = false
            }
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            onAvailable?()
        }

        override func layoutSubviews() {
            IOTimingDiagnostics.measure(.nativePosterLayout, minimumDurationNanoseconds: 1_000_000) {
                layoutPosterSubviews()
            }
        }

        private func layoutPosterSubviews() {
            super.layoutSubviews()
            (superview as? Container)?.posterDidLayout()
            onAvailable?()
        }

        override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
            super.didUpdateFocus(in: context, with: coordinator)
            onFocus?(isFocused)
        }
    }
}

struct NativeTVMonogram: UIViewRepresentable {
    let image: UIImage?
    let name: String?
    let diameter: CGFloat
    let focus: PlozzCardFocus.Binding
    let action: () -> Void

    @MainActor
    final class Coordinator {
        let focus: NativeTVMediaCoordinator
        private var original: UIImage?
        private var diameter: CGFloat = 0
        private var scale: CGFloat = 0
        private var prepared: UIImage?

        init(focus: PlozzCardFocus.Binding, action: @escaping () -> Void) {
            self.focus = NativeTVMediaCoordinator(focus: focus, action: action)
        }

        func portrait(_ image: UIImage?, diameter: CGFloat, scale: CGFloat) -> UIImage? {
            guard let image else {
                original = nil
                prepared = nil
                return nil
            }
            if original === image, self.diameter == diameter, self.scale == scale { return prepared }
            guard image.size.width > 0, image.size.height > 0, diameter > 0 else {
                PlozzLog.app.error("Cannot prepare native monogram from invalid image dimensions")
                return nil
            }
            original = image
            self.diameter = diameter
            self.scale = scale
            let format = UIGraphicsImageRendererFormat()
            format.scale = scale
            let bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
            prepared = UIGraphicsImageRenderer(size: bounds.size, format: format).image { _ in
                UIBezierPath(ovalIn: bounds).addClip()
                let fill = max(diameter / image.size.width, diameter / image.size.height)
                let size = CGSize(width: image.size.width * fill, height: image.size.height * fill)
                image.draw(in: CGRect(
                    x: (diameter - size.width) / 2, y: (diameter - size.height) / 2,
                    width: size.width, height: size.height
                ))
            }
            return prepared
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(focus: focus, action: action)
    }

    func makeUIView(context: Context) -> Monogram {
        let view = Monogram()
        view.contentSize = CGSize(width: diameter, height: diameter)
        view.onFocus = { [weak coordinator = context.coordinator] in coordinator?.focus.observe($0) }
        view.onAvailable = { [weak coordinator = context.coordinator, weak view] in
            if let view { coordinator?.focus.requestFocusIfReady(in: view) }
        }
        view.addAction(UIAction { [weak coordinator = context.coordinator] _ in coordinator?.focus.activate() },
                       for: .primaryActionTriggered)
        return view
    }

    func updateUIView(_ view: Monogram, context: Context) {
        let portrait = context.coordinator.portrait(image, diameter: diameter, scale: context.environment.displayScale)
        if view.image !== portrait { view.image = portrait }
        if view.displayedName != name {
            view.displayedName = name
            view.personNameComponents = name.flatMap { PersonNameComponentsFormatter().personNameComponents(from: $0) }
        }
        let size = CGSize(width: diameter, height: diameter)
        if view.contentSize != size { view.contentSize = size }
        view.isEnabled = context.environment.isEnabled
        context.coordinator.focus.update(focus: focus, action: action, view: view)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: Monogram, context: Context) -> CGSize? {
        uiView.intrinsicContentSize
    }

    final class Monogram: TVMonogramView {
        var displayedName: String?
        var onFocus: ((Bool) -> Void)?
        var onAvailable: (() -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            onAvailable?()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            onAvailable?()
        }

        override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
            super.didUpdateFocus(in: context, with: coordinator)
            onFocus?(isFocused)
        }
    }
}

struct NativeTVCardButtonStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        LabelBody(configuration: configuration)
    }

    private struct LabelBody: View {
        let configuration: PrimitiveButtonStyleConfiguration
        @PlozzCardFocus private var focus: Bool
        @Environment(\.isEnabled) private var isEnabled

        @ViewBuilder
        var body: some View {
            NativeTVCard(content: configuration.label, focus: $focus, isEnabled: isEnabled, action: configuration.trigger)
                .focused($focus.focusState)
                .zIndex(focus ? 1 : 0)
        }
    }
}

/// A loading placeholder drawn by a real native poster of the card's shape, so
/// it takes the same room (TVUIKit keeps clearance around the artwork for focus
/// growth) and has the same corners as the poster that replaces it. The poster is
/// disabled unless the caller supplies the explicit loading-entry focus binding.
struct NativePosterPlaceholder: UIViewRepresentable {
    let aspectRatio: CGFloat
    let fallbackWidth: CGFloat
    let fill: Color
    var focus: PlozzCardFocus.Binding?
    var showsProgress = false

    typealias Container = NativeTVPoster<EmptyView>.Container

    /// The corner TVUIKit gives a poster's image: the same at every size, and
    /// matched to within a pixel of the native one.
    static let cornerRadius: CGFloat = 21

    func makeCoordinator() -> NativeTVMediaCoordinator? {
        focus.map { NativeTVMediaCoordinator(focus: $0, action: {}) }
    }

    func makeUIView(context: Context) -> Container {
        let size = CGSize(width: fallbackWidth, height: fallbackWidth / aspectRatio)
        // TVUIKit sizes the clearance from the image, so it needs one of the
        // artwork's size from the start.
        let poster = NativeTVPoster<EmptyView>.Poster(image: Self.blank(size))
        poster.contentSize = size
        poster.isEnabled = focus != nil && context.environment.isEnabled
        poster.isUserInteractionEnabled = focus != nil
        poster.isAccessibilityElement = focus != nil
        poster.onFocus = { [weak coordinator = context.coordinator] in coordinator?.observe($0) }
        poster.onAvailable = { [weak coordinator = context.coordinator, weak poster] in
            if let poster { coordinator?.requestFocusIfReady(in: poster) }
        }
        // TVUIKit rounds a poster's image itself and leaves its overlay square,
        // so the fill carries TVUIKit's corner.
        let sheen = configuration(in: context).makeContentView()
        poster.hostedOverlay = sheen
        let container = poster.imageView.overlayContentView
        container.addSubview(sheen)
        sheen.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            sheen.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            sheen.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            sheen.topAnchor.constraint(equalTo: container.topAnchor),
            sheen.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        return Container(poster: poster)
    }

    func updateUIView(_ container: Container, context: Context) {
        let poster = container.poster
        poster.hostedOverlay?.configuration = configuration(in: context)
        poster.isEnabled = focus != nil && context.environment.isEnabled
        poster.isAccessibilityElement = focus != nil
        poster.accessibilityLabel = focus == nil
            ? nil : NativePosterText.localized("Loading").resolve(locale: context.environment.locale)
        if let focus { context.coordinator?.update(focus: focus, action: {}, view: poster) }
    }

    private func configuration(in context: Context) -> any UIContentConfiguration {
        UIHostingConfiguration {
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .fill(fill)
                .shimmering()
                .overlay {
                    SkeletonLoadingIndicator(isVisible: showsProgress)
                }
                .environment(\.self, context.environment)
        }
        .margins(.all, 0)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: Container, context: Context) -> CGSize? {
        let width = proposal.width ?? fallbackWidth
        guard width.isFinite, width > 0 else { return nil }
        let size = CGSize(width: width, height: width / aspectRatio)
        let poster = uiView.poster
        if poster.contentSize != size {
            poster.contentSize = size
            poster.image = Self.blank(size)
            uiView.invalidateIntrinsicContentSize()
            uiView.setNeedsLayout()
        }
        return uiView.intrinsicContentSize
    }

    /// A clear image of the artwork's size: TVUIKit sizes the clearance and the
    /// corners from it, and the hosted fill draws inside those corners.
    @MainActor private static var blanks: [String: UIImage] = [:]

    @MainActor private static func blank(_ size: CGSize) -> UIImage {
        let key = "\(size.width)x\(size.height)"
        if let image = blanks[key] { return image }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in }
        blanks[key] = image
        return image
    }
}
#endif
