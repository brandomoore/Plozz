import CoreModels
import SwiftUI

/// Presentation-only identity shared by a profile tile and its authorization screen.
public struct PINProfileTransition: Equatable {
    public let profileID: String
    public let namespace: Namespace.ID
    public let avatarSize: CGFloat
    public let nameFont: Font
    public let isSource: Bool

    public init(
        profileID: String, namespace: Namespace.ID, avatarSize: CGFloat = 88,
        nameFont: Font = .title2.weight(.bold), isSource: Bool = true
    ) {
        self.profileID = profileID
        self.namespace = namespace
        self.avatarSize = avatarSize
        self.nameFont = nameFont
        self.isSource = isSource
    }

    public var avatarID: String { "\(profileID).avatar" }
    public var nameID: String { "\(profileID).name" }
}

extension EnvironmentValues {
    @Entry public var pinProfileTransition: PINProfileTransition? = nil
}

struct PINProfileEntryLayout<Badge: View, Pad: View>: View {
    let transition: PINProfileTransition
    let title: LocalizedStringResource
    let name: Text
    let showsLock: Bool
    let availability: PINEntryAvailability
    let errorMessage: LocalizedStringResource?
    let footnote: LocalizedStringResource?
    let sequenceStep: PINSequenceStep?
    let onRetry: () -> Void
    let onCancel: () -> Void
    @ViewBuilder let badge: () -> Badge
    @ViewBuilder let pad: () -> Pad
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        #if os(tvOS)
        HStack(spacing: PINMetrics.columnGap) {
            PINProfileIdentity(
                transition: transition, title: title, name: name, showsLock: showsLock,
                availability: availability, errorMessage: errorMessage,
                footnote: footnote, sequenceStep: sequenceStep, badge: badge
            )
            .frame(width: PINMetrics.proseColumnWidth)
            ZStack {
                if transition.isSource {
                    Group {
                        if availability == .available {
                            pad()
                        } else {
                            PINProfileRequirementState(
                                availability: availability, errorMessage: errorMessage, onRetry: onRetry
                            )
                        }
                    }
                    .transition(.identity)
                }
            }
            .frame(width: PINMetrics.padWidth)
        }
        .frame(maxWidth: PINMetrics.compositionWidth, maxHeight: .infinity)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, PINMetrics.horizontalPadding)
        #else
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 24) {
                    let layout = geometry.size.width > geometry.size.height
                        ? AnyLayout(HStackLayout(alignment: .center, spacing: 40))
                        : AnyLayout(VStackLayout(spacing: 24))
                    layout {
                        PINProfileIdentity(
                            transition: transition, title: title, name: name, showsLock: showsLock,
                            availability: availability, errorMessage: errorMessage,
                            footnote: footnote, sequenceStep: sequenceStep, badge: badge
                        )
                        .frame(maxWidth: 320)

                        ZStack {
                            if availability == .available {
                                pad()
                            } else {
                                PINProfileRequirementState(
                                    availability: availability, errorMessage: errorMessage,
                                    onRetry: onRetry
                                )
                            }
                        }
                        .frame(width: PINMetrics.padWidth)
                        .frame(minHeight: PINMetrics.dotSize + 28
                            + PINMetrics.keyDiameter * 4 + PINMetrics.keySpacing * 3)
                    }
                    Button("Cancel", action: onCancel)
                        .plozzActionButton(role: .secondary)
                        .modifier(PINKeyEntrance(enabled: true, position: 0, reduceMotion: reduceMotion))
                }
                .frame(maxWidth: .infinity)
                .frame(minHeight: max(0, geometry.size.height - 48))
                .padding(24)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        #endif
    }
}

private struct PINProfileIdentity<Badge: View>: View {
    let transition: PINProfileTransition
    let title: LocalizedStringResource
    let name: Text
    let showsLock: Bool
    let availability: PINEntryAvailability
    let errorMessage: LocalizedStringResource?
    let footnote: LocalizedStringResource?
    let sequenceStep: PINSequenceStep?
    @ViewBuilder let badge: () -> Badge
    @Environment(\.themePalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 10) {
            if let sequenceStep, sequenceStep.total > 1 {
                PINSequenceIndicator(step: sequenceStep)
                    .opacity(transition.isSource ? 1 : 0)
            }
            badge()
                .matchedGeometryEffect(
                    id: transition.avatarID, in: transition.namespace, isSource: transition.isSource
                )
                .accessibilityHidden(true)
            identityName
                .font(transition.nameFont)
                .foregroundStyle(palette.primaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                // Interpolating text bounds would rewrap the larger heading in flight.
                .matchedGeometryEffect(
                    id: transition.nameID, in: transition.namespace, properties: .position,
                    isSource: transition.isSource
                )
                .accessibilityIdentifier("profile-pin-name")
                .accessibilityAddTraits(.isHeader)
            if availability == .available {
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(palette.secondaryText)
                    .accessibilityIdentifier("pin-entry-title")
                    .modifier(PINKeyEntrance(enabled: true, position: 0, reduceMotion: reduceMotion))
                    .opacity(transition.isSource ? 1 : 0)
            } else {
                Text(verbatim: " ").font(.subheadline).accessibilityHidden(true)
            }
            ((availability == .available ? errorMessage.map(Text.init) : nil) ?? Text(verbatim: " "))
                .font(.callout)
                .foregroundStyle(availability == .available && errorMessage != nil ? Color.red : .clear)
                .multilineTextAlignment(.center)
                .opacity(transition.isSource ? 1 : 0)
            if let footnote {
                Text(footnote)
                    .font(.footnote)
                    .foregroundStyle(palette.secondaryText)
                    .multilineTextAlignment(.center)
                    .opacity(transition.isSource ? 1 : 0)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("profile-pin-identity")
    }

    private var identityName: some View {
        #if os(tvOS)
        HStack(spacing: 6) {
            name
            if showsLock {
                Image(systemName: "lock.fill")
                    .font(.caption2.weight(.semibold))
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name)
        .accessibilityValue(showsLock ? Text(ProfileLockCopy.title) : Text(verbatim: ""))
        #else
        PINIdentityName(name: name, showsLock: showsLock)
        #endif
    }
}

private struct PINProfileRequirementState: View {
    let availability: PINEntryAvailability
    let errorMessage: LocalizedStringResource?
    let onRetry: () -> Void
    @State private var showsLoading = false

    var body: some View {
        ContentStateView<Bool, EmptyView>(
            state: availability == .checking ? .loading : .failed(.serverUnreachable),
            errorMessage: errorMessage,
            onRetry: onRetry,
            loadingContent: {
                if showsLoading {
                    ProgressView("Loading")
                        .accessibilityIdentifier("profile-pin-checking")
                }
            },
            content: { _ in EmptyView() }
        )
        .task(id: availability) {
            showsLoading = false
            guard availability == .checking else { return }
            do {
                try await Task.sleep(for: .milliseconds(800))
            } catch { return }
            showsLoading = true
        }
    }
}

struct PINKeyEntrance: ViewModifier {
    let enabled: Bool
    let position: Int
    let reduceMotion: Bool
    @State private var isPresented = false
    @State private var isInteractive = false

    private var delay: TimeInterval { 0.14 + Double(position) * 0.025 }

    func body(content: Content) -> some View {
        content
            .opacity(!enabled || reduceMotion || isPresented ? 1 : 0)
            .offset(y: !enabled || reduceMotion || isPresented ? 0 : 8)
            .animation(
                enabled && !reduceMotion ? .smooth(duration: 0.28).delay(delay) : nil,
                value: isPresented
            )
            .allowsHitTesting(!enabled || reduceMotion || isInteractive)
            .accessibilityHidden(enabled && !reduceMotion && !isInteractive)
            .onAppear { if enabled { isPresented = true } }
            .task {
                guard enabled else { return }
                guard !reduceMotion else { isInteractive = true; return }
                do {
                    try await Task.sleep(for: .seconds(delay + 0.08))
                } catch { return }
                isInteractive = true
            }
    }
}
