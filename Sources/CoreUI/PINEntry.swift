import CoreModels
import Observation
import SwiftUI

/// Platform metrics for the PIN screen. A 10-foot remote-driven UI and a phone
/// held at arm's length need genuinely different sizes, and these live at file
/// scope because the views that use them are generic (which can't hold static
/// stored properties).
/// The size the identity badge must be built at.
///
/// Public because the scaffold can't fix a mis-sized badge for you: a view that
/// draws at its own intrinsic size (`ProfileAvatarView`) is clipped, not scaled,
/// by an outer `.frame` — which is exactly how the avatar ended up squashed.
public enum PINLayout {
    public static var badgeSize: CGFloat { PINMetrics.badgeSize }
}

enum PINMetrics {
    #if os(tvOS)
    static let horizontalPadding: CGFloat = 110
    static let badgeSize: CGFloat = 72
    static let keyDiameter: CGFloat = 108
    static let keySpacing: CGFloat = 22
    static let dotSize: CGFloat = 30
    #else
    static let horizontalPadding: CGFloat = 24
    static let badgeSize: CGFloat = 48
    static let keyDiameter: CGFloat = 74
    static let keySpacing: CGFloat = 16
    static let dotSize: CGFloat = 24
    #endif

    #if os(tvOS)
    static let titleFont: Font = .system(size: 64, weight: .bold)
    static let subtitleFont: Font = .title3
    static let nameFont: Font = .title3.weight(.semibold)
    static let proseMaxWidth: CGFloat = 720
    #else
    static let titleFont: Font = .title2.weight(.bold)
    static let subtitleFont: Font = .body
    static let nameFont: Font = .headline
    static let proseMaxWidth: CGFloat = .infinity
    #endif

    /// Width of the delete key: it spans the two trailing columns of the bottom
    /// row, so it lines up with the grid rather than floating.
    static var deleteKeyWidth: CGFloat { keyDiameter * 2 + keySpacing }

    /// Intrinsic width of the 3-column dial pad.
    static var padWidth: CGFloat { keyDiameter * 3 + keySpacing * 2 }

    #if os(tvOS)
    /// Fixed width for the prose column, rather than letting it absorb every
    /// spare point. See the layout note in ``PINEntryScaffold``.
    static let proseColumnWidth: CGFloat = 720
    /// The real, honest gap between prose and pad.
    static let columnGap: CGFloat = 120
    /// Prose + gap + pad, centered on screen as one unit.
    static var compositionWidth: CGFloat { proseColumnWidth + columnGap + padWidth }
    #endif
}

/// Position inside a chained PIN gate. Omitted for ordinary one-PIN flows.
public struct PINSequenceStep: Equatable, Sendable {
    public let current: Int
    public let total: Int

    public init(current: Int, total: Int) {
        self.current = current
        self.total = total
    }
}

public enum PINEntryAvailability: Equatable, Sendable {
    case checking
    case available
    case unavailable
}

/// The shared 4-digit PIN screen.
///
/// Everything that asks for four digits uses this — unlocking a profile,
/// unlocking a Plex Home user, and creating or confirming a new PIN — so they're
/// visually indistinguishable. That matters most for the "same PIN as Plex"
/// option: if the two systems looked different, the fact that one PIN satisfies
/// both would stop being obvious.
///
/// The layout is a **3×4 dial pad**, not the single row this used to be. On a
/// remote the row meant every digit was up to ten presses away along one axis and
/// 0 sat past 9; a phone-shaped pad puts any digit within two presses across two
/// axes, which is the whole reason phones and TV apps settled on it.
///
/// Owns the entry state (typed digits) but not the *verdict* — the caller decides
/// whether a PIN was right and feeds an error back down, because only it knows
/// whether that means a network round-trip (Plex) or a local hash comparison
/// (`ProfileLock`).
public struct PINEntryScaffold<Badge: View>: View {
    /// Large heading — what this entry is for ("Enter your PIN", "Create a
    /// Profile Lock"). Carries the whole meaning of the screen, so it's the one
    /// thing a caller must supply.
    public let title: LocalizedStringResource
    /// Supporting line under the title.
    public var subtitle: LocalizedStringResource?
    /// Name shown beside the badge.
    ///
    /// A `Text` rather than a `String` so a caller can pass either provider
    /// CONTENT (`Text(verbatim: profile.name)`) or app COPY
    /// (`Text(KidsProfileCopy.parentalPIN)`). When this took a `String`, the
    /// copy case had to call `String(localized:)`, which resolves at call time
    /// and freezes the value against a language change.
    public let name: Text
    public let showsLock: Bool
    /// Error from the last attempt, or `nil`. The slot is reserved either way so
    /// the pad doesn't jump when one appears.
    ///
    /// Carried as a resource, not a resolved `String`: every caller was reaching
    /// for `String(localized:)` to build one, which resolves eagerly.
    public let errorMessage: LocalizedStringResource?
    /// Whether an attempt is in flight (shows a spinner, blocks the pad).
    public let isSubmitting: Bool
    public let availability: PINEntryAvailability
    public let onRetry: () -> Void
    /// Optional caveat under the identity block, e.g. the sync warning.
    public var footnote: LocalizedStringResource?
    /// Whether this scaffold is rendered INLINE in a constrained container
    /// (a settings card, the profile actions dialog) rather than filling the
    /// screen.
    ///
    /// Declared by the host instead of measured. Measuring it with
    /// `ViewThatFits` deadlocked the layout: the two-column composition is
    /// 1208pt and the settings content column is 1200pt, so the candidates sat
    /// exactly on the fit boundary and SwiftUI re-evaluated the enclosing view
    /// ~180 times a second, which presents as a completely frozen screen. The
    /// host always knows which case it is; the layout engine had to keep asking.
    public var isCompact: Bool = false
    /// Whether to draw the badge + name.
    ///
    /// False when the HOST already says whose PIN this is. The profile actions
    /// dialog puts the avatar and name in its own header, so the scaffold's copy
    /// made the name appear twice on one small card.
    public var showsIdentity: Bool = true
    /// Position inside a chained PIN gate. Nil for ordinary one-PIN flows.
    public var sequenceStep: PINSequenceStep?
    /// Called with the full PIN as soon as the last digit lands.
    public let onSubmit: (String) -> Void
    public let onCancel: () -> Void
    @ViewBuilder public let badge: () -> Badge

    @Environment(\.themePalette) private var palette
    @Environment(\.pinProfileTransition) private var profileTransition
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var entry = PINEntryState()

    public init(
        title: LocalizedStringResource,
        subtitle: LocalizedStringResource? = nil,
        name: Text,
        showsLock: Bool = false,
        errorMessage: LocalizedStringResource? = nil,
        isSubmitting: Bool = false,
        availability: PINEntryAvailability = .available,
        onRetry: @escaping () -> Void = {},
        footnote: LocalizedStringResource? = nil,
        sequenceStep: PINSequenceStep? = nil,
        isCompact: Bool = false,
        showsIdentity: Bool = true,
        onSubmit: @escaping (String) -> Void,
        onCancel: @escaping () -> Void,
        @ViewBuilder badge: @escaping () -> Badge
    ) {
        self.title = title
        self.subtitle = subtitle
        self.name = name
        self.showsLock = showsLock
        self.errorMessage = errorMessage
        self.isSubmitting = isSubmitting
        self.availability = availability
        self.onRetry = onRetry
        self.footnote = footnote
        self.sequenceStep = sequenceStep
        self.isCompact = isCompact
        self.showsIdentity = showsIdentity
        self.onSubmit = onSubmit
        self.onCancel = onCancel
        self.badge = badge
    }

    public var body: some View {
        ZStack {
            // Opaque, not a translucent scrim. The keys are liquid glass and
            // glass has to sample a real backdrop — floating them over
            // `.ultraThinMaterial` was glass on glass, which reads muddy and
            // costs a second blur pass for nothing.
            AppBackground(palette: palette)
                .ignoresSafeArea()
                .opacity(profileTransition == nil ? 1 : 0)

            if let profileTransition {
                PINProfileEntryLayout(
                    transition: profileTransition, title: title, name: name, showsLock: showsLock,
                    availability: availability, errorMessage: errorMessage,
                    footnote: footnote, sequenceStep: sequenceStep,
                    onRetry: onRetry, onCancel: cancelEntry,
                    badge: badge, pad: { padColumn }
                )
            } else if availability != .available {
                PINRequirementCheckView(
                    name: name, availability: availability, errorMessage: errorMessage,
                    onRetry: onRetry, onCancel: cancelEntry
                )
            } else {
                #if os(tvOS)
                // Prose on the left, pad on the right, and the PAIR centered on
                // screen as one composition. The prose column is sized explicitly
                // rather than absorbing the slack: when it was greedy the pad landed
                // near 75% of the screen and had to be dragged back with a hand-tuned
                // `.offset`, which moved pixels without moving layout.
                //
                // Which arrangement to use is a fact the HOST supplies, not something
                // to measure. `ViewThatFits` here froze the app outright: the wide
                // composition is 1208pt and the settings content column is 1200pt, so
                // the candidates sat on the fit boundary and the enclosing view
                // re-evaluated ~180 times a second. Before that a `GeometryReader`
                // collapsed the pad to nothing inside a content-sized card. A flag
                // is duller than both and cannot oscillate.
                if isCompact {
                    VStack(spacing: 28) {
                        prose(centered: true)
                        padColumn
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 28)
                } else {
                    HStack(alignment: .center, spacing: PINMetrics.columnGap) {
                        prose(centered: false)
                            .frame(width: PINMetrics.proseColumnWidth, alignment: .leading)
                        padColumn
                    }
                    .frame(maxWidth: PINMetrics.compositionWidth, maxHeight: .infinity)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, PINMetrics.horizontalPadding)
                }
                #else
                GeometryReader { proxy in
                    if usesTwoColumnLayout(proxy.size) {
                        HStack(alignment: .center, spacing: 56) {
                            prose(centered: false)
                                .frame(width: 360, alignment: .leading)
                            VStack(spacing: 24) {
                                padColumn
                                Button("Cancel", action: cancelEntry)
                                    .plozzActionButton(role: .secondary)
                            }
                        }
                        // Centre the COMPOSITION, not each column independently.
                        .frame(maxWidth: 780, maxHeight: .infinity)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.horizontal, 40)
                    } else {
                        VStack(spacing: 32) {
                            Spacer(minLength: 0)
                            prose(centered: true)
                                .frame(maxWidth: .infinity, alignment: .center)
                            padColumn
                            Spacer(minLength: 0)
                            Button("Cancel", action: cancelEntry)
                                .plozzActionButton(role: .secondary)
                                .padding(.bottom, 24)
                        }
                        .padding(.horizontal, PINMetrics.horizontalPadding)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                #endif
            }
        }
        #if os(tvOS)
        // Menu on the Siri remote backs out. iOS has no equivalent command, so
        // the Cancel button is the way out there.
        .onExitCommand(perform: cancelEntry)
        #endif
        .onDisappear(perform: entry.reset)
        .onChange(of: availability) { _, newValue in
            if newValue != .available { entry.reset() }
        }
        .onChange(of: errorMessage) { _, newValue in
            if newValue != nil { entry.reset() }
        }
    }

    // MARK: Prose column

    private func prose(centered: Bool) -> some View {
        VStack(alignment: centered ? .center : .leading, spacing: 20) {
            if let sequenceStep, sequenceStep.total > 1 {
                PINSequenceIndicator(step: sequenceStep)
                    .padding(.bottom, 4)
            }

            Text(title)
                .accessibilityIdentifier("pin-entry-title")
                .font(PINMetrics.titleFont)
                .foregroundStyle(palette.primaryText)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(centered ? .center : .leading)

            if let subtitle {
                Text(subtitle)
                    .font(PINMetrics.subtitleFont)
                    .foregroundStyle(palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(centered ? .center : .leading)
            }

            // Whose PIN this is. Small and secondary — the person already knows
            // who they picked; this is confirmation, not the headline. Skipped
            // entirely when the host has already said it.
            if showsIdentity {
                HStack(spacing: 14) {
                    badge()
                        .clipShape(Circle())
                    PINIdentityName(name: name, showsLock: showsLock)
                        .font(PINMetrics.nameFont)
                        .foregroundStyle(palette.primaryText)
                        .lineLimit(1)
                }
                .padding(.top, 4)
            }

            // Reserved either way so nothing shifts between attempts.
            // Reserved either way so nothing shifts between attempts.
            (errorMessage.map(Text.init) ?? Text(verbatim: " "))
                .font(.callout)
                .foregroundStyle(errorMessage == nil ? Color.clear : .red)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(centered ? .center : .leading)

            if let footnote {
                Label {
                    Text(footnote)
                        .font(.footnote)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
                .foregroundStyle(palette.secondaryText)
            }
        }

        .frame(
            maxWidth: PINMetrics.proseMaxWidth,
            alignment: centered ? .center : .leading
        )
    }

    /// Geometry, not device model: adapts correctly to iPad split view, external
    /// displays and iPhone landscape.
    private func usesTwoColumnLayout(_ size: CGSize) -> Bool {
        size.width >= 760 && size.height >= 620
    }

    // MARK: Pad column

    private var animatesKeyEntrance: Bool {
        #if os(tvOS)
        // Native focus must never land on a key that has not appeared yet.
        false
        #else
        profileTransition != nil
        #endif
    }

    @ViewBuilder
    private var padColumn: some View {
        VStack(spacing: 28) {
            HStack(spacing: 18) {
                PINProgressDots(filledCount: isSubmitting
                    ? max(entry.pin.count, entry.submittedDigitCount) : entry.pin.count)
                if isSubmitting {
                    ProgressView().controlSize(.large)
                }
            }
            .modifier(PINKeyEntrance(enabled: animatesKeyEntrance, position: 0, reduceMotion: reduceMotion))
            PINDialPad(
                animatesEntrance: animatesKeyEntrance,
                onDigit: appendDigit, onDelete: deleteDigit
            )
                .disabled(isSubmitting || entry.isCommitting)
                .opacity(isSubmitting ? 0.5 : 1.0)
        }
        #if os(tvOS)
        // Keep the pad a single focus region so Left from any key returns to the
        // prose side rather than hunting between rows.
        .focusSection()
        #endif
    }

    // MARK: Entry

    private func appendDigit(_ d: String) {
        guard !isSubmitting else { return }
        entry.appendDigit(d, onSubmit: onSubmit)
    }

    private func cancelEntry() {
        entry.reset()
        onCancel()
    }

    private func deleteDigit() {
        guard !isSubmitting else { return }
        entry.deleteDigit()
    }
}

struct PINIdentityName: View {
    let name: Text
    let showsLock: Bool

    var body: some View {
        (showsLock
            ? name + Text(verbatim: " ") + Text(Image(systemName: "lock.fill")).font(.caption2)
            : name)
            .accessibilityLabel(name)
            .accessibilityValue(showsLock ? Text(ProfileLockCopy.title) : Text(verbatim: ""))
    }
}

@MainActor @Observable
final class PINEntryState {
    private(set) var pin = ""
    private(set) var submittedDigitCount = 0
    private(set) var isCommitting = false
    @ObservationIgnored private var commitTask: Task<Void, Never>?

    func appendDigit(_ d: String, onSubmit: @escaping @MainActor (String) -> Void) {
        guard !isCommitting else { return }
        guard d.count == 1, d.first?.isNumber == true else { return }
        guard pin.count < ProfileLock.pinLength else { return }
        pin.append(d)
        if pin.count == ProfileLock.pinLength {
            let entered = pin
            // Show the fourth dot before synchronous verification can remove the view.
            isCommitting = true
            commitTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(140))
                guard !Task.isCancelled, let self else { return }
                // Reset before submitting so repeated identical errors also allow retry.
                self.submittedDigitCount = self.pin.count
                self.pin = ""
                self.isCommitting = false
                self.commitTask = nil
                onSubmit(entered)
            }
        }
    }

    func reset() {
        commitTask?.cancel()
        commitTask = nil
        pin = ""
        submittedDigitCount = 0
        isCommitting = false
    }

    func deleteDigit() {
        guard !isCommitting else { return }
        if !pin.isEmpty { pin.removeLast() }
    }
}

private struct PINRequirementCheckView: View {
    let name: Text
    let availability: PINEntryAvailability
    let errorMessage: LocalizedStringResource?
    let onRetry: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            name
                .font(PINMetrics.nameFont)
                .plozzForeground(.primary)
            ContentStateView<Bool, EmptyView>(
                state: availability == .checking ? .loading : .failed(.serverUnreachable),
                errorMessage: errorMessage,
                onRetry: onRetry,
                loadingContent: {
                    ProgressView()
                        .accessibilityLabel("Loading")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                },
                content: { _ in EmptyView() }
            )
            Button("Cancel", action: onCancel)
                .plozzActionButton(role: .secondary)
        }
        .padding(PINMetrics.horizontalPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("pin-requirement-check")
    }
}

/// Quiet progress for a chained profile-PIN then Plex-PIN gate.
///
/// The rail says "this is one continuous two-step action" before the first PIN
/// is entered, while the text removes any ambiguity about why another PIN screen
/// follows. Single-PIN flows pass no step and render nothing.
struct PINSequenceIndicator: View {
    let step: PINSequenceStep

    @Environment(\.themePalette) private var palette

    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 7) {
                ForEach(1 ... step.total, id: \.self) { index in
                    Capsule()
                        .fill(
                            index <= step.current
                                ? ThemePalette.brandBlue
                                : palette.secondaryText.opacity(0.28)
                        )
                        .frame(width: 42, height: 6)
                }
            }
            Text("PIN \(step.current) of \(step.total)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(palette.secondaryText)
                .textCase(.uppercase)
                .tracking(0.8)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("PIN \(step.current) of \(step.total)")
    }
}

/// The four progress dots above the pad.
///
/// Outlines that fill in, rather than the boxes-with-dots this used to draw: at a
/// distance a filled circle reads as progress instantly, and it keeps the pad and
/// its indicator in one visual language.
public struct PINProgressDots: View {
    public let filledCount: Int

    @Environment(\.themePalette) private var palette

    public init(filledCount: Int) { self.filledCount = filledCount }

    public var body: some View {
        HStack(spacing: 18) {
            ForEach(0 ..< ProfileLock.pinLength, id: \.self) { idx in
                let filled = idx < filledCount
                Circle()
                    .strokeBorder(palette.secondaryText.opacity(0.75), lineWidth: 2)
                    .background(Circle().fill(filled ? palette.primaryText : .clear))
                    .frame(width: PINMetrics.dotSize, height: PINMetrics.dotSize)
                    // The dot is the payoff for a key press, so it pops rather
                    // than cross-fades — the two together are what make the pad
                    // feel connected to what you typed.
                    .scaleEffect(filled ? 1.0 : 0.9)
                    .animation(.spring(response: 0.26, dampingFraction: 0.55), value: filled)
            }
        }
        // Phrased as a position rather than "N digits entered": the latter
        // quantifies a noun, which needs real plural variations in every language
        // (Polish has four forms, Arabic six). "2 of 4" needs none and reads the
        // same to VoiceOver.
        .accessibilityLabel("PIN progress: \(filledCount) of \(ProfileLock.pinLength)")
    }
}

/// The 3×4 dial pad: 1–9, then 0 and a wide delete key on the bottom row.
///
/// Each key is a focusable Button so focus is always anchored and Menu/Back can't
/// fall through to the system. Round keys, because the shape is what makes a
/// 10-foot target readable at a glance — and because delete can then be a capsule
/// that visibly spans two columns without looking like a mistake.
public struct PINDialPad: View {
    public let animatesEntrance: Bool
    public let onDigit: (String) -> Void
    public let onDelete: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        animatesEntrance: Bool = false,
        onDigit: @escaping (String) -> Void, onDelete: @escaping () -> Void
    ) {
        self.animatesEntrance = animatesEntrance
        self.onDigit = onDigit
        self.onDelete = onDelete
    }

    private static let rows = [["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"]]

    private var digitFont: Font {
        .system(size: PINMetrics.keyDiameter * 0.34, weight: .semibold, design: .rounded)
    }

    public var body: some View {
        VStack(spacing: PINMetrics.keySpacing) {
            ForEach(Array(Self.rows.enumerated()), id: \.offset) { rowIndex, row in
                HStack(spacing: PINMetrics.keySpacing) {
                    ForEach(Array(row.enumerated()), id: \.element) { columnIndex, digit in
                        Button { onDigit(digit) } label: {
                            Text(verbatim: digit).font(digitFont)
                        }
                        .buttonStyle(PINKeyStyle(width: PINMetrics.keyDiameter))
                        #if os(tvOS)
                        .settingsPageEntryFocus(enabled: digit == "1")
                        #endif
                        .modifier(PINKeyEntrance(
                            enabled: animatesEntrance, position: rowIndex * 3 + columnIndex,
                            reduceMotion: reduceMotion
                        ))
                    }
                }
            }
            HStack(spacing: PINMetrics.keySpacing) {
                Button { onDigit("0") } label: {
                    Text(verbatim: "0").font(digitFont)
                }
                .buttonStyle(PINKeyStyle(width: PINMetrics.keyDiameter))
                .modifier(PINKeyEntrance(enabled: animatesEntrance, position: 9, reduceMotion: reduceMotion))

                Button(action: onDelete) {
                    Image(systemName: "delete.backward")
                        .font(.system(size: PINMetrics.keyDiameter * 0.28, weight: .semibold))
                }
                .buttonStyle(PINKeyStyle(width: PINMetrics.deleteKeyWidth))
                .accessibilityLabel("Delete")
                .modifier(PINKeyEntrance(enabled: animatesEntrance, position: 10, reduceMotion: reduceMotion))
            }
        }
    }
}

/// Native Liquid Glass for every PIN keypad, with the existing opaque/legacy fallback.
public struct PINKeyStyle: PrimitiveButtonStyle {
    public let width: CGFloat
    @Environment(\.plozzReduceTransparency) private var reduceTransparency

    public init(width: CGFloat) { self.width = width }

    public func makeBody(configuration: Configuration) -> some View {
        if #available(iOS 26.0, tvOS 26.0, *), !reduceTransparency {
            PINNativeKeyBody(configuration: configuration, width: width)
        } else {
            Button(role: configuration.role, action: configuration.trigger) {
                configuration.label
            }
            .buttonStyle(PINFallbackKeyStyle(width: width))
        }
    }
}

@available(iOS 26.0, tvOS 26.0, *)
private struct PINNativeKeyBody: View {
    let configuration: PrimitiveButtonStyleConfiguration
    let width: CGFloat
    @State private var activationCount = 0

    var body: some View {
        Button(role: configuration.role) {
            activationCount += 1
            configuration.trigger()
        } label: {
            configuration.label
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(width == PINMetrics.keyDiameter ? .circle : .capsule)
        .buttonSizing(.flexible)
        .frame(width: width, height: PINMetrics.keyDiameter)
        #if os(iOS)
        .sensoryFeedback(.impact(flexibility: .soft, intensity: 0.7), trigger: activationCount)
        #endif
    }
}

private struct PINFallbackKeyStyle: ButtonStyle {
    let width: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        PINKeyBody(configuration: configuration, width: width)
    }
}

private struct PINKeyBody: View {
    let configuration: ButtonStyle.Configuration
    let width: CGFloat

    @Environment(\.isFocused) private var isFocused
    @Environment(\.themePalette) private var palette
    @Environment(\.gradientBackgroundsEnabled) private var gradientEnabled

    /// A press is latched rather than read straight from
    /// `configuration.isPressed`.
    ///
    /// A tap — remote click or finger — can lift in well under 100ms, so the raw
    /// flag is often true for a single frame. The pad registered those presses
    /// correctly but drew a state nobody could perceive, which is exactly what
    /// makes a working control feel dead. Latching guarantees a minimum on-screen
    /// dwell, so every digit is *seen* to land.
    @State private var showsPress = false
    /// Pointer hover (iPad trackpad/mouse). tvOS does the same job with focus.
    @State private var isHovering = false
    /// Bumped once per press. Drives haptics, and tags the release so a stale
    /// unlatch from a previous press can't cancel the current one during fast
    /// typing.
    @State private var pressCount = 0

    /// Focus and hover are the same idea on their respective platforms: "this is
    /// the key you're about to hit."
    private var isHighlighted: Bool { isFocused || isHovering }

    private var highlightScale: CGFloat {
        if isFocused { return 1.06 }
        if isHovering { return 1.04 }
        return 1.0
    }

    /// Highlight and press compose rather than override, so a focused key still
    /// visibly depresses instead of snapping back to its resting size.
    private var scale: CGFloat { highlightScale * (showsPress ? 0.94 : 1.0) }

    /// The wash flips polarity with the surface beneath it. A highlighted key is
    /// already bright, so it darkens; a resting key is dark, so it lights up.
    /// Either way the press reads as the key being pushed in.
    private var pressWash: Color { isHighlighted ? .black : palette.primaryText }

    var body: some View {
        configuration.label
            .foregroundStyle(palette.primaryText)
            .frame(width: width, height: PINMetrics.keyDiameter)
            // The app's own liquid-glass card surface, cornered to a capsule.
            // Using it rather than a hand-rolled fill means the keys pick up the
            // same focus bloom, the same Reduce Transparency fallback, and the
            // same tvOS-26 treatment as every card in the app — and can't drift
            // from them.
            .plozzGlassCard(
                cornerRadius: PINMetrics.keyDiameter / 2,
                isFocused: isHighlighted
            )
            .environment(\.plozzGradientCardSurface, gradientEnabled)
            .overlay {
                // A capsule matches the key at both widths: the delete key is
                // wider, but the corner radius is driven by the shared height.
                Capsule()
                    .fill(pressWash)
                    .opacity(showsPress ? 0.18 : 0)
                    .allowsHitTesting(false)
            }
            .shadow(color: .black.opacity(isHighlighted ? 0.36 : 0), radius: 20, y: 10)
            .scaleEffect(scale)
            // One animation per driver, so a press curve can be snappy without
            // dragging the slower focus bloom along with it.
            .animation(.easeOut(duration: 0.18), value: isFocused)
            .animation(.easeOut(duration: 0.14), value: isHovering)
            .animation(.spring(response: 0.24, dampingFraction: 0.62), value: showsPress)
            .onChange(of: configuration.isPressed) { _, pressed in
                if pressed {
                    pressCount += 1
                    showsPress = true
                } else {
                    releasePress()
                }
            }
            #if !os(tvOS)
            .onHover { hovering in isHovering = hovering }
            #endif
            #if os(iOS)
            // A glass key has no travel and no click, so touch is the only
            // channel left to confirm a digit actually landed.
            .sensoryFeedback(
                .impact(flexibility: .soft, intensity: 0.7),
                trigger: pressCount
            )
            #endif
    }

    private func releasePress() {
        let token = pressCount
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(90))
            // A newer press has taken over; leave the key depressed for it.
            guard pressCount == token else { return }
            showsPress = false
        }
    }
}

/// Circular badge slot for the identity beside the title. Kept as its own type so
/// the Plex prompt — which has no avatar view of its own to lean on — can drop an
/// `AsyncImage` or a glyph in and get the same shape as a profile avatar.
public struct PINBadge<Content: View>: View {
    @Environment(\.themePalette) private var palette
    @ViewBuilder public let image: () -> Content

    public init(@ViewBuilder image: @escaping () -> Content) {
        self.image = image
    }

    public var body: some View {
        ZStack {
            Circle().fill(palette.fillSubtle)
            image()
        }
        // Own the proposal. A resizable AsyncImage otherwise accepts the whole
        // prose column and turns a 48pt identity badge into a screen-sized circle.
        .frame(width: PINLayout.badgeSize, height: PINLayout.badgeSize)
        .clipShape(Circle())
    }
}
