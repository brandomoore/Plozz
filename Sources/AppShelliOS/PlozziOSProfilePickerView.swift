#if os(iOS)
import CoreModels
import FeatureProfiles
import Foundation
import SwiftUI
import CoreUI

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

    @State private var isEditing = false
    @State private var route: Route?
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

                        PlozziOSProfilePickerGrid(
                            profiles: profiles, layout: layout,
                            canManage: manager != nil, isEditing: isEditing,
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
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            .background { AppBackground(palette: palette) }
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                if let onCancel, !isEditing {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Cancel", systemImage: "xmark", action: onCancel)
                            .labelStyle(.iconOnly)
                            .accessibilityIdentifier("profile-picker-close")
                    }
                }
                if manager != nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                                isEditing.toggle()
                            }
                        } label: {
                            if isEditing {
                                Text("Done")
                            } else {
                                Label("Edit Profiles", systemImage: "pencil")
                                    .labelStyle(.iconOnly)
                            }
                        }
                        .accessibilityIdentifier("profile-picker-edit")
                    }
                }
            }
            .navigationDestination(item: $route) { route in
                destination(for: route)
            }
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
    let canManage: Bool
    let isEditing: Bool
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
                Button {
                    if isEditing, canManage { onEdit(profile) } else { onSelect(profile) }
                } label: {
                    PlozziOSProfilePickerTile(title: Text(profile.name)) {
                        ProfileAvatarView(profile: profile, size: layout.avatarSize)
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
                .accessibilityIdentifier("profile-picker-\(profile.id)")
                .accessibilityHint(isEditing
                    ? "Opens this profile’s settings" : "Switches to this profile")
                .contextMenu {
                    if canManage {
                        Button("Edit Profile", systemImage: "pencil") { onEdit(profile) }
                    }
                }
                .modifier(PlozziOSProfilePickerEntrance(
                    isPresented: hasAppeared, position: position, reduceMotion: reduceMotion
                ))
            }
            if canManage, !isEditing {
                PlozziOSProfilePickerAddTile(
                    title: "Add Profile", symbol: "plus", size: layout.avatarSize
                ) { onAdd(false) }
                .modifier(PlozziOSProfilePickerEntrance(
                    isPresented: hasAppeared, position: profiles.count, reduceMotion: reduceMotion
                ))
                PlozziOSProfilePickerAddTile(
                    title: KidsProfileCopy.addTile, symbol: "figure.and.child.holdinghands",
                    size: layout.avatarSize
                ) { onAdd(true) }
                .modifier(PlozziOSProfilePickerEntrance(
                    isPresented: hasAppeared, position: profiles.count + 1, reduceMotion: reduceMotion
                ))
            }
        }
        .task {
            guard !hasAppeared else { return }
            if !reduceMotion {
                // Commit the hidden grid first; onAppear coalesces into the initial render.
                try? await Task.sleep(for: .milliseconds(40))
                guard !Task.isCancelled else { return }
            }
            hasAppeared = true
        }
    }
}

private struct PlozziOSProfilePickerTile<Avatar: View>: View {
    let title: Text
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

struct PlozziOSProfilePickerEntrance: ViewModifier {
    let isPresented: Bool
    let position: Int
    let reduceMotion: Bool

    static let initialScale: CGFloat = 0.94
    static let duration: TimeInterval = 0.5
    static func delay(at position: Int) -> TimeInterval { min(Double(max(0, position)) * 0.05, 0.3) }

    func body(content: Content) -> some View {
        content
            .opacity(isPresented || reduceMotion ? 1 : 0)
            .scaleEffect(isPresented || reduceMotion ? 1 : Self.initialScale)
            .allowsHitTesting(isPresented || reduceMotion)
            .accessibilityHidden(!isPresented && !reduceMotion)
            .animation(
                reduceMotion ? nil : .timingCurve(0.2, 0.8, 0.2, 1, duration: Self.duration)
                    .delay(Self.delay(at: position)),
                value: isPresented
            )
    }
}
#endif
