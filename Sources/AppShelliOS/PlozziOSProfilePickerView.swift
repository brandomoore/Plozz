#if os(iOS)
import CoreModels
import FeatureProfiles
import Foundation
import SwiftUI
import CoreUI
import UIKit

/// Keeps selection and authorization in one presentation, including while Plex
/// checks the current PIN requirement. Only a completed selection closes it.
struct PlozziOSProfileSelectionView: View {
    let appModel: PlozziOSAppModel
    var onSelectionStarted: () -> Void = {}
    let onComplete: () -> Void
    var onCancel: (() -> Void)?

    @State private var selectedProfileID: String?
    @State private var profileOrder: [String] = []
    @State private var hasPresentedAuthorization = false
    @State private var selectionAllowsManagement = false
    @Namespace private var profileIdentity
    @Environment(\.themePalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var hasPendingAuthorization: Bool {
        appModel.parentalSwitch != nil || appModel.lockedSwitch != nil
            || appModel.plexHomeUsers.pendingPlexPINRequest != nil
    }

    private var presentsAuthorization: Bool {
        selectedProfileID != nil && (hasPresentedAuthorization || hasPendingAuthorization)
    }

    private var selectedProfile: Profile? {
        appModel.profiles.profiles.first { $0.id == selectedProfileID }
    }

    private var displayedProfiles: [Profile] {
        let recent = appModel.profiles.profilesByRecency
        let byID = Dictionary(uniqueKeysWithValues: recent.map { ($0.id, $0) })
        let retainedIDs = Set(profileOrder)
        return profileOrder.compactMap { byID[$0] } + recent.filter { !retainedIDs.contains($0.id) }
    }

    private var pickerManager: PlozziOSAppModel? {
        let canManage = selectedProfileID == nil
            ? !appModel.managementRequiresParentalPIN : selectionAllowsManagement
        return canManage ? appModel : nil
    }

    private var selectionCompleted: Bool {
        selectedProfileID != nil
            && selectedProfileID == appModel.profiles.activeProfileID
            && !hasPendingAuthorization
            && !appModel.activeProfileNeedsUnlock
            && !appModel.mustChooseProfile
    }

    var body: some View {
        ZStack {
            PlozziOSProfilePickerView(
                profiles: displayedProfiles,
                activeProfileID: appModel.profiles.activeProfileID,
                onSelect: { profile in
                    onSelectionStarted()
                    // Activation changes recency immediately; keep the tapped
                    // tile in place through verification and cancellation.
                    profileOrder = displayedProfiles.map(\.id)
                    selectionAllowsManagement = !appModel.managementRequiresParentalPIN
                    selectedProfileID = profile.id
                    hasPresentedAuthorization = false
                    // A cancelled Plex attempt can leave a fallback PIN prompt.
                    // A new selection must recheck gates for its own target.
                    appModel.cancelProfileLockPrompt()
                    appModel.cancelParentalSwitch()
                    appModel.selectProfile(profile.id)
                },
                manager: pickerManager,
                onCancel: onCancel,
                identityNamespace: profileIdentity,
                selectedProfileID: selectedProfileID,
                isCovered: presentsAuthorization,
                showsPINLock: appModel.accountsProviders.profileShowsPINLock,
                offlineMode: appModel.isOfflineModeAvailable ? Binding(
                    get: { appModel.isOfflineMode },
                    set: { enabled in Task { await appModel.setOfflineMode(enabled) } }
                ) : nil,
                isChangingOfflineMode: appModel.isChangingOfflineMode
            )
            .allowsHitTesting(!presentsAuthorization && selectedProfileID == nil)
            .accessibilityHidden(presentsAuthorization)

            if presentsAuthorization {
                PlozziOSProfileAccessGateView(appModel: appModel, profile: selectedProfile) {
                    selectedProfileID = nil
                    hasPresentedAuthorization = false
                }
                .environment(\.pinProfileTransition, selectedProfile.map {
                    PINProfileTransition(profileID: $0.id, namespace: profileIdentity)
                })
                .transition(.identity)
                .zIndex(1)
            }
        }
        .offlineStatusOverlay(appModel: appModel, palette: palette, isEnabled: !presentsAuthorization)
        .background { AppBackground(palette: palette).ignoresSafeArea() }
        .animation(reduceMotion ? nil : .smooth(duration: 0.48), value: presentsAuthorization)
        .onChange(of: presentsAuthorization) { _, presented in
            // Once opened, keep the gate through chained PINs and completion
            // instead of revealing the picker between authorization phases.
            if presented { hasPresentedAuthorization = true }
        }
        .onChange(of: selectionCompleted) { _, completed in
            if completed { onComplete() }
        }
    }
}

/// "Who's watching?" — the one screen for choosing a profile, and for changing
/// or adding one.
///
/// Used both at launch and as the switcher reached from Settings, so switching
/// looks the same wherever you start. That mirrors the tvOS picker, which has
/// always carried Add and Edit alongside the tiles.
///
/// Editing has two ways in, because touch has no focused-tile affordance to hang
/// an Edit button on: **long-press a profile**, or turn on **Edit Profiles** and
/// tap. The first is fast, the second is findable.
struct PlozziOSProfilePickerView: View {
    let profiles: [Profile]
    let activeProfileID: String
    let onSelect: (Profile) -> Void
    /// Supplied only when profile management is authorized. Its presence turns
    /// on Add and Edit at launch as well as in the switcher.
    ///
    /// The picker drives those flows through its OWN navigation stack instead of
    /// handing them back to the caller. A second presentation from the same host
    /// as this cover is the arrangement SwiftUI drops silently, and the caller
    /// (the tab shell) already owns the Settings sheet.
    var manager: PlozziOSAppModel?
    /// Closes the picker. `nil` at launch, where there's nothing to go back to.
    var onCancel: (() -> Void)?
    var identityNamespace: Namespace.ID?
    var selectedProfileID: String?
    var isCovered = false
    var showsPINLock: (Profile) -> Bool = { $0.showsPINLock }
    var offlineMode: Binding<Bool>?
    var isChangingOfflineMode = false

    @State private var isEditing = false
    @State private var route: Route?
    @State private var hasAppeared = false
    @State private var hasRevealedProfiles = false
    @Namespace private var localIdentityNamespace
    @Environment(\.themePalette) private var palette
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// What the picker has pushed on top of itself.
    private enum Route: Hashable, Identifiable {
        case add(isKids: Bool)
        case edit(profileID: String)
        var id: Self { self }
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                let layout = PlozziOSProfilePickerLayout(
                    width: geometry.size.width,
                    itemCount: profiles.count + (manager != nil ? 2 : 0),
                    usesAccessibleText: dynamicTypeSize.isAccessibilitySize
                )
                ScrollView {
                    VStack(spacing: 36) {
                        Text(isEditing
                            ? "Edit Profiles"
                            : (profiles.count > 1 ? "Who’s watching?" : "Profiles"))
                            .font(.title2.weight(.bold))
                            .foregroundStyle(palette.primaryText)
                            .multilineTextAlignment(.center)
                            .accessibilityAddTraits(.isHeader)
                            .modifier(PlozziOSProfilePickerHeadingEntrance(
                                isPresented: hasAppeared, isLaunch: onCancel == nil,
                                reduceMotion: reduceMotion
                            ))
                            .animation(reduceMotion ? nil : .easeOut(duration: 0.18)) { content in
                                content.opacity(isCovered ? 0 : 1)
                            }

                        PlozziOSProfilePickerGrid(
                            profiles: profiles, layout: layout,
                            showsPINLock: showsPINLock,
                            canManage: manager != nil, isEditing: isEditing,
                            isPresented: onCancel != nil || hasRevealedProfiles,
                            startsDuringPresentation: onCancel != nil,
                            identityNamespace: identityNamespace ?? localIdentityNamespace,
                            selectedProfileID: selectedProfileID,
                            isCovered: isCovered,
                            onSelect: onSelect,
                            onEdit: { route = .edit(profileID: $0.id) },
                            onAdd: { route = .add(isKids: $0) }
                        )
                    }
                    .frame(maxWidth: layout.contentWidth)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 32)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: geometry.size.height, alignment: .center)
                    .background {
                        ProfilePickerPresentationObserver(startsDuringPresentation: onCancel != nil) {
                            startEntrance()
                        }
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            .background { AppBackground(palette: palette) }
            .toolbar(manager != nil || offlineMode != nil || onCancel != nil ? .visible : .automatic, for: .navigationBar)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                if let onCancel, !isEditing, !isCovered {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Cancel", systemImage: "xmark", action: onCancel)
                            .labelStyle(.iconOnly)
                            .accessibilityIdentifier("profile-picker-close")
                    }
                }
                if (manager != nil || offlineMode != nil), !isCovered {
                    ToolbarItem(placement: .topBarTrailing) {
                        if isEditing {
                            Button("Done") {
                                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                                    isEditing = false
                                }
                            }
                            .accessibilityIdentifier("profile-picker-edit")
                        } else {
                            Menu {
                                if manager != nil {
                                    Button("Edit Profiles", systemImage: "pencil") {
                                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                                            isEditing = true
                                        }
                                    }
                                    .accessibilityIdentifier("profile-picker-edit")
                                }
                                if let offlineMode {
                                    Toggle("Offline Mode", systemImage: "wifi.slash", isOn: offlineMode)
                                        .disabled(isChangingOfflineMode)
                                        .accessibilityIdentifier("profile-picker-offline-mode")
                                }
                            } label: {
                                Label("More", systemImage: "ellipsis").labelStyle(.iconOnly)
                            }
                            .accessibilityIdentifier("profile-picker-options")
                        }
                    }
                }
            }
            .navigationDestination(item: $route) { route in
                destination(for: route)
            }
        }
    }

    private func startEntrance() {
        guard !hasAppeared else { return }
        guard onCancel == nil, !reduceMotion else {
            hasAppeared = true
            hasRevealedProfiles = true
            return
        }
        withAnimation(
            .smooth(duration: PlozziOSProfilePickerEntrance.headingDuration),
            completionCriteria: .logicallyComplete
        ) {
            hasAppeared = true
        } completion: {
            hasRevealedProfiles = true
        }
    }

    @ViewBuilder
    private func destination(for route: Route) -> some View {
        if let manager {
            switch route {
            case let .add(isKids):
                PlozziOSProfileEditorHost(
                    appModel: manager,
                    createsKidsProfile: isKids
                ) {
                    self.route = nil
                    // Close the whole picker: a brand-new profile owes its setup
                    // pass, and that cover is presented by the root — which can't
                    // while this one is up.
                    onCancel?()
                }
            case let .edit(profileID):
                PlozziOSProfileSettingsView(appModel: manager, profileID: profileID)
            }
        }
    }
}

struct PlozziOSProfilePickerLayout {
    let contentWidth: CGFloat
    let columnCount: Int
    let avatarSize: CGFloat
    let columnSpacing: CGFloat = 24

    init(width: CGFloat, itemCount: Int, usesAccessibleText: Bool) {
        contentWidth = max(1, min(640, width - 48))
        let capacity = usesAccessibleText ? 1
            : contentWidth >= 520 ? 4
            : contentWidth >= 340 && itemCount > 6 ? 3 : 2
        columnCount = min(max(1, itemCount), capacity)
        let cellWidth = (contentWidth - CGFloat(columnCount - 1) * columnSpacing) / CGFloat(columnCount)
        avatarSize = min(contentWidth >= 520 ? 104 : 96, max(64, cellWidth - 16))
    }
}

private struct PlozziOSProfilePickerGrid: View {
    let profiles: [Profile]
    let layout: PlozziOSProfilePickerLayout
    let showsPINLock: (Profile) -> Bool
    let canManage: Bool
    let isEditing: Bool
    let isPresented: Bool
    let startsDuringPresentation: Bool
    let identityNamespace: Namespace.ID
    let selectedProfileID: String?
    let isCovered: Bool
    let onSelect: (Profile) -> Void
    let onEdit: (Profile) -> Void
    let onAdd: (Bool) -> Void
    @State private var hasAppeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: layout.columnSpacing, alignment: .top),
                           count: layout.columnCount),
            spacing: 24
        ) {
            ForEach(Array(profiles.enumerated()), id: \.element.id) { position, profile in
                let showsLock = showsPINLock(profile)
                let identity = PINProfileTransition(
                    profileID: isCovered ? "retained-\(profile.id)" : profile.id,
                    namespace: identityNamespace
                )
                Button {
                    if isEditing, canManage { onEdit(profile) } else { onSelect(profile) }
                } label: {
                    PlozziOSProfilePickerTile(title:
                        ProfileNameLabel(profile: profile, showsLock: showsLock)
                            .matchedGeometryEffect(
                                id: identity.nameID, in: identity.namespace, properties: .position
                            )
                    ) {
                        ProfileAvatarView(profile: profile, size: layout.avatarSize)
                            .matchedGeometryEffect(id: identity.avatarID, in: identity.namespace)
                            .overlay(alignment: .bottomTrailing) {
                                if isEditing {
                                    Image(systemName: "pencil.circle.fill")
                                        .font(.title3)
                                        .symbolRenderingMode(.palette)
                                        .foregroundStyle(.black, .white)
                                }
                            }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(profile.name)
                .accessibilityValue(showsLock ? Text(ProfileLockCopy.title) : Text(verbatim: ""))
                .accessibilityIdentifier("profile-picker-\(profile.id)")
                .accessibilityHint(isEditing
                    ? "Opens this profile’s settings" : "Switches to this profile")
                .contextMenu {
                    if canManage {
                        Button("Edit Profile", systemImage: "pencil") { onEdit(profile) }
                    }
                }
                .modifier(PlozziOSProfilePickerEntrance(
                    isPresented: hasAppeared, position: position,
                    profileCount: profiles.count, reduceMotion: reduceMotion
                ))
                .animation(
                    reduceMotion || profile.id == selectedProfileID ? nil : .easeOut(duration: 0.18)
                ) { content in
                    content.opacity(isCovered ? 0 : 1)
                }
            }
            if canManage, !isEditing {
                PlozziOSProfilePickerAddTile(
                    title: "Add Profile", symbol: "plus", size: layout.avatarSize
                ) { onAdd(false) }
                .modifier(PlozziOSProfilePickerEntrance(
                    isPresented: hasAppeared, position: profiles.count,
                    profileCount: profiles.count, reduceMotion: reduceMotion
                ))
                .opacity(isCovered ? 0 : 1)
                PlozziOSProfilePickerAddTile(
                    title: KidsProfileCopy.addTile, symbol: "figure.and.child.holdinghands",
                    size: layout.avatarSize
                ) { onAdd(true) }
                .modifier(PlozziOSProfilePickerEntrance(
                    isPresented: hasAppeared, position: profiles.count + 1,
                    profileCount: profiles.count, reduceMotion: reduceMotion
                ))
                .opacity(isCovered ? 0 : 1)
            }
        }
        .disabled(isCovered)
        .background {
            ProfilePickerPresentationObserver(
                startsDuringPresentation: startsDuringPresentation, isReady: isPresented
            ) {
                hasAppeared = true
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

struct ProfilePickerPresentationObserver: UIViewControllerRepresentable {
    let startsDuringPresentation: Bool
    var isReady = true
    let onAppear: () -> Void

    func makeUIViewController(context: Context) -> Observer {
        Observer(startsDuringPresentation: startsDuringPresentation, isReady: isReady, onAppear: onAppear)
    }

    func updateUIViewController(_ controller: Observer, context: Context) {
        controller.startsDuringPresentation = startsDuringPresentation
        controller.onAppear = onAppear
        controller.isReady = isReady
    }

    static func dismantleUIViewController(_ controller: Observer, coordinator: ()) {
        controller.cancelPendingEntrance()
    }

    final class Observer: UIViewController {
        var startsDuringPresentation: Bool
        var onAppear: () -> Void
        var isReady: Bool {
            didSet { resumeIfReady() }
        }
        private var hasStarted = false
        private var isAppearing = false
        private var isPresented = false
        private var displayLink: CADisplayLink?
        private var displayedFrames = 0

        init(startsDuringPresentation: Bool, isReady: Bool = true, onAppear: @escaping () -> Void) {
            self.startsDuringPresentation = startsDuringPresentation
            self.isReady = isReady
            self.onAppear = onAppear
            super.init(nibName: nil, bundle: nil)
        }

        required init?(coder: NSCoder) { nil }

        override func loadView() {
            view = UIView()
            view.isUserInteractionEnabled = false
        }

        override func viewIsAppearing(_ animated: Bool) {
            super.viewIsAppearing(animated)
            isAppearing = true
            resumeIfReady()
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            isAppearing = true
            isPresented = true
            guard !hasStarted else { return }
            NotificationCenter.default.addObserver(
                self, selector: #selector(sceneDidActivate),
                name: UIScene.didActivateNotification, object: nil
            )
            resumeIfReady()
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            cancelPendingEntrance()
        }

        func cancelPendingEntrance() {
            isAppearing = false
            isPresented = false
            displayLink?.invalidate()
            displayLink = nil
            NotificationCenter.default.removeObserver(self)
        }

        @objc private func sceneDidActivate(_ notification: Notification) {
            guard let scene = notification.object as? UIWindowScene,
                  scene === view.window?.windowScene else { return }
            resumeIfReady()
        }

        private func resumeIfReady() {
            guard isReady, !hasStarted else { return }
            if startsDuringPresentation {
                if isAppearing { startEntrance() }
            } else {
                scheduleAfterFirstFrame()
            }
        }

        private func scheduleAfterFirstFrame() {
            guard isReady, isPresented, !hasStarted, displayLink == nil,
                  let window = view.window, !window.isHidden,
                  window.windowScene?.activationState == .foregroundActive else { return }
            displayedFrames = 0
            let link = CADisplayLink(target: self, selector: #selector(frameWillDisplay))
            displayLink = link
            link.add(to: .main, forMode: .common)
        }

        @objc private func frameWillDisplay() {
            guard isReady, isPresented, let window = view.window, !window.isHidden,
                  window.windowScene?.activationState == .foregroundActive else {
                displayLink?.invalidate()
                displayLink = nil
                return
            }
            // A display-link callback precedes drawing. Let one frame commit
            // the hidden starting state before starting the entrance clock.
            displayedFrames += 1
            if displayedFrames == 2 { startEntrance() }
        }

        private func startEntrance() {
            guard !hasStarted else { return }
            hasStarted = true
            cancelPendingEntrance()
            onAppear()
        }
    }
}

private struct PlozziOSProfilePickerTile<Title: View, Avatar: View>: View {
    let title: Title
    @ViewBuilder var avatar: () -> Avatar
    @Environment(\.themePalette) private var palette
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(spacing: 10) {
            avatar()
            title
                .font(.callout)
                .foregroundStyle(palette.primaryText)
                .multilineTextAlignment(.center)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }
}

private struct PlozziOSProfilePickerAddTile: View {
    let title: LocalizedStringResource
    let symbol: String
    let size: CGFloat
    let action: () -> Void
    @Environment(\.themePalette) private var palette

    var body: some View {
        Button(action: action) {
            PlozziOSProfilePickerTile(title: Text(title)) {
                Circle()
                    .fill(palette.primaryText.opacity(0.06))
                    .overlay { Circle().strokeBorder(palette.primaryText.opacity(0.12), lineWidth: 1) }
                    .overlay {
                        Image(systemName: symbol)
                            .font(.system(size: size * 0.32, weight: .regular))
                            .foregroundStyle(palette.secondaryText)
                    }
                    .frame(width: size, height: size)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(title))
    }
}

struct PlozziOSProfilePickerHeadingEntrance: ViewModifier {
    let isPresented: Bool
    let isLaunch: Bool
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        let isVisible = isPresented || !isLaunch || reduceMotion
        content
            .opacity(isVisible ? 1 : 0)
            .scaleEffect(isVisible ? 1 : 0.97)
            .offset(y: isVisible ? 0 : 14)
            .animation(
                !isLaunch || reduceMotion ? nil
                    : .smooth(duration: PlozziOSProfilePickerEntrance.headingDuration),
                value: isPresented
            )
            .accessibilityHidden(!isVisible)
    }
}

struct PlozziOSProfilePickerEntrance: ViewModifier {
    let isPresented: Bool
    let position: Int
    let profileCount: Int
    let reduceMotion: Bool
    @State private var isInteractive = false

    static let initialScale: CGFloat = 0.3
    static let initialOffset: CGFloat = 8
    static let duration: TimeInterval = 0.45
    static let headingDuration: TimeInterval = 0.45
    static func delay(at position: Int, profileCount: Int) -> TimeInterval {
        let interval = min(0.09, 0.45 / Double(max(1, profileCount - 1)))
        return Double(max(0, position)) * interval
    }

    init(isPresented: Bool, position: Int, profileCount: Int, reduceMotion: Bool) {
        self.isPresented = isPresented
        self.position = position
        self.profileCount = profileCount
        self.reduceMotion = reduceMotion
        // Cells first realized after the entrance (scrolling a large household)
        // are immediately available instead of waiting through offscreen slots.
        _isInteractive = State(initialValue: isPresented || reduceMotion)
    }

    func body(content: Content) -> some View {
        let delay = Self.delay(at: position, profileCount: profileCount)
        content
            .opacity(isPresented || reduceMotion ? 1 : 0)
            .scaleEffect(isPresented || reduceMotion ? 1 : Self.initialScale)
            .offset(y: isPresented || reduceMotion ? 0 : Self.initialOffset)
            .animation(
                reduceMotion ? nil : .smooth(duration: Self.duration)
                    .delay(isPresented ? delay : 0),
                value: isPresented
            )
            .allowsHitTesting(reduceMotion || (isPresented && isInteractive))
            .accessibilityHidden(!reduceMotion && (!isPresented || !isInteractive))
            .task(id: isPresented) {
                guard isPresented else { isInteractive = false; return }
                guard !isInteractive else { return }
                // Only input admission waits on a task. Avatar animations are
                // scheduled together from the grid-reveal transaction.
                if !reduceMotion {
                    do {
                        try await Task.sleep(for: .seconds(delay))
                    } catch { return }
                }
                isInteractive = true
            }
    }
}
#endif
