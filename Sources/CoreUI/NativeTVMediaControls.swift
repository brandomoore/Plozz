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

    func update(focus: PlozzCardFocus.Binding, action: @escaping () -> Void, view: UIControl) {
        self.focus = focus
        self.action = action
        requestFocusIfReady(in: view)
    }

    private var hasPendingRequest: Bool {
        let request = focus.request.wrappedValue
        return request.wantsFocus && request.generation != handledGeneration
    }

    func requestFocusIfReady(in view: UIControl) {
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

    private func applyFocus(to view: UIControl, in window: UIWindow, using system: UIFocusSystem) {
        let restoring = DetailTransitionNavigation.isRestoringSourcePage
        if restoring {
            HandoffDiagnostics.emit("detail RETURN_NATIVE_REQUEST target=\(HandoffDiagnostics.correlationID(view.accessibilityLabel)) focused=\(view.isFocused)")
        }
        defer {
            if restoring {
                HandoffDiagnostics.emit("detail RETURN_NATIVE_RESULT target=\(HandoffDiagnostics.correlationID(view.accessibilityLabel)) accepted=\(view.isFocused)")
            }
        }
        focus.focusState.wrappedValue = true
        window.layoutIfNeeded()
        guard hasPendingRequest, view.window === window, view.isEnabled, view.canBecomeFocused else { return }
        var request = focus.request.wrappedValue
        handledGeneration = request.generation
        request.wantsFocus = false
        focus.request.wrappedValue = request
        guard !view.isFocused else { return }
        system.requestFocusUpdate(to: view)
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
        view.cardBackgroundColor = UIColor(context.environment.themePalette.raised.fill)
        let host = configuration(in: context, card: view).makeContentView()
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
        if !context.environment.plozzGradientCardSurface {
            let background = UIColor(context.environment.themePalette.raised.fill)
            if view.cardBackgroundColor != background { view.cardBackgroundColor = background }
        }
        view.hostedContent?.configuration = configuration(in: context, card: view)
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

    private func configuration(in context: Context, card: Card) -> any UIContentConfiguration {
        UIHostingConfiguration {
            content
                .background {
                    NativeCardBackground { [weak card] color in
                        if card?.cardBackgroundColor != color { card?.cardBackgroundColor = color }
                    }
                }
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

        override func shouldUpdateFocus(in context: UIFocusUpdateContext) -> Bool {
            DetailTransitionNavigation.allowsFocusUpdate(heading: context.focusHeading, in: self)
                && super.shouldUpdateFocus(in: context)
        }
    }
}

private struct NativeCardBackground: View {
    @Environment(\.themePalette) private var palette
    @Environment(\.ambientBackdropModel) private var ambient
    @Environment(\.settingsGradientCardSurface) private var settingsSurface
    @Environment(\.plozzGradientCardSurface) private var gradientSurface
    @Environment(\.plozzGradientCardFillOpacity) private var fillOpacity
    @Environment(\.plozzRestingCardSurface) private var restingSurface
    @Environment(\.artworkGradientTintSaturation) private var tintSaturation
    let apply: (UIColor) -> Void

    private var color: Color {
        guard gradientSurface else { return palette.raised.fill }
        // TVUIKit's flat fill remains a fallback until the page-aligned surface is ready.
        return AmbientGradientBackground.meshColors(
            tint: settingsSurface == nil ? ambient?.colors : nil,
            palette: palette, tintSaturation: tintSaturation
        )[4]
            .mix(with: palette.informationSurface,
                 by: settingsSurface == nil ? DetailInformationSections.bandFillOpacity : 0)
            .mix(with: palette.gradientSurfaceTint, by: fillOpacity)
    }

    var body: some View {
        NativeGradientCardFill(
            surface: gradientSurface ? (settingsSurface ?? ambient?.cardSurface) : nil,
            fill: restingSurface.fill
        )
            .onChange(of: color, initial: true) { _, color in apply(UIColor(color)) }
    }
}

enum NativePosterImageTreatment: Equatable {
    case original, blurred, extended, fitted
    case extendedPortrait(blurredReflection: Bool)
    case upcoming(Color)
}

final class NativePosterImageView: UIImageView {
    let indicatorView = UIImageView()
    private var indicatorPlacement: NativePosterOverlayPlacement?
    private var indicatorLayoutDirection = LayoutDirection.leftToRight
    private var focusTransition: UInt64 = 0
    private var artworkFocused = false {
        didSet {
            // Artwork can mount at its lifted size if armed before real focus,
            // including opaque portrait cards in a lazy rail.
            if artworkFocused {
                clipsToBounds = false
                adjustsImageWhenAncestorFocused = true
            }
        }
    }

    init(masksFocusEffectToContents: Bool) {
        super.init(frame: .zero)
        self.masksFocusEffectToContents = masksFocusEffectToContents
        adjustsImageWhenAncestorFocused = false
        layer.cornerRadius = PlozzTheme.Metrics.nativePosterArtworkCornerRadius
        layer.cornerCurve = .circular
        clipsToBounds = true
        isUserInteractionEnabled = false
        indicatorView.isUserInteractionEnabled = false
        overlayContentView.addSubview(indicatorView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutIndicator()
    }

    func updateFocus(_ focused: Bool, coordinator: UIFocusAnimationCoordinator) {
        focusTransition &+= 1
        let transition = focusTransition
        artworkFocused = focused
        coordinator.addCoordinatedAnimations { [weak self] in
            self?.layoutIndicator()
        } completion: { [weak self] in
            guard let self, focusTransition == transition, !artworkFocused else { return }
            clipsToBounds = true
            adjustsImageWhenAncestorFocused = false
        }
    }

    func updateIndicator(_ overlay: NativePosterOverlay?, focused: Bool) {
        artworkFocused = focused
        if indicatorView.image !== overlay?.image { indicatorView.image = overlay?.image }
        indicatorPlacement = overlay?.placement
        if let overlay { indicatorLayoutDirection = overlay.layoutDirection }
        indicatorView.isHidden = overlay == nil
        layoutIndicator()
    }

    private func layoutIndicator() {
        let overlayView = overlayContentView
        guard let indicatorPlacement, !overlayView.bounds.isEmpty, !bounds.isEmpty else { return }
        // UIKit lifts overlays onto a nearer plane. Align only our badge to the
        // destination artwork geometry, never a sampled in-flight transform.
        guard let projected = NativeFocusProjection.frame(
            of: overlayView.layer, in: layer, usePresentation: false
        ), projected.width > 0 else {
            PlozzLog.app.error("Unable to align native poster indicators with their artwork")
            return
        }
        let size = bounds.size
        let viewport = artworkFocused ? focusedFrameGuide.layoutFrame : bounds
        let crop = artworkFocused && !masksFocusEffectToContents && indicatorPlacement == .croppedCount
            ? NativePosterArtworkBitmap.focusCrop(for: size) : .zero
        let artworkScale = viewport.width / (size.width - 2 * crop.width)
        let scale = artworkScale / (projected.width / overlayView.bounds.width)
        // The baked tile loses its top/trailing edges to the native crop.
        let trailingDirection: CGFloat = indicatorLayoutDirection == .leftToRight ? -1 : 1
        let center = CGPoint(
            x: overlayView.bounds.midX + trailingDirection * crop.width * scale / 2,
            y: overlayView.bounds.midY + crop.height * scale / 2
        )
        if indicatorView.bounds != bounds { indicatorView.bounds = bounds }
        if indicatorView.center != center { indicatorView.center = center }
        let transform = CGAffineTransform(scaleX: scale, y: scale)
        if indicatorView.transform != transform { indicatorView.transform = transform }
    }
}

final class NativePosterButton: UIButton {
    let artworkView: NativePosterImageView
    var indicatorView: UIImageView { artworkView.indicatorView }
    var overlayView: UIView { artworkView.overlayContentView }
    var contentSize = CGSize.zero {
        didSet {
            guard contentSize != oldValue else { return }
            invalidateIntrinsicContentSize()
            setNeedsLayout()
        }
    }
    var image: UIImage? { artworkView.image }
    var defaultAccessibilityElement = false
    var hostedOverlay: (UIView & UIContentView)?
    var onFocus: ((Bool) -> Void)?
    var onAvailable: (() -> Void)?
    var prepareArtwork: ((CGSize) -> UIImage?)?
    var prepareOverlay: ((CGSize) -> NativePosterOverlay?)?

    init(image: UIImage, masksFocusEffectToContents: Bool = false) {
        artworkView = NativePosterImageView(masksFocusEffectToContents: masksFocusEffectToContents)
        super.init(frame: .zero)
        clipsToBounds = false
        addSubview(artworkView)
        updateImage(image)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: CGSize { contentSize }

    func updateImage(_ image: UIImage) {
        if artworkView.image !== image { artworkView.image = image }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { setNeedsLayout() }
        onAvailable?()
    }

    override func layoutSubviews() {
        IOTimingDiagnostics.measure(.nativePosterLayout, minimumDurationNanoseconds: 1_000_000) {
            super.layoutSubviews()
            if artworkView.frame != bounds { artworkView.frame = bounds }
            refreshArtwork()
            onAvailable?()
        }
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        artworkView.updateFocus(isFocused, coordinator: coordinator)
        onFocus?(isFocused)
    }

    override func shouldUpdateFocus(in context: UIFocusUpdateContext) -> Bool {
        DetailTransitionNavigation.allowsFocusUpdate(heading: context.focusHeading, in: self)
            && super.shouldUpdateFocus(in: context)
    }

    private func refreshArtwork() {
        guard window != nil, bounds.width > 0, bounds.height > 0 else { return }
        autoreleasepool {
            if let image = prepareArtwork?(bounds.size) { updateImage(image) }
            artworkView.updateIndicator(prepareOverlay?(bounds.size), focused: isFocused)
        }
    }
}

private final class NativePosterPresentationKey: NSObject {
    let source: ObjectIdentifier?
    let treatment: NativePosterImageTreatment
    let size: CGSize
    let scale: CGFloat
    let preservesTransparency: Bool
    let indicators: NativePosterArtworkBitmap.IndicatorKey?
    let artworkBackground: NativePosterArtworkBackground

    init(
        image: UIImage?, treatment: NativePosterImageTreatment, size: CGSize, scale: CGFloat, preservesTransparency: Bool,
        indicators: NativePosterArtworkBitmap.IndicatorKey?, artworkBackground: NativePosterArtworkBackground
    ) {
        source = image.map(ObjectIdentifier.init)
        self.treatment = treatment
        self.size = size
        self.scale = scale
        self.preservesTransparency = preservesTransparency
        self.indicators = indicators
        self.artworkBackground = artworkBackground
    }

    override var hash: Int {
        var hasher = Hasher()
        hasher.combine(source)
        hasher.combine(size.width)
        hasher.combine(size.height)
        hasher.combine(scale)
        return hasher.finalize()
    }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? NativePosterPresentationKey else { return false }
        return source == other.source && treatment == other.treatment
            && size == other.size && scale == other.scale && preservesTransparency == other.preservesTransparency
            && indicators == other.indicators
            && artworkBackground == other.artworkBackground
    }
}

struct NativeTVPoster<Overlay: View>: UIViewRepresentable {
    let image: UIImage?
    var artworkIdentity: String? = nil
    var preservesArtworkTransparency = false
    let treatment: NativePosterImageTreatment
    let aspectRatio: CGFloat
    let fallbackWidth: CGFloat
    // Accessible metadata only. Visible captions must not inherit native image animation.
    let title: NativePosterText?
    let subtitle: String? // l10n:content — provider metadata and preformatted runtime
    let overlay: Overlay
    var rasterizesOverlay = true
    var clipsOverlayToArtwork = true
    var indicators: NativePosterIndicators? = nil
    var artworkBackground: NativePosterArtworkBackground = .init()
    let focus: PlozzCardFocus.Binding
    var source: DetailTransitionSourceReference? = nil
    let action: () -> Void

    @MainActor
    final class Coordinator {
        let focus: NativeTVMediaCoordinator
        let menu = NativeMediaItemMenuCoordinator()
        var original: UIImage?
        var treatment = NativePosterImageTreatment.original
        var imageSize = CGSize.zero
        var imageScale: CGFloat = 1
        var prepared: UIImage?
        private var presentationKey: NativePosterPresentationKey?
        private var presentationSource: UIImage?
        private var presentationIdentity: String?
        private var presentedImage: UIImage?
        private var retainedImage: UIImage?
        private(set) var displayedOverlay: NativePosterOverlay?
        private var presentationTask: Task<Void, Never>?
        private var presentationGeneration = 0

        init(focus: PlozzCardFocus.Binding, action: @escaping () -> Void) {
            self.focus = NativeTVMediaCoordinator(focus: focus, action: action)
        }

        deinit { presentationTask?.cancel() }

        func cancelPresentation() {
            presentationGeneration &+= 1
            presentationTask?.cancel()
            presentationTask = nil
            presentationKey = nil
            presentationSource = nil
            presentationIdentity = nil
            presentedImage = nil
            retainedImage = nil
            displayedOverlay = nil
            original = nil
            prepared = nil
        }

        func presentationImage(
            _ image: UIImage?, identity: String? = nil, preservesTransparency: Bool = false,
            treatment: NativePosterImageTreatment, size: CGSize,
            indicators: NativePosterIndicators?, artworkBackground: NativePosterArtworkBackground,
            environment: EnvironmentValues, onReady: ((UIImage) -> Void)? = nil
        ) -> UIImage {
            let scale = environment.displayScale
            // UIKit's rectangular focus surface requires opaque artwork. A
            // second, baked alpha corner separates from its highlight under tilt.
            let clipsToArtwork = preservesTransparency
            let backgroundColor: UIColor? = preservesTransparency ? nil : .darkGray
            let key = NativePosterPresentationKey(
                image: image, treatment: treatment, size: size, scale: scale, preservesTransparency: preservesTransparency,
                indicators: indicators.flatMap {
                    guard $0.hasContent(
                        indicator: environment.plozzWatchStatusIndicator,
                        showsEpisodeCount: environment.plozzShowsUnwatchedEpisodeCount,
                        seerConnected: environment.plozzSeerConnected
                    ) else { return nil }
                    let key = NativePosterArtworkBitmap.IndicatorKey($0, environment: environment)
                    return NativePosterArtworkBitmap.IndicatorKey(
                        $0, environment: environment,
                        layer: key.overlayPlacement != nil ? .background : .combined
                    )
                },
                artworkBackground: artworkBackground
            )
            if presentationSource === image, presentationIdentity == identity, presentationKey == key {
                if let presentedImage {
                    onReady?(presentedImage)
                    return presentedImage
                }
                return retainedImage ?? NativePosterArtworkBitmap.placeholder(
                    size: size, scale: scale, clipsToArtwork: clipsToArtwork
                )
            }
            // Keep chrome updates and progressive upgrades visible. A new
            // subject, spoiler treatment or geometry must still blank immediately.
            let sameArtwork = identity == presentationIdentity
                && (presentationSource === image || identity != nil)
            if image != nil, sameArtwork,
               presentationKey?.treatment == treatment, presentationKey?.size == size,
               presentationKey?.scale == scale, presentationKey?.preservesTransparency == preservesTransparency {
                retainedImage = presentedImage ?? retainedImage
            } else {
                retainedImage = nil
                displayedOverlay = nil
            }
            presentationGeneration &+= 1
            let generation = presentationGeneration
            presentationTask?.cancel()
            presentationKey = key
            presentationSource = image
            presentationIdentity = identity
            presentedImage = nil
            if let cached = NativePosterBitmapCache.cachedImage(source: image, key: key) {
                presentedImage = cached
                retainedImage = nil
                displayedOverlay = presentationOverlay(size: size, indicators: indicators, environment: environment)
                presentationTask = nil
                onReady?(cached)
                return cached
            }
            if treatment == .original {
                original = nil
                prepared = nil
            }
            let placeholder = NativePosterArtworkBitmap.placeholder(
                size: size, scale: scale, clipsToArtwork: clipsToArtwork
            )
            if image == nil, key.indicators == nil {
                presentedImage = placeholder
                retainedImage = nil
                displayedOverlay = nil
                presentationTask = nil
                onReady?(placeholder)
                return placeholder
            }
            presentationTask = Task { [weak self] in
                guard !Task.isCancelled else { return }
                defer {
                    if let self, self.presentationGeneration == generation {
                        self.presentationTask = nil
                        if self.presentedImage == nil { self.presentationKey = nil }
                    }
                }
                let purgesBefore = NativePosterBitmapCache.observePurges()
                let source = treatment == .original
                    ? image : self?.prepare(image, treatment: treatment, size: size, scale: scale)
                let overlay: UIImage?
                if let indicatorKey = key.indicators {
                    guard let rendered = NativePosterArtworkBitmap.indicatorImage(
                        key: indicatorKey, size: size, scale: scale, environment: environment
                    ) else { return }
                    overlay = rendered
                } else {
                    overlay = nil
                }
                let renderedResult = await NativePosterArtworkBitmap.composite(
                    source: source, overlay: overlay, size: size, scale: scale,
                    backgroundColor: backgroundColor, clipsToArtwork: clipsToArtwork,
                    artworkBackground: artworkBackground
                )
                guard !Task.isCancelled, let self, self.presentationGeneration == generation else { return }
                guard let result = renderedResult else {
                    PlozzLog.app.error("Unable to composite native poster artwork")
                    return
                }
                if NativePosterBitmapCache.purges == purgesBefore {
                    NativePosterBitmapCache.store(result, source: image, key: key)
                }
                self.presentedImage = result
                self.retainedImage = nil
                self.displayedOverlay = self.presentationOverlay(
                    size: size, indicators: indicators, environment: environment
                )
                onReady?(result)
            }
            return retainedImage ?? placeholder
        }

        func presentationOverlay(
            size: CGSize, indicators: NativePosterIndicators?, environment: EnvironmentValues
        ) -> NativePosterOverlay? {
            guard let indicators else { return nil }
            let key = NativePosterArtworkBitmap.IndicatorKey(indicators, environment: environment, layer: .foreground)
            guard let placement = key.overlayPlacement else { return nil }
            guard let image = NativePosterArtworkBitmap.indicatorImage(
                key: key, size: size, scale: environment.displayScale, environment: environment
            ) else { return nil }
            return NativePosterOverlay(image: image, placement: placement, layoutDirection: key.layoutDirection)
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
            if treatment == .original {
                prepared = NativePosterArtworkBitmap.image(source: image, size: size, scale: scale)
                return prepared
            }
            let portraitBlur: Bool?
            if case .extendedPortrait(let blurredReflection) = treatment {
                portraitBlur = blurredReflection
            } else {
                portraitBlur = nil
            }
            if treatment == .extended || portraitBlur != nil {
                prepared = ExtendedArtworkBitmap.render(
                    image: image, size: size, scale: scale,
                    artworkAspectRatio: portraitBlur != nil ? 2.0 / 3.0 : 16.0 / 9.0,
                    sideCrop: portraitBlur != nil ? 0 : PlozzTheme.Metrics.continueWatchingArtworkSideCrop,
                    minimumReflectionShare: portraitBlur != nil
                        ? PlozzTheme.Metrics.continueWatchingPortraitReflectionShare : 0,
                    progressivelyBlursReflection: portraitBlur ?? false
                )
                if prepared == nil { original = nil }
                return prepared
            }
            let renderer = ImageRenderer(content: Group {
                if case .upcoming(let background) = treatment {
                    Image(uiImage: image).resizable().scaledToFill()
                        .saturation(0)
                        .opacity(0.05)
                        .background(background)
                } else if treatment == .fitted {
                    Image(uiImage: image).resizable().scaledToFit()
                } else {
                    Image(uiImage: image).resizable().scaledToFill()
                        .blur(radius: treatment == .blurred ? 28 : 0)
                }
            }.frame(width: size.width, height: size.height).clipped())
            renderer.scale = scale
            renderer.isOpaque = true
            prepared = renderer.uiImage.flatMap {
                NativePosterArtworkBitmap.image(source: $0, size: size, scale: scale, clipsToArtwork: false)
            }
            if prepared == nil {
                PlozzLog.app.error("Unable to prepare native poster artwork; keeping the protected placeholder")
            }
            return prepared
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(focus: focus, action: action) }

    func makeUIView(context: Context) -> Container {
        let size = CGSize(width: fallbackWidth, height: fallbackWidth / aspectRatio)
        let view = NativePosterButton(image: NativePosterArtworkBitmap.placeholder(
            size: size, scale: context.environment.displayScale, clipsToArtwork: preservesArtworkTransparency
        ), masksFocusEffectToContents: preservesArtworkTransparency)
        view.defaultAccessibilityElement = view.isAccessibilityElement
        view.contentSize = size
        configureArtwork(view, context: context)
        view.hostedOverlay = overlayConfiguration(in: context).makeContentView()
        if let overlay = view.hostedOverlay {
            // Edge backgrounds stay baked; the separately aligned indicator
            // foreground and async logos use UIKit's live overlay surface.
            overlay.layer.shouldRasterize = rasterizesOverlay
            overlay.layer.rasterizationScale = context.environment.displayScale
            let container = view.overlayView
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
            guard let view else { return }
            if view.window == nil {
                coordinator?.cancelPresentation()
            } else {
                coordinator?.focus.requestFocusIfReady(in: view)
            }
        }
        view.addAction(UIAction { [weak coordinator = context.coordinator] _ in coordinator?.focus.activate() },
                       for: .primaryActionTriggered)
        return Container(poster: view)
    }

    static func dismantleUIView(_ container: Container, coordinator: Coordinator) {
        coordinator.cancelPresentation()
        coordinator.menu.update(nil, locale: .current, button: container.poster, interactionView: container)
        container.poster.prepareArtwork = nil
        container.poster.prepareOverlay = nil
        container.poster.onAvailable = nil
        container.poster.onFocus = nil
    }

    func updateUIView(_ container: Container, context: Context) {
        IOTimingDiagnostics.measure(.nativePosterUpdate, minimumDurationNanoseconds: 1_000_000) {
            updatePoster(container, context: context)
        }
    }

    private func updatePoster(_ container: Container, context: Context) {
        let view = container.poster
        if view.artworkView.masksFocusEffectToContents != preservesArtworkTransparency {
            view.artworkView.masksFocusEffectToContents = preservesArtworkTransparency
            view.artworkView.adjustsImageWhenAncestorFocused = view.isFocused
        }
        if view.contentSize.width <= 0 {
            view.contentSize = CGSize(width: fallbackWidth, height: fallbackWidth / aspectRatio)
        }
        let resolvedTitle = title?.resolve(locale: context.environment.locale)
        view.isAccessibilityElement = view.defaultAccessibilityElement || resolvedTitle != nil || subtitle != nil
        view.accessibilityLabel = resolvedTitle
        view.accessibilityValue = subtitle
        view.accessibilityTraits.insert(.button)
        view.hostedOverlay?.configuration = overlayConfiguration(in: context)
        view.hostedOverlay?.layer.shouldRasterize = rasterizesOverlay
        view.hostedOverlay?.layer.rasterizationScale = context.environment.displayScale
        container.aspectRatio = aspectRatio
        configureArtwork(view, context: context)
        view.isEnabled = context.environment.isEnabled
        context.coordinator.menu.update(
            context.environment.nativeMediaItemMenu, locale: context.environment.locale,
            button: view, interactionView: container
        )
        source?.nativeArtworkView = view.artworkView
        context.coordinator.focus.update(focus: focus, action: action, view: view)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: Container, context: Context) -> CGSize? {
        let width = proposal.width ?? fallbackWidth
        guard width.isFinite, width > 0 else { return nil }
        return CGSize(width: width, height: ceil(width / aspectRatio))
    }

    private func configureArtwork(_ view: NativePosterButton, context: Context) {
        let environment = context.environment
        view.prepareArtwork = { [weak coordinator = context.coordinator, weak view, image, artworkIdentity, preservesArtworkTransparency, treatment, indicators, artworkBackground] size in
            coordinator?.presentationImage(
                image, identity: artworkIdentity, preservesTransparency: preservesArtworkTransparency,
                treatment: treatment, size: size, indicators: indicators,
                artworkBackground: artworkBackground, environment: environment,
                onReady: { [weak view, weak coordinator] image in
                    guard let view else { return }
                    view.updateImage(image)
                    view.artworkView.updateIndicator(coordinator?.displayedOverlay, focused: view.isFocused)
                }
            )
        }
        view.prepareOverlay = { [weak coordinator = context.coordinator] _ in
            coordinator?.displayedOverlay
        }
        view.setNeedsLayout()
    }

    private func overlayConfiguration(in context: Context) -> any UIContentConfiguration {
        UIHostingConfiguration {
            Group {
                if clipsOverlayToArtwork {
                    overlay.clipShape(RoundedRectangle(
                        cornerRadius: PlozzTheme.Metrics.nativePosterArtworkCornerRadius, style: .circular))
                } else {
                    overlay
                }
            }
                .environment(\.plozzNativeArtworkSurface, true)
                .environment(\.plozzNativeFocusSurface, true)
                .environment(\.self, context.environment)
        }
        .margins(.all, 0)
    }

    final class Container: UIView {
        let poster: NativePosterButton
        var aspectRatio: CGFloat {
            didSet {
                if aspectRatio != oldValue { setNeedsLayout() }
            }
        }

        init(poster: NativePosterButton) {
            self.poster = poster
            self.aspectRatio = poster.contentSize.width / poster.contentSize.height
            super.init(frame: .zero)
            addSubview(poster)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override var intrinsicContentSize: CGSize {
            // SwiftUI must not round a fractional artwork height down into its caption.
            CGSize(width: poster.contentSize.width, height: ceil(poster.contentSize.height))
        }

        override var preferredFocusEnvironments: [any UIFocusEnvironment] { [poster] }

        override func layoutSubviews() {
            super.layoutSubviews()
            guard bounds.width > 0 else { return }
            // SwiftUI probes lazy-row sizes before mounting them. Only the
            // committed UIKit width may allocate artwork or change its size.
            let intrinsic = CGSize(width: bounds.width, height: bounds.width / aspectRatio)
            poster.contentSize = intrinsic
            let size = CGSize(width: ceil(intrinsic.width), height: ceil(intrinsic.height))
            let frame = CGRect(x: (bounds.width - size.width) / 2,
                               y: (bounds.height - size.height) / 2,
                               width: size.width, height: size.height)
            if poster.frame != frame { poster.frame = frame }
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
/// it takes the same room and has the same corners as the poster that replaces it. The poster is
/// disabled unless the caller supplies the explicit loading-entry focus binding.
struct NativePosterPlaceholder: UIViewRepresentable {
    let aspectRatio: CGFloat
    let fallbackWidth: CGFloat
    let fill: Color
    var focus: PlozzCardFocus.Binding?
    var showsProgress = false

    typealias Container = NativeTVPoster<EmptyView>.Container

    func makeCoordinator() -> NativeTVMediaCoordinator? {
        focus.map { NativeTVMediaCoordinator(focus: $0, action: {}) }
    }

    func makeUIView(context: Context) -> Container {
        let size = CGSize(width: fallbackWidth, height: fallbackWidth / aspectRatio)
        let poster = NativePosterButton(image: Self.blank(size, fill: fill))
        poster.contentSize = size
        poster.isEnabled = focus != nil && context.environment.isEnabled
        poster.isUserInteractionEnabled = focus != nil
        poster.isAccessibilityElement = focus != nil
        poster.onFocus = { [weak coordinator = context.coordinator] in coordinator?.observe($0) }
        poster.onAvailable = { [weak coordinator = context.coordinator, weak poster] in
            if let poster { coordinator?.requestFocusIfReady(in: poster) }
        }
        let sheen = configuration(in: context).makeContentView()
        poster.hostedOverlay = sheen
        let container = poster.overlayView
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
        poster.updateImage(Self.blank(poster.contentSize, fill: fill))
        poster.hostedOverlay?.configuration = configuration(in: context)
        poster.isEnabled = focus != nil && context.environment.isEnabled
        poster.isAccessibilityElement = focus != nil
        poster.accessibilityLabel = focus == nil
            ? nil : NativePosterText.localized("Loading").resolve(locale: context.environment.locale)
        if let focus { context.coordinator?.update(focus: focus, action: {}, view: poster) }
    }

    private func configuration(in context: Context) -> any UIContentConfiguration {
        UIHostingConfiguration {
            Color.clear
                .overlay { SkeletonLoadingIndicator(isVisible: showsProgress) }
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
            poster.updateImage(Self.blank(size, fill: fill))
            uiView.invalidateIntrinsicContentSize()
            uiView.setNeedsLayout()
        }
        return uiView.intrinsicContentSize
    }

    private struct BlankKey: Hashable {
        let width: CGFloat
        let height: CGFloat
        let fill: Color
    }
    @MainActor private static var blanks: [BlankKey: UIImage] = [:]

    @MainActor private static func blank(_ size: CGSize, fill: Color) -> UIImage {
        let key = BlankKey(width: size.width, height: size.height, fill: fill)
        if let image = blanks[key] { return image }
        guard let image = NativePosterArtworkBitmap.image(
            source: nil, size: size, scale: 1, backgroundColor: .darkGray,
            clipsToArtwork: false,
            drawOverlay: { context in
                context.setFillColor(UIColor(fill).cgColor)
                context.fill(CGRect(origin: .zero, size: size))
            }
        ) else {
            PlozzLog.app.error("Unable to prepare native loading artwork")
            return NativePosterArtworkBitmap.placeholder(size: size, scale: 1, clipsToArtwork: size.height <= size.width)
        }
        if blanks.count >= 16 { blanks.removeAll(keepingCapacity: true) }
        blanks[key] = image
        return image
    }
}
#endif
