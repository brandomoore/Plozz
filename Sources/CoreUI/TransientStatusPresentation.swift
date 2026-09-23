#if canImport(SwiftUI)
import Foundation
import Observation
import SwiftUI

public enum TransientStatusPlacement: Hashable, Sendable {
    case root
    case musicTransport
}

public struct TransientStatusMessage: Equatable, Sendable {
    public let icon: String
    public let text: LocalizedStringResource
    public let placement: TransientStatusPlacement
    public let isProgress: Bool

    public init(
        icon: String,
        text: LocalizedStringResource,
        placement: TransientStatusPlacement = .root,
        isProgress: Bool = false
    ) {
        self.icon = icon
        self.text = text
        self.placement = placement
        self.isProgress = isProgress
    }
}

@MainActor
@Observable
public final class TransientStatusPresenter {
    public typealias Sleeper = @Sendable (Duration) async -> Void
    public typealias Announcement =
        @MainActor @Sendable (LocalizedStringResource) -> Void

    public static let defaultDisplayDuration: Duration = .milliseconds(1_600)
    public static let presentationAnimationDuration: TimeInterval = 0.2
    public static let dismissalAnimationDuration: TimeInterval = 0.3

    public private(set) var message: TransientStatusMessage?

    @ObservationIgnored private let displayDuration: Duration
    @ObservationIgnored private let sleeper: Sleeper
    @ObservationIgnored private let announcement: Announcement
    @ObservationIgnored private var dismissalTask: Task<Void, Never>?
    @ObservationIgnored private var generation: UInt64 = 0

    public init(
        displayDuration: Duration = defaultDisplayDuration,
        sleeper: @escaping Sleeper = { duration in
            try? await Task.sleep(for: duration)
        },
        announcement: @escaping Announcement = { text in
            #if os(tvOS) || os(iOS)
            // An announcement is spoken at this instant and then gone, so it
            // must be resolved now: there is no later render to re-resolve for,
            // which is what the eager rule normally protects, and
            // `Announcement` accepts no lazy form.
            AccessibilityNotification.Announcement(
                String(localized: text)  // l10n:content — resolved to be spoken now
            ).post()
            #endif
        }
    ) {
        self.displayDuration = displayDuration
        self.sleeper = sleeper
        self.announcement = announcement
    }

    deinit {
        dismissalTask?.cancel()
    }

    @discardableResult
    public func present(
        icon: String,
        text: LocalizedStringResource,
        placement: TransientStatusPlacement = .root,
        isProgress: Bool = false
    ) -> UInt64 {
        generation &+= 1
        let expectedGeneration = generation
        dismissalTask?.cancel()
        withAnimation(.easeInOut(
            duration: Self.presentationAnimationDuration
        )) {
            message = TransientStatusMessage(
                icon: icon,
                text: text,
                placement: placement,
                isProgress: isProgress
            )
        }
        announcement(text)
        dismissalTask = nil
        guard !isProgress else { return expectedGeneration }

        let displayDuration = self.displayDuration
        let sleeper = self.sleeper
        dismissalTask = Task { [weak self] in
            await sleeper(displayDuration)
            guard !Task.isCancelled else { return }
            await self?.dismiss(expectedGeneration: expectedGeneration)
        }
        return expectedGeneration
    }

    public func dismiss() {
        generation &+= 1
        dismissalTask?.cancel()
        dismissalTask = nil
        withAnimation(.easeInOut(
            duration: Self.dismissalAnimationDuration
        )) {
            message = nil
        }
    }

    public func dismiss(expectedGeneration: UInt64) {
        guard expectedGeneration == generation else { return }
        dismissalTask?.cancel()
        dismissalTask = nil
        withAnimation(.easeInOut(
            duration: Self.dismissalAnimationDuration
        )) {
            message = nil
        }
    }
}

public struct TransientStatusView: View {
    private let presenter: TransientStatusPresenter
    private let placement: TransientStatusPlacement
    private let palette: ThemePalette

    public init(
        presenter: TransientStatusPresenter,
        placement: TransientStatusPlacement = .root,
        palette: ThemePalette = .dark
    ) {
        self.presenter = presenter
        self.placement = placement
        self.palette = palette
    }

    public var body: some View {
        Group {
            if let message = presenter.message,
               message.placement == placement {
                HStack(spacing: 10) {
                    Group {
                        if message.isProgress {
                            ProgressView()
                                .controlSize(.small)
                                #if os(tvOS)
                                .scaleEffect(0.5)
                                #endif
                        } else {
                            Image(systemName: message.icon)
                        }
                    }
                    .frame(width: 22, height: 22)
                    Text(message.text)
                }
                .font(messageFont)
                .foregroundStyle(palette.primaryText)
                .tint(palette.primaryText)
                .padding(.horizontal, 22)
                .padding(.vertical, 13)
                .background(palette.overlay.fill, in: Capsule())
                .overlay {
                    if let border = palette.overlay.border {
                        Capsule().strokeBorder(border, lineWidth: palette.overlay.borderWidth)
                    }
                }
                .modifier(OptionalSurfaceShadow(shadow: palette.overlay.shadow))
                .transition(.opacity)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var messageFont: Font {
        #if os(iOS)
        placement == .root
            ? .headline.weight(.semibold)
            : .system(size: 22, weight: .semibold)
        #else
        .system(size: 22, weight: .semibold)
        #endif
    }
}

private struct TransientStatusPresenterKey: EnvironmentKey {
    static let defaultValue: TransientStatusPresenter? = nil
}

public extension EnvironmentValues {
    var transientStatusPresenter: TransientStatusPresenter? {
        get { self[TransientStatusPresenterKey.self] }
        set { self[TransientStatusPresenterKey.self] = newValue }
    }
}

public extension View {
    func transientStatusPresenter(
        _ presenter: TransientStatusPresenter?
    ) -> some View {
        environment(\.transientStatusPresenter, presenter)
    }

    /// Overlay-only host: no layout participation, focus target, or hit testing.
    func transientStatusOverlay(
        presenter: TransientStatusPresenter,
        placement: TransientStatusPlacement = .root,
        alignment: Alignment = .bottom,
        bottomPadding: CGFloat = 48,
        palette: ThemePalette = .dark
    ) -> some View {
        overlay(alignment: alignment) {
            TransientStatusView(
                presenter: presenter,
                placement: placement,
                palette: palette
            )
            .padding(.bottom, bottomPadding)
        }
        .transientStatusPresenter(presenter)
    }
}
#endif
