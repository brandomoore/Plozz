#if canImport(UIKit)
import Observation
import UIKit
import CoreUI

/// Keeps the live renderer above a dismissing controller until its next host is laid out.
final class VideoPresentationHandoff: UIView {
    private weak var output: UIView?
    private weak var originalHost: UIView?
    private var originalBounds: CGRect = .zero
    private var originalCenter: CGPoint = .zero
    private var originalTransform: CGAffineTransform = .identity
    private var completion: (() -> Void)?
    private weak var receiver: VideoPresentationView?
    private var displayLink: CADisplayLink?
    private let retainedPicture: CGRect?
    private let retainedViewportSize: CGSize
    private let pictureCornerRadius: CGFloat
    private let animatesFocusTransition: Bool
    private var transitionAnimator: UIViewPropertyAnimator?
    private var transitionFinished = false
    private var isReturningOutput = false
    private var stableTarget: CGRect?
    private var stableTargetFrames = 0
    #if os(tvOS)
    private var focusEntry: VideoCardEntryTransition?
    private var stagedFocusFrame: CGRect?
    private var unstagedFocusFrame: CGRect?
    #endif

    private final class PresentationClock: NSObject {
        weak var owner: VideoPresentationHandoff?
        init(owner: VideoPresentationHandoff) { self.owner = owner }
        @objc func tick(_ link: CADisplayLink) {
            guard let owner else { link.invalidate(); return }
            owner.receivePresentedOutput()
        }
    }

    init?(engine: any VideoEngine, pictureCornerRadius: CGFloat? = nil,
          animatesFocusTransition: Bool = false,
          completion: @escaping () -> Void) {
        let output = engine.makeVideoOutputView()
        guard let window = output.window, !output.bounds.isEmpty else { return nil }
        #if os(tvOS)
        let previousEntry = (output.superview as? VideoPresentationView)?.focusEntryTransition
        let continuesEntry = previousEntry?.isActive == true
        #else
        let continuesEntry = false
        #endif
        let usesPresentation = animatesFocusTransition || continuesEntry
            || (output.superview as? VideoPresentationHandoff)?.animatesFocusTransition == true
        let windowLayer = usesPresentation ? window.layer.presentation() ?? window.layer : window.layer
        let outputLayer = usesPresentation ? output.layer.presentation() ?? output.layer : output.layer
        let picture = outputLayer.convert(outputLayer.bounds, to: windowLayer)
        let viewport = output.superview.map {
            let layer = usesPresentation ? $0.layer.presentation() ?? $0.layer : $0.layer
            return layer.convert(layer.bounds, to: windowLayer)
        } ?? picture
        let center = CGPoint(x: picture.midX, y: picture.midY)
        self.animatesFocusTransition = animatesFocusTransition
        self.pictureCornerRadius = pictureCornerRadius ?? 0
        retainedPicture = pictureCornerRadius.map { _ in
            picture.offsetBy(dx: -viewport.minX, dy: -viewport.minY)
        }
        retainedViewportSize = viewport.size
        super.init(frame: pictureCornerRadius == nil ? window.bounds : viewport)
        self.output = output
        originalHost = output.superview
        originalBounds = output.bounds
        originalCenter = output.center
        originalTransform = output.transform
        self.completion = completion
        backgroundColor = pictureCornerRadius == nil ? .black : .clear
        layer.cornerRadius = pictureCornerRadius ?? 0
        isUserInteractionEnabled = false
        clipsToBounds = true
        window.addSubview(self)
        addSubview(output)
        if pictureCornerRadius != nil {
            output.transform = CGAffineTransform(
                scaleX: picture.width / output.bounds.width, y: picture.height / output.bounds.height)
            output.center = CGPoint(x: picture.midX - viewport.minX, y: picture.midY - viewport.minY)
        } else {
            output.center = center
        }
        #if os(tvOS)
        previousEntry?.cancel()
        #endif
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func canReceiveOutput(in view: VideoPresentationView) -> Bool {
        guard let window, view.window === window, !view.bounds.isEmpty,
              view.layer.presentation() != nil else { return false }
        var ancestor: UIView? = view
        while let current = ancestor {
            if current.isHidden || current.alpha < 1 || current.layer.presentation()?.opacity == 0 { return false }
            ancestor = current.superview
        }
        if animatesFocusTransition, !transitionFinished { return false }
        return true
    }

    func waitForPresentation(of view: VideoPresentationView) {
        receiver = view
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: PresentationClock(owner: self), selector: #selector(PresentationClock.tick(_:)))
        displayLink = link
        link.add(to: .main, forMode: .common)
    }

    private func receivePresentedOutput() {
        guard let receiver else { return }
        if isReturningOutput, let output, let presented = output.layer.presentation() {
            guard presented.bounds == output.layer.bounds,
                  presented.position == output.layer.position,
                  CATransform3DEqualToTransform(presented.transform, output.layer.transform) else { return }
            isReturningOutput = false
            transitionFinished = true
        }
        if animatesFocusTransition, !transitionFinished {
            prepareFocusTransition(to: receiver)
            return
        }
        if !animatesFocusTransition, let retainedPicture, let output, output.superview === self,
           let window, receiver.window === window,
           let presented = receiver.layer.presentation(), !presented.bounds.isEmpty,
           retainedViewportSize.width > 0, retainedViewportSize.height > 0 {
            // Unfocused native card labels can fade in after their geometry starts moving.
            // Keep the live bridge on that same geometry until the label is fully visible.
            let target = presented.convert(presented.bounds, to: window.layer.presentation() ?? window.layer)
            let scaleX = target.width / retainedViewportSize.width
            let scaleY = target.height / retainedViewportSize.height
            UIView.performWithoutAnimation {
                frame = target
                output.transform = CGAffineTransform(
                    scaleX: retainedPicture.width * scaleX / output.bounds.width,
                    y: retainedPicture.height * scaleY / output.bounds.height)
                output.center = CGPoint(x: retainedPicture.midX * scaleX, y: retainedPicture.midY * scaleY)
            }
        }
        guard canReceiveOutput(in: receiver) else { return }
        receiver.setNeedsLayout()
        receiver.layoutIfNeeded()
    }

    private func prepareFocusTransition(to view: VideoPresentationView) {
        guard transitionAnimator == nil, let window, view.window === window,
              let presented = view.layer.presentation(), !presented.bounds.isEmpty else { return }
        var ancestor: UIView? = view
        while let current = ancestor {
            guard !current.isHidden, current.alpha >= 1,
                  (current.layer.presentation()?.opacity ?? 0) >= 0.999 else { return }
            ancestor = current.superview
        }
        let target = presented.convert(presented.bounds, to: window.layer.presentation() ?? window.layer)
        guard stableTarget == target else {
            stableTarget = target
            stableTargetFrames = 0
            return
        }
        stableTargetFrames += 1
        guard stableTargetFrames >= 2 else { return }
        #if os(tvOS)
        if let stagedFocusFrame, let focusEntry {
            guard let output else { return }
            if abs(target.minX - stagedFocusFrame.minX) >= 1
                || abs(target.minY - stagedFocusFrame.minY) >= 1
                || abs(target.width - stagedFocusFrame.width) >= 1
                || abs(target.height - stagedFocusFrame.height) >= 1 {
                guard target != unstagedFocusFrame else { return }
                // Native focus can settle after the initial card layout, or move
                // to another card while this replacement is being prepared.
                let size = CGSize(width: target.width / focusEntry.scale.width,
                                  height: target.height / focusEntry.scale.height)
                let destination = CGRect(
                    x: target.midX - focusEntry.offset.width - size.width / 2,
                    y: target.midY - focusEntry.offset.height - size.height / 2,
                    width: size.width, height: size.height)
                unstagedFocusFrame = destination
                focusEntry.prepare(from: stagedFocusFrame, to: destination)
                stableTarget = nil
                return
            }
            normalizeOutput(output, for: view, visibleFrame: stagedFocusFrame)
            isReturningOutput = true
            return
        }
        #endif
        guard retainedPicture != nil, output != nil,
              retainedViewportSize.width > 0, retainedViewportSize.height > 0 else { return }
        #if os(tvOS)
        if let entry = view.focusEntryTransition {
            focusEntry = entry
            stagedFocusFrame = frame
            unstagedFocusFrame = target
            entry.prepare(from: frame, to: target)
            return
        }
        #endif
        let scaleX = target.width / retainedViewportSize.width
        let scaleY = target.height / retainedViewportSize.height
        let targetRadius = pictureCornerRadius / max(scaleX, scaleY)
        let animator = UIViewPropertyAnimator(duration: MultiviewMotion.duration, curve: .easeInOut) { [weak self] in
            guard let self else { return }
            // Animate the owned bridge, never the renderer: its transform must
            // not survive reparenting and compound the destination's native lift.
            self.transform = CGAffineTransform(scaleX: scaleX, y: scaleY)
            self.center = CGPoint(x: target.midX, y: target.midY)
            self.layer.cornerRadius = targetRadius
        }
        transitionAnimator = animator
        animator.addCompletion { [weak self] position in
            guard let self, let view = self.receiver, let window = self.window,
                  let presented = view.layer.presentation(), !view.bounds.isEmpty,
                  let output = self.output, position == .end else { return }
            let currentTarget = presented.convert(presented.bounds, to: window.layer.presentation() ?? window.layer)
            guard currentTarget == target else {
                self.transitionAnimator = nil
                self.stableTarget = nil
                return
            }
            // Commit the receiver's local geometry while the bridge still owns
            // the renderer. Reparenting with old presentation bounds produces
            // one frame of the old size multiplied by the new native focus lift.
            self.normalizeOutput(output, for: view, visibleFrame: target)
            self.isReturningOutput = true
        }
        animator.startAnimation()
    }

    private func normalizeOutput(_ output: UIView, for view: VideoPresentationView, visibleFrame: CGRect) {
        UIView.performWithoutAnimation {
            let visibleRadius = layer.cornerRadius * max(abs(transform.a), abs(transform.d))
            layer.removeAllAnimations()
            transform = .identity
            bounds = view.bounds
            center = CGPoint(x: visibleFrame.midX, y: visibleFrame.midY)
            transform = CGAffineTransform(
                scaleX: visibleFrame.width / view.bounds.width, y: visibleFrame.height / view.bounds.height)
            layer.cornerRadius = visibleRadius / max(abs(transform.a), abs(transform.d))
            view.prepareHandoffOutput(output)
        }
    }

    func complete() {
        transitionAnimator = nil
        displayLink?.invalidate()
        displayLink = nil
        receiver = nil
        removeFromSuperview()
        // The receiving UIView has laid out; leave SwiftUI's update before changing its state.
        Task { @MainActor [weak self] in
            #if os(tvOS)
            self?.focusEntry?.animate()
            self?.focusEntry = nil
            #endif
            let completion = self?.completion
            self?.completion = nil
            completion?()
        }
    }

    func cancel(restoringOutput: Bool = false) {
        #if os(tvOS)
        focusEntry?.cancel()
        focusEntry = nil
        #endif
        transitionAnimator?.stopAnimation(true)
        transitionAnimator = nil
        displayLink?.invalidate()
        displayLink = nil
        receiver = nil
        completion = nil
        if let output, output.superview === self {
            if restoringOutput, let originalHost, originalHost.window != nil {
                UIView.performWithoutAnimation {
                    output.transform = .identity
                    output.bounds = originalBounds
                    output.center = originalCenter
                    output.transform = originalTransform
                    originalHost.addSubview(output)
                }
            } else {
                output.removeFromSuperview()
            }
        }
        removeFromSuperview()
    }
}

/// Crops only the engine's surface. AVKit's external/PiP presentation keeps
/// owning its own sizing. Light preview colors use a separately bounded sampler.
final class VideoPresentationView: UIView {
    #if os(tvOS)
    weak var focusEntryTransition: VideoCardEntryTransition?
    #endif
    private var engine: (any VideoEngine)?
    private var surface: UIView?
    private var defersOffscreenAttachment = false
    private var presentationHandoff: VideoPresentationHandoff?
    private weak var pendingHandoffOutput: UIView?
    private var zoom = PlayerVideoZoom()
    private var aspectRatio: Double?
    private var fitsInsideSafeArea = false
    private var needsPictureSubtitles = false
    private var activePicture: CGRect?
    private var pictureTask: Task<Void, Never>?
    private var pictureToken = UUID()
    private var pictureSuspended = false
    private var pictureObservers: [NSObjectProtocol] = []
    private final class PictureOwner {
        weak var view: VideoPresentationView?
        let token: UUID
        init(_ view: VideoPresentationView, token: UUID) { self.view = view; self.token = token }
    }
    private static var pictureOwners: [ObjectIdentifier: PictureOwner] = [:]
    #if os(iOS)
    private let reflection = VideoPreviewReflectionView()
    private var colorSampler: VideoPreviewColorSampler?
    private var activationObservers: [NSObjectProtocol] = []
    private var permitsColorSampling = true
    private var reflectionIsActive = true
    var previewColorSampleCount: Int { colorSampler?.sampleCount ?? 0 }
    var isPreviewColorSampling: Bool { colorSampler?.isRunning ?? false }
    #endif
    private(set) var fitBounds: CGRect?
    weak var subtitleViewport: VideoSubtitleViewport? {
        didSet { subtitleViewport?.attachVideoView(self) }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        clipsToBounds = true
        isUserInteractionEnabled = false
        pictureObservers = [
            NotificationCenter.default.addObserver(
                forName: UIApplication.willResignActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.pictureSuspended = true
                    self?.stopPictureSampling()
                }
            },
            NotificationCenter.default.addObserver(
                forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.pictureSuspended = false
                    self?.updatePictureSampling()
                }
            }
        ]
        #if os(iOS)
        addSubview(reflection)
        activationObservers = [
            NotificationCenter.default.addObserver(
                forName: UIApplication.willResignActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.permitsColorSampling = false
                    self?.colorSampler?.stop()
                    self?.reflection.updateColors([], animated: false)
                    self?.reflection.updateDarkReflection(isActive: false, animated: false)
                }
            },
            NotificationCenter.default.addObserver(
                forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.permitsColorSampling = true
                    self?.updateColorSampling()
                }
            }
        ]
        #endif
    }

    deinit {
        pictureTask?.cancel()
        for observer in pictureObservers { NotificationCenter.default.removeObserver(observer) }
        #if os(iOS)
        for observer in activationObservers { NotificationCenter.default.removeObserver(observer) }
        #endif
        // Avoid isolated-deinit back deployment without releasing another view's analysis.
        let cleanup: @MainActor @Sendable () -> Void = {
            [engine, pictureToken, activePicture, weak subtitleViewport] in
            if let engine, Self.pictureOwners[ObjectIdentifier(engine)]?.token == pictureToken {
                Self.pictureOwners.removeValue(forKey: ObjectIdentifier(engine))
                engine.stopActivePictureAnalysis()
            }
            if activePicture != nil { subtitleViewport?.scheduleUpdate() }
        }
        if Thread.isMainThread {
            MainActor.assumeIsolated { cleanup() }
        } else {
            Task { @MainActor in cleanup() }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func attach(_ engine: any VideoEngine, deferringOffscreenAttachment: Bool = false) {
        defersOffscreenAttachment = deferringOffscreenAttachment
        let changesEngine = self.engine !== engine
        if changesEngine { stopPictureSampling() }
        let output = engine.makeVideoOutputView()
        self.engine = engine
        #if os(iOS)
        updateColorSampling()
        #endif
        guard output.superview !== surfaceHost else { return }
        // Native card styles can prepare an offscreen label while the previous
        // label is still presenting this same live output.
        if deferringOffscreenAttachment, output.window != nil {
            guard window != nil else { return }
            // An outgoing label can still receive updates during its removal
            // animation. It must not reclaim a renderer its replacement owns.
            if !changesEngine, surface === output { return }
        }
        attachOutput(output)
    }

    private func attachOutput(_ output: UIView) {
        guard output.superview !== surfaceHost else { return }
        if let handoff = output.superview as? VideoPresentationHandoff, !handoff.canReceiveOutput(in: self) {
            pendingHandoffOutput = output
            handoff.waitForPresentation(of: self)
            return
        }
        pendingHandoffOutput = nil
        presentationHandoff = output.superview as? VideoPresentationHandoff
        if surface?.superview === surfaceHost { surface?.removeFromSuperview() }
        output.removeFromSuperview()
        output.autoresizingMask = []
        output.isUserInteractionEnabled = false
        surface = output
        UIView.performWithoutAnimation {
            if presentationHandoff != nil {
                prepareHandoffOutput(output)
            }
            surfaceHost.addSubview(output)
        }
        setNeedsLayout()
    }

    private var surfaceHost: UIView {
        #if os(iOS)
        reflection.source
        #else
        self
        #endif
    }

    func updateReflection(
        height: CGFloat, topHeight: CGFloat = 0, leftWidth: CGFloat = 0, rightWidth: CGFloat = 0,
        previewCornerRadius: CGFloat = 0, lightAppearance: Bool = false, isActive: Bool = true
    ) {
        #if os(iOS)
        let insets = UIEdgeInsets(top: topHeight, left: leftWidth, bottom: height, right: rightWidth)
        guard reflection.insets != insets || reflection.previewCornerRadius != previewCornerRadius
            || reflection.lightAppearance != lightAppearance || reflectionIsActive != isActive else { return }
        reflectionIsActive = isActive
        reflection.insets = insets
        reflection.previewCornerRadius = previewCornerRadius
        reflection.lightAppearance = lightAppearance
        updateColorSampling()
        clipsToBounds = insets == .zero
        backgroundColor = previewCornerRadius > 0 || insets != .zero ? .clear : .black
        setNeedsLayout()
        #endif
    }

    func update(zoom: PlayerVideoZoom, aspectRatio: Double? = nil, fitsInsideSafeArea: Bool = false,
                needsPictureSubtitles: Bool = false) {
        let ratio = aspectRatio ?? engine?.videoAspectRatio
        let needsUpdate = self.fitsInsideSafeArea != fitsInsideSafeArea
            || self.aspectRatio != ratio || self.zoom != zoom
        self.zoom = zoom
        self.aspectRatio = ratio
        self.fitsInsideSafeArea = fitsInsideSafeArea
        self.needsPictureSubtitles = needsPictureSubtitles
        updatePictureSampling()
        guard needsUpdate || fitBounds != resolvedFitBounds else { return }
        setNeedsLayout()
        layoutIfNeeded()
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        setNeedsLayout()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // Another offscreen label may have claimed the output before this host
        // entered the window, even if its initial attachment was not deferred.
        if window != nil, defersOffscreenAttachment, let engine {
            attachOutput(engine.makeVideoOutputView())
        }
        updatePictureSampling()
        #if os(iOS)
        updateColorSampling()
        #endif
        setNeedsLayout()
        subtitleViewport?.scheduleUpdate()
    }

    private var shouldSamplePicture: Bool {
        guard window != nil, !pictureSuspended, let engine, engine.supportsActivePictureAnalysis,
              engine.isPlaybackPositionReady,
              surface?.superview === surfaceHost, needsPictureSubtitles || zoom.mode == .picture
        else { return false }
        #if os(iOS)
        if (engine as? any PictureInPicturePresentingEngine)?.continuesPlaybackInBackground == true { return false }
        #endif
        return engine.nowPlayingPlayer?.isExternalPlaybackActive != true
    }

    private func updatePictureSampling() {
        guard shouldSamplePicture, let engine else { stopPictureSampling(); return }
        guard pictureTask == nil else { return }
        let id = ObjectIdentifier(engine)
        Self.pictureOwners[id]?.view?.stopPictureSampling()
        let token = UUID()
        Self.pictureOwners[id] = PictureOwner(self, token: token)
        pictureToken = token
        pictureTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard await self?.samplePicture(token: token) == true else { return }
                do { try await Task.sleep(for: .milliseconds(500)) }
                catch { return }
            }
        }
    }

    private func samplePicture(token: UUID) async -> Bool {
        guard shouldSamplePicture, let engine else { stopPictureSampling(); return false }
        let result = await engine.sampleActivePicture()
        guard !Task.isCancelled, pictureToken == token, self.engine === engine else { return false }
        guard shouldSamplePicture else { stopPictureSampling(); return false }
        let next: CGRect?
        if case let .measured(rect, size) = result, VideoActivePictureGeometry.isValid(rect),
           size.width > 0, size.height > 0, let ratio = engine.videoAspectRatio,
           abs(size.width / size.height - ratio) < 0.01 {
            next = rect
        } else {
            next = nil
        }
        if activePicture != next {
            activePicture = next
            setNeedsLayout()
            layoutIfNeeded()
        }
        return true
    }

    private func stopPictureSampling() {
        guard pictureTask != nil || activePicture != nil else { return }
        let ownershipToken = pictureToken
        pictureToken = UUID()
        pictureTask?.cancel()
        pictureTask = nil
        if let engine, Self.pictureOwners[ObjectIdentifier(engine)]?.token == ownershipToken {
            Self.pictureOwners.removeValue(forKey: ObjectIdentifier(engine))
            engine.stopActivePictureAnalysis()
        }
        if activePicture != nil {
            activePicture = nil
            setNeedsLayout()
            subtitleViewport?.scheduleUpdate()
        }
    }

    #if os(iOS)
    private func updateColorSampling() {
        let visible = permitsColorSampling && reflection.insets != .zero
            && window?.windowScene?.activationState == .foregroundActive
            && !UIAccessibility.isReduceTransparencyEnabled
        reflection.updateDarkReflection(
            isActive: visible && reflectionIsActive && !reflection.lightAppearance,
            animated: visible && !reflection.lightAppearance
        )
        let enabled = permitsColorSampling && reflection.lightAppearance && reflection.insets != .zero
            && window?.windowScene?.activationState == .foregroundActive
            && !UIAccessibility.isReduceTransparencyEnabled
        guard let engine, enabled, reflectionIsActive else {
            colorSampler?.stop()
            if !enabled { reflection.updateColors([], animated: false) }
            return
        }
        if colorSampler == nil {
            colorSampler = VideoPreviewColorSampler { [weak self] colors in
                self?.reflection.updateColors(colors)
            }
        }
        colorSampler?.update(engine: engine, enabled: true)
    }
    #endif

    private var resolvedFitBounds: CGRect? {
        #if os(iOS)
        guard fitsInsideSafeArea,
              (engine as? any PictureInPicturePresentingEngine)?.continuesPlaybackInBackground != true
        else { return nil }
        var safe = bounds.inset(by: safeAreaInsets)
        if let window {
            // SwiftUI's ignoresSafeArea can zero the view's insets; the current
            // window still describes the physical cutout and home-indicator area.
            let windowSafe = convert(window.bounds.inset(by: window.safeAreaInsets), from: window)
            safe = safe.intersection(windowSafe)
        }
        if bounds.width > bounds.height {
            // Landscape video can extend behind the home indicator; only the
            // horizontal cutout insets should constrain the fitted picture.
            safe = CGRect(x: safe.minX, y: bounds.minY, width: safe.width, height: bounds.height)
        }
        return safe
        #else
        return nil
        #endif
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if let output = pendingHandoffOutput, output.superview is VideoPresentationHandoff {
            attachOutput(output)
        } else {
            pendingHandoffOutput = nil
        }
        aspectRatio = engine?.videoAspectRatio
        fitBounds = resolvedFitBounds
        #if os(iOS)
        reflection.videoSize = bounds.size
        reflection.picture = (videoRect ?? bounds).intersection(bounds)
        reflection.frame = CGRect(
            x: bounds.minX - reflection.insets.left, y: bounds.minY - reflection.insets.top,
            width: bounds.width + reflection.insets.left + reflection.insets.right,
            height: bounds.height + reflection.insets.top + reflection.insets.bottom
        )
        reflection.layoutIfNeeded()
        #endif
        guard let surface, surface.superview === surfaceHost else { return }
        layoutSurface(surface)
        subtitleViewport?.scheduleUpdate()
        if window != nil, !bounds.isEmpty, let handoff = presentationHandoff {
            presentationHandoff = nil
            handoff.complete()
        }
    }

    private func layoutSurface(_ surface: UIView) {
        let contentBounds = CGRect(origin: .zero, size: bounds.size)
        let center = zoom.surfaceCenter(in: bounds, fitBounds: fitBounds, aspectRatio: aspectRatio, activePicture: activePicture)
        let scale = zoom.scaleFactors(in: bounds, aspectRatio: aspectRatio, fitBounds: fitBounds, activePicture: activePicture)
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

    fileprivate func prepareHandoffOutput(_ output: UIView) {
        aspectRatio = engine?.videoAspectRatio
        fitBounds = resolvedFitBounds
        layoutSurface(output)
    }

    #if os(iOS)
    /// Replicates the existing compositor surface, not a second player or decoded frame.
    final class VideoPreviewReflectionView: UIView {
        let source = UIView()
        var videoSize: CGSize = .zero {
            didSet { if oldValue != videoSize { setNeedsLayout() } }
        }
        var picture: CGRect = .zero {
            didSet { if oldValue != picture { setNeedsLayout() } }
        }
        var insets: UIEdgeInsets = .zero {
            didSet { if oldValue != insets { setNeedsLayout() } }
        }
        var previewCornerRadius: CGFloat = 0 {
            didSet { if oldValue != previewCornerRadius { setNeedsLayout() } }
        }
        var lightAppearance = false {
            didSet {
                guard oldValue != lightAppearance else { return }
                blur.effect = UIBlurEffect(style: lightAppearance
                    ? .systemThinMaterialLight : .systemUltraThinMaterialDark)
                setNeedsLayout()
            }
        }
        private static let fadeSteps: [CGFloat] = [0, 0.2, 0.4, 0.6, 0.8, 1]
        private let topReplicas = VideoPreviewReplicaView()
        private let replicas = VideoPreviewReplicaView()
        private let leftReplicas = VideoPreviewReplicaView()
        private let rightReplicas = VideoPreviewReplicaView()
        private let pictureCrop = CAShapeLayer()
        private let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
        private let blurMask = CAShapeLayer()
        private let fade = CAGradientLayer()
        private let horizontalFade = CAGradientLayer()
        private let glow = CAGradientLayer()
        private let reflectionVisibility = CALayer()
        private let surroundingVisibility = CALayer()
        private let pictureVisibility = CAShapeLayer()

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            accessibilityElementsHidden = true
            source.backgroundColor = .black
            source.clipsToBounds = true
            addSubview(topReplicas)
            layer.insertSublayer(glow, at: 0)
            glow.startPoint = CGPoint(x: 0, y: 0.5)
            glow.endPoint = CGPoint(x: 1, y: 0.5)
            topReplicas.addSubview(replicas)
            replicas.addSubview(leftReplicas)
            leftReplicas.addSubview(rightReplicas)
            rightReplicas.addSubview(source)
            pictureCrop.fillColor = UIColor.white.cgColor
            blurMask.fillColor = UIColor.white.cgColor
            blurMask.fillRule = .evenOdd
            blur.layer.mask = blurMask
            addSubview(blur)
            fade.startPoint = CGPoint(x: 0.5, y: 0)
            fade.endPoint = CGPoint(x: 0.5, y: 1)
            horizontalFade.startPoint = CGPoint(x: 0, y: 0.5)
            horizontalFade.endPoint = CGPoint(x: 1, y: 0.5)
            fade.mask = horizontalFade
            horizontalFade.mask = reflectionVisibility
            surroundingVisibility.backgroundColor = UIColor.white.cgColor
            surroundingVisibility.opacity = 0
            pictureVisibility.fillColor = UIColor.white.cgColor
            reflectionVisibility.addSublayer(surroundingVisibility)
            reflectionVisibility.addSublayer(pictureVisibility)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        func updateDarkReflection(isActive: Bool, animated: Bool = true) {
            let target: Float = isActive || lightAppearance ? 1 : 0
            let animates = animated && !UIAccessibility.isReduceMotionEnabled
            guard surroundingVisibility.opacity != target else {
                if !animates { surroundingVisibility.removeAllAnimations() }
                return
            }
            let current = surroundingVisibility.presentation()?.opacity ?? surroundingVisibility.opacity
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            surroundingVisibility.opacity = target
            CATransaction.commit()
            guard animates else {
                surroundingVisibility.removeAllAnimations()
                return
            }
            let transition = CABasicAnimation(keyPath: "opacity")
            transition.fromValue = current
            transition.toValue = target
            transition.duration = 0.6
            surroundingVisibility.add(transition, forKey: "visibility")
        }

        func updateColors(_ samples: [SIMD4<Float>], animated: Bool = true) {
            let colors = samples.map {
                UIColor(red: CGFloat($0.x), green: CGFloat($0.y),
                        blue: CGFloat($0.z), alpha: CGFloat($0.w)).cgColor
            }
            let previous = glow.colors as? [CGColor] ?? []
            let oldColors = previous.isEmpty ? [] : (glow.presentation()?.colors as? [CGColor] ?? previous)
            let animates = animated && !UIAccessibility.isReduceMotionEnabled
            let target = colors.isEmpty && animates
                ? previous.map { UIColor(cgColor: $0).withAlphaComponent(0).cgColor }
                : colors
            if animates, previous == target { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            glow.colors = target.isEmpty ? nil : target
            CATransaction.commit()
            guard !target.isEmpty, animates else {
                glow.removeAllAnimations()
                return
            }
            let transition = CABasicAnimation(keyPath: "colors")
            transition.fromValue = oldColors.isEmpty ? target.map {
                UIColor(cgColor: $0).withAlphaComponent(0).cgColor
            } : oldColors
            transition.toValue = target
            transition.duration = 0.6
            glow.add(transition, forKey: "colors")
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            defer { CATransaction.commit() }
            topReplicas.frame = CGRect(origin: CGPoint(x: insets.left, y: insets.top), size: videoSize)
            replicas.frame = topReplicas.bounds
            leftReplicas.frame = replicas.bounds
            rightReplicas.frame = leftReplicas.bounds
            source.frame = rightReplicas.bounds
            let reflects = insets != .zero
            let decorates = reflects || previewCornerRadius > 0
            let visiblePicture = decorates ? picture : source.bounds
            isHidden = visiblePicture.isEmpty || visiblePicture.isNull || visiblePicture.isInfinite
            guard !isHidden else { return }
            let translatedPicture = visiblePicture.offsetBy(dx: insets.left, dy: insets.top)
            let left = max(0, translatedPicture.minX)
            let right = max(0, bounds.width - translatedPicture.maxX)
            let top = max(0, translatedPicture.minY)
            let bottom = max(0, bounds.height - translatedPicture.maxY)
            let radius = left > 1 && right > 1 ? previewCornerRadius : 0
            pictureCrop.frame = source.bounds
            pictureCrop.path = UIBezierPath(roundedRect: visiblePicture, cornerRadius: radius).cgPath
            source.layer.mask = decorates ? pictureCrop : nil
            configureReplica(rightReplicas, horizontal: true, edge: visiblePicture.maxX,
                             extent: right, pictureLength: visiblePicture.width, enabled: reflects && !lightAppearance)
            configureReplica(leftReplicas, horizontal: true, edge: visiblePicture.minX,
                             extent: left, pictureLength: visiblePicture.width, enabled: reflects && !lightAppearance)
            configureReplica(replicas, horizontal: false, edge: visiblePicture.maxY,
                             extent: bottom, pictureLength: visiblePicture.height, enabled: reflects && !lightAppearance)
            configureReplica(topReplicas, horizontal: false, edge: visiblePicture.minY,
                             extent: top, pictureLength: visiblePicture.height, enabled: reflects && !lightAppearance)
            blur.isHidden = !reflects || lightAppearance
            glow.frame = bounds
            glow.isHidden = !reflects || !lightAppearance
            let blurScale: CGFloat = 4
            blur.bounds = CGRect(x: 0, y: 0, width: bounds.width / blurScale, height: bounds.height / blurScale)
            blur.center = CGPoint(x: bounds.midX, y: bounds.midY)
            blur.transform = CGAffineTransform(scaleX: blurScale, y: blurScale)
            let blurPath = UIBezierPath(rect: blur.bounds)
            let sharpPicture = CGRect(
                x: translatedPicture.minX / blurScale, y: translatedPicture.minY / blurScale,
                width: translatedPicture.width / blurScale, height: translatedPicture.height / blurScale
            )
            blurPath.append(UIBezierPath(roundedRect: sharpPicture, cornerRadius: radius / blurScale))
            blurMask.frame = blur.bounds
            blurMask.path = blurPath.cgPath
            fade.frame = bounds
            horizontalFade.frame = fade.bounds
            reflectionVisibility.frame = fade.bounds
            surroundingVisibility.frame = reflectionVisibility.bounds
            pictureVisibility.frame = reflectionVisibility.bounds
            pictureVisibility.path = UIBezierPath(roundedRect: translatedPicture, cornerRadius: radius).cgPath
            configureFade(fade, before: top, pictureLength: visiblePicture.height, after: bottom)
            configureFade(horizontalFade, before: left, pictureLength: visiblePicture.width, after: right)
            layer.mask = reflects ? fade : nil
        }

        private func configureReplica(
            _ view: VideoPreviewReplicaView, horizontal: Bool, edge: CGFloat,
            extent: CGFloat, pictureLength: CGFloat, enabled: Bool
        ) {
            view.replicaLayer.instanceCount = enabled && extent > 0 ? 2 : 1
            view.replicaLayer.instanceAlphaOffset = 0
            // Stretch only the reflected tile when a narrow picture has wider gutters.
            let scale = max(1, extent / max(1, pictureLength))
            let anchor = (horizontal ? videoSize.width : videoSize.height) / 2
            let translation = (1 + scale) * (edge - anchor)
            view.replicaLayer.instanceTransform = CATransform3DConcat(
                CATransform3DMakeScale(horizontal ? -scale : 1, horizontal ? 1 : -scale, 1),
                CATransform3DMakeTranslation(horizontal ? translation : 0, horizontal ? 0 : translation, 0)
            )
        }

        private func configureFade(_ gradient: CAGradientLayer, before: CGFloat, pictureLength: CGFloat, after: CGFloat) {
            let total = max(1, before + pictureLength + after)
            var locations: [CGFloat] = [0]
            var alphas: [CGFloat] = [before > 0 ? 0 : 1]
            for step in Self.fadeSteps.dropFirst() where before > 0 {
                locations.append(before * step / total)
                alphas.append(lightAppearance ? step : step * step)
            }
            locations.append((before + pictureLength) / total)
            alphas.append(1)
            for step in Self.fadeSteps.dropFirst() where after > 0 {
                locations.append((before + pictureLength + after * step) / total)
                alphas.append(lightAppearance ? 1 - step : (1 - step) * (1 - step))
            }
            gradient.locations = locations.map { NSNumber(value: Double($0)) }
            gradient.colors = alphas.map { UIColor.white.withAlphaComponent($0).cgColor }
        }
    }

    private final class VideoPreviewReplicaView: UIView {
        override class var layerClass: AnyClass { CAReplicatorLayer.self }
        var replicaLayer: CAReplicatorLayer { layer as! CAReplicatorLayer }
    }
    #endif

    var videoRect: CGRect? {
        zoom.videoRect(in: bounds, aspectRatio: aspectRatio, fitBounds: fitBounds, activePicture: activePicture)
    }
    var activePictureRect: CGRect? {
        videoRect.map { VideoActivePictureGeometry.map(activePicture, into: $0).intersection(bounds) }
    }
    var sourceAspectRatio: Double? { aspectRatio }
}

/// Shares the rendered picture with a separately laid-out subtitle overlay,
/// without moving ordinary captions or assuming both views have the same origin.
@MainActor
@Observable
final class VideoSubtitleViewport {
    private(set) var videoRect: CGRect?
    private(set) var activePictureRect: CGRect?
    @ObservationIgnored private weak var videoView: VideoPresentationView?
    @ObservationIgnored private weak var subtitleView: UIView?
    @ObservationIgnored private var updateScheduled = false

    func attachVideoView(_ view: VideoPresentationView) {
        videoView = view
        scheduleUpdate()
    }

    func attachSubtitleView(_ view: UIView) {
        subtitleView = view
        scheduleUpdate()
    }

    func scheduleUpdate() {
        guard !updateScheduled else { return }
        updateScheduled = true
        // Representable updates/layout must not synchronously publish into
        // the SwiftUI graph that is currently placing these views.
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.updateScheduled = false
            let rect: CGRect?
            let activeRect: CGRect?
            if let videoView = self.videoView, let subtitleView = self.subtitleView,
               let window = videoView.window, subtitleView.window === window {
                rect = videoView.videoRect.map { videoView.convert($0, to: subtitleView) }
                activeRect = videoView.activePictureRect.map { videoView.convert($0, to: subtitleView) }
            } else {
                rect = nil
                activeRect = nil
            }
            if self.videoRect != rect { self.videoRect = rect }
            if self.activePictureRect != activeRect { self.activePictureRect = activeRect }
        }
    }
}
#endif
