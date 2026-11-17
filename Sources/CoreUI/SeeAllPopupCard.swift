#if os(tvOS)
import CoreModels
import Observation
import SwiftUI

/// The floating details card for the See all grid. It is display-only: the grid
/// keeps focus, and the card is hidden from hit testing and the focus engine.
public struct SeeAllPopupCard: View {
    static let width: CGFloat = 560
    let content: SeeAllPopupContent
    /// Called once the whole synopsis has been shown: straight away when it fits,
    /// otherwise when it has finished scrolling. The pop-up's timeout counts from here.
    let onReadingFinished: @MainActor () -> Void

    public init(content: SeeAllPopupContent, onReadingFinished: @escaping @MainActor () -> Void = {}) {
        self.content = content
        self.onReadingFinished = onReadingFinished
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Group {
                if let resource = content.titleResource {
                    Text(resource)
                } else {
                    Text(verbatim: content.title) // l10n:content — catalog title
                }
            }
            .font(.title3.weight(.semibold))
            .lineLimit(3)
            if let subtitle = content.subtitle {
                Text(verbatim: subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(1) // l10n:content
            }
            if !content.facts.isEmpty {
                Text(verbatim: content.facts.joined(separator: " · ")).font(.callout).foregroundStyle(.secondary) // l10n:content
            }
            if !content.ratings.isEmpty {
                Text(verbatim: content.ratings.joined(separator: "  ")).font(.callout.weight(.medium)) // l10n:content
            }
            if !content.genres.isEmpty {
                Text(verbatim: content.genres.joined(separator: " · ")).font(.callout).foregroundStyle(.secondary) // l10n:content
            }
            if let overview = content.overview {
                ScrollingSynopsis(text: overview, onFinished: onReadingFinished)
            }
        }
        .onAppear { if content.overview == nil { onReadingFinished() } }
        .padding(28)
        .frame(width: Self.width, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: .black.opacity(0.35), radius: 30, y: 10)
        .allowsHitTesting(false)
        .focusable(false)
        .accessibilityElement(children: .combine)
    }
}

/// The synopsis in full: text taller than the window drifts upward after a
/// short pause, ending on its last line. The card never takes focus, so it
/// scrolls itself rather than waiting for input.
private struct ScrollingSynopsis: View {
    static let windowHeight: CGFloat = 220
    static let pointsPerSecond: CGFloat = 22
    let text: String
    let onFinished: @MainActor () -> Void
    @State private var contentHeight: CGFloat = 0
    @State private var offset: CGFloat = 0

    private var overflow: CGFloat { max(0, contentHeight - Self.windowHeight) }

    var body: some View {
        Text(verbatim: text).font(.callout) // l10n:content
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            .offset(y: -offset)
            .frame(height: contentHeight > 0 ? min(contentHeight, Self.windowHeight) : nil, alignment: .top)
            .clipped()
            .task(id: contentHeight) {
                offset = 0
                // Not measured yet: finishing now would start the timeout too early.
                guard contentHeight > 0 else { return }
                guard overflow > 0 else { onFinished(); return }
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                let scrollTime = Double(overflow / Self.pointsPerSecond)
                withAnimation(.linear(duration: scrollTime)) { offset = overflow }
                do { try await Task.sleep(for: .seconds(scrollTime)) } catch { return }
                onFinished()
            }
    }
}

enum SeeAllPopupTiming {
    /// Seconds the card takes to fade in when it appears.
    static let fadeIn = 0.45
    /// Seconds the card takes to fade out once its time on screen is up.
    static let fadeOut = 0.6
}

/// Lets a pop-up's timeout wait for its synopsis to finish scrolling. A finish
/// that arrives before anyone is waiting is kept, so the order never matters.
@MainActor
final class SeeAllPopupReading {
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() {
        (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
    }

    func finish() {
        continuation.yield()
        continuation.finish()
    }

    /// Returns when the synopsis has finished, or when the waiting task is cancelled.
    func wait() async {
        for await _ in stream { return }
    }
}

/// Owns the pop-up's timing and placement for a grid. The delay restarts for each
/// newly focused title; any focus change hides the card at once.
@MainActor
public final class SeeAllPopupPresenter {
    public init() {}
    private let host = UIHostingController(rootView: AnyView(EmptyView()))
    private var task: Task<Void, Never>?
    private var shown: IndexPath?

    public func attach(to parent: UIViewController) {
        guard host.parent == nil else { return }
        host.view.backgroundColor = .clear
        host.view.isUserInteractionEnabled = false
        host.view.isHidden = true
        host.safeAreaRegions = []
        parent.addChild(host)
        parent.view.addSubview(host.view)
        host.didMove(toParent: parent)
    }

    public var isShowing: Bool { shown != nil }

    public func hide() {
        task?.cancel()
        task = nil
        shown = nil
        host.view.layer.removeAllAnimations()
        host.view.alpha = 1
        host.view.isHidden = true
        host.rootView = AnyView(EmptyView())
    }

    /// Fades the card out, then hides it. A focus move meanwhile calls `hide()`,
    /// which cancels this and resets the card.
    private func fadeOutAndHide() async {
        UIView.animate(withDuration: SeeAllPopupTiming.fadeOut, delay: 0, options: .curveEaseInOut) {
            self.host.view.alpha = 0
        }
        do { try await Task.sleep(for: .seconds(SeeAllPopupTiming.fadeOut)) } catch { return }
        hide()
    }

    /// Hides the current card and, when `delay` is set, shows `path`'s after it.
    /// `isStillFocused` guards against a focus move during the delay or the load.
    public func schedule(
        path: IndexPath, delay: Duration?, hideAfter: Duration? = nil,
        bounds: @escaping () -> CGRect, anchor: @escaping () -> CGRect?,
        isRightToLeft: Bool, environment: EnvironmentValues,
        content: @escaping () async -> SeeAllPopupContent?, isStillFocused: @escaping () -> Bool
    ) {
        hide()
        guard let delay else { return }
        task = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self, isStillFocused(), let content = await content(),
                  !Task.isCancelled, isStillFocused(), let anchor = anchor() else { return }
            let reading = SeeAllPopupReading()
            let card = SeeAllPopupCard(content: content, onReadingFinished: { reading.finish() })
            self.host.rootView = AnyView(card.transformEnvironment(\.self) { target in
                target.colorScheme = environment.colorScheme
                target.locale = environment.locale
                target.layoutDirection = environment.layoutDirection
                target.dynamicTypeSize = environment.dynamicTypeSize
            })
            let size = self.host.sizeThatFits(in: CGSize(width: SeeAllPopupCard.width, height: .greatestFiniteMagnitude))
            self.host.view.frame = SeeAllPopupPlacement.frame(
                card: size, anchor: anchor, bounds: bounds(), isRightToLeft: isRightToLeft
            )
            self.shown = path
            self.host.view.alpha = 0
            self.host.view.isHidden = false
            UIView.animate(withDuration: SeeAllPopupTiming.fadeIn, delay: 0, options: .curveEaseInOut) {
                self.host.view.alpha = 1
            }
            guard let hideAfter else { return }
            // The timeout counts from the end of the synopsis, not from appearing.
            await reading.wait()
            guard !Task.isCancelled else { return }
            do { try await Task.sleep(for: hideAfter) } catch { return }
            await self.fadeOutAndHide()
        }
    }
}

/// The SwiftUI grid's pop-up state: same timing rules as `SeeAllPopupPresenter`.
@MainActor
@Observable
public final class SeeAllPopupModel {
    public init() {}
    public private(set) var content: SeeAllPopupContent?
    public var anchor: CGRect = .zero
    public var cardSize: CGSize = .zero
    @ObservationIgnored private var task: Task<Void, Never>?
    public private(set) var focusedKey: String?
    /// True while the card fades out after its time on screen.
    public private(set) var isFadingOut = false
    @ObservationIgnored private var reading = SeeAllPopupReading()

    public func hide() {
        task?.cancel()
        task = nil
        isFadingOut = false
        content = nil
        // The next card is measured afresh, so it fades in rather than appearing.
        cardSize = .zero
    }

    /// The card on screen has shown its whole synopsis.
    func readingFinished() { reading.finish() }

    /// Restarts the delay for `key`; any focus change hides the card at once.
    /// `nil` means focus left the grid (ignored if another title already took it).
    public func focusChanged(
        key: String, focused: Bool, delay: Duration?, hideAfter: Duration? = nil,
        detail: @escaping () async -> SeeAllPopupContent?
    ) {
        guard focused || focusedKey == key else { return }
        focusedKey = focused ? key : nil
        hide()
        guard focused, let delay else { return }
        task = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            let loaded = await detail()
            guard let loaded, !Task.isCancelled, self?.focusedKey == key else { return }
            guard let self else { return }
            let reading = SeeAllPopupReading()
            self.reading = reading
            self.content = loaded
            guard let hideAfter else { return }
            // The timeout counts from the end of the synopsis, not from appearing.
            await reading.wait()
            guard !Task.isCancelled else { return }
            do { try await Task.sleep(for: hideAfter) } catch { return }
            self.isFadingOut = true
            do { try await Task.sleep(for: .seconds(SeeAllPopupTiming.fadeOut)) } catch { return }
            self.hide()
        }
    }
}

public struct SeeAllPopupOverlay: View {
    let model: SeeAllPopupModel
    @Environment(\.layoutDirection) private var direction

    public init(model: SeeAllPopupModel) { self.model = model }

    public var body: some View {
        GeometryReader { proxy in
            if let content = model.content {
                let frame = SeeAllPopupPlacement.frame(
                    card: model.cardSize, anchor: model.anchor,
                    bounds: CGRect(origin: .zero, size: proxy.size).insetBy(dx: 0, dy: 40),
                    isRightToLeft: direction == .rightToLeft)
                let isVisible = model.cardSize != .zero && !model.isFadingOut
                SeeAllPopupCard(content: content, onReadingFinished: { model.readingFinished() })
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { model.cardSize = $0 }
                    .offset(x: frame.minX, y: frame.minY)
                    .opacity(isVisible ? 1 : 0)
                    .animation(
                        .easeInOut(duration: isVisible ? SeeAllPopupTiming.fadeIn : SeeAllPopupTiming.fadeOut),
                        value: isVisible)
            }
        }
        .allowsHitTesting(false)
    }
}
#endif
