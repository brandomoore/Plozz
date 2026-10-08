#if canImport(SwiftUI)
import CoreUI
import Observation
import SwiftUI

@MainActor
@Observable
final class SettingsDetailNavigation {
    private(set) var isPresented = false
    private(set) var awaitingFocus = false
    private(set) var returnFocusGeneration = 0
    private var transitionGeneration = 0

    func push(animated: Bool) {
        transitionGeneration += 1
        awaitingFocus = true
        withAnimation(animated ? .easeInOut(duration: 0.2) : nil) {
            isPresented = true
        }
    }

    func pop(animated: Bool) {
        transitionGeneration += 1
        let generation = transitionGeneration
        awaitingFocus = true
        withAnimation(animated ? .easeInOut(duration: 0.2) : nil, completionCriteria: .removed) {
            isPresented = false
        } completion: {
            guard self.transitionGeneration == generation else { return }
            self.returnFocusGeneration += 1
        }
    }

    func focusArrived() { awaitingFocus = false }

    func reset() {
        transitionGeneration += 1
        isPresented = false
        awaitingFocus = false
        returnFocusGeneration = 0
    }
}

/// A retained settings page and its child share one clipped, directional slide.
struct SettingsDetailPages<Root: View, Detail: View>: View {
    let navigation: SettingsDetailNavigation
    @ViewBuilder var root: () -> Root
    @ViewBuilder var detail: () -> Detail
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var rootFocusScope

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                root()
                    .tvOSFocusScope(rootFocusScope)
                    .environment(\.settingsDetailRootFocusScope, rootFocusScope)
                    .environment(\.settingsDetailRootEnabled, isEnabled)
                    .environment(\.isEnabled, isEnabled && !navigation.isPresented && !navigation.awaitingFocus)
                    .allowsHitTesting(!navigation.isPresented)
                    .accessibilityHidden(navigation.isPresented)
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                    .offset(x: navigation.isPresented ? -geometry.size.width : 0)
                if navigation.isPresented {
                    detail()
                        .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                        .transition(.move(edge: .trailing))
                        #if os(tvOS)
                        .onExitCommand {
                            navigation.pop(animated: !reduceMotion)
                        }
                        #endif
                }
            }
        }
        .environment(navigation)
        .clipped()
    }
}

/// Uses the registered detail pane on TV, or ordinary navigation outside that pane.
struct SettingsDetailLink<Destination: View, Label: View>: View {
    @ViewBuilder var destination: () -> Destination
    @ViewBuilder var label: () -> Label
    @Environment(SettingsDetailNavigation.self) private var navigation: SettingsDetailNavigation?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.settingsDetailRootFocusScope) private var rootFocusScope
    @Environment(\.settingsDetailRootEnabled) private var rootEnabled
    #if os(tvOS)
    @Environment(\.resetFocus) private var resetFocus
    #endif
    @FocusState private var isFocused: Bool

    var body: some View {
        Group {
            if let navigation {
                Button {
                    navigation.push(animated: !reduceMotion)
                } label: {
                    label()
                }
                .focused($isFocused)
                .modifier(SettingsDetailReturnFocus())
                .environment(\.isEnabled, rootEnabled && !navigation.isPresented)
            } else {
                NavigationLink(destination: destination, label: label)
                    .focused($isFocused)
            }
        }
        .onChange(of: isFocused) { _, focused in
            if focused { navigation?.focusArrived() }
        }
        .task(id: navigation?.returnFocusGeneration) {
            guard let navigation, navigation.returnFocusGeneration > 0 else { return }
            isFocused = false
            await Task.yield()
            if !Task.isCancelled, !navigation.isPresented {
                isFocused = true
                #if os(tvOS)
                if let rootFocusScope { resetFocus(in: rootFocusScope) }
                #endif
            }
        }
    }
}

private struct SettingsDetailReturnFocus: ViewModifier {
    @Environment(SettingsDetailNavigation.self) private var navigation: SettingsDetailNavigation?
    @Environment(\.settingsDetailRootFocusScope) private var scope

    @ViewBuilder
    func body(content: Content) -> some View {
        if let scope {
            content.tvOSPrefersDefaultFocus(navigation?.awaitingFocus == true, in: scope)
        } else {
            content
        }
    }
}

private struct SettingsDetailRootFocusScopeKey: EnvironmentKey {
    static let defaultValue: Namespace.ID? = nil
}

private struct SettingsDetailRootEnabledKey: EnvironmentKey {
    static let defaultValue = true
}

private extension EnvironmentValues {
    var settingsDetailRootEnabled: Bool {
        get { self[SettingsDetailRootEnabledKey.self] }
        set { self[SettingsDetailRootEnabledKey.self] = newValue }
    }

    var settingsDetailRootFocusScope: Namespace.ID? {
        get { self[SettingsDetailRootFocusScopeKey.self] }
        set { self[SettingsDetailRootFocusScopeKey.self] = newValue }
    }
}
#endif
