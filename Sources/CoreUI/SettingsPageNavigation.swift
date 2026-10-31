#if canImport(SwiftUI)
import Observation
import SwiftUI

public enum SettingsPageMotion {
    public static let travelDistance: CGFloat = 64
    public static let animation: Animation = .timingCurve(0.22, 0, 0.2, 1, duration: 0.42)

    public static func transition(edge: HorizontalEdge) -> AnyTransition {
        .modifier(
            active: SettingsPageVisibility(isVisible: false, hiddenEdge: edge),
            identity: SettingsPageVisibility(isVisible: true, hiddenEdge: edge)
        )
    }

    public static func transition(isReturning: Bool) -> AnyTransition {
        .asymmetric(
            insertion: transition(edge: isReturning ? .leading : .trailing),
            removal: transition(edge: isReturning ? .trailing : .leading)
        )
    }
}

private struct SettingsPageVisibility: ViewModifier {
    let isVisible: Bool
    let hiddenEdge: HorizontalEdge
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .offset(x: isVisible || reduceMotion ? 0
                : (hiddenEdge == .leading ? -1 : 1) * SettingsPageMotion.travelDistance)
            .opacity(isVisible ? 1 : 0)
    }
}

public extension View {
    func settingsPageVisibility(_ isVisible: Bool, hiddenEdge: HorizontalEdge = .leading) -> some View {
        modifier(SettingsPageVisibility(isVisible: isVisible, hiddenEdge: hiddenEdge))
    }
}

#if os(tvOS)
@MainActor
@Observable
public final class SettingsPageNavigation<Route: Hashable> {
    public struct Page: Identifiable {
        public let id: UUID
        public let route: Route?
        let content: AnyView?
        let sourceID: UUID?
    }

    public private(set) var pages: [Page] = []
    public private(set) var returnSourceID: UUID?
    public private(set) var returnGeneration = 0
    fileprivate var entryPageID: UUID?
    public private(set) var isTransitioning = false
    public var animationsEnabled = true
    private var transitionGeneration = 0

    public init() {}

    public var routes: [Route] {
        get { pages.compactMap(\.route) }
        set {
            let oldRoutes = routes
            guard oldRoutes != newValue else { return }
            let commonCount = zip(oldRoutes, newValue).prefix { $0 == $1 }.count
            var retainedCount = 0
            var routeCount = 0
            for page in pages where routeCount < commonCount {
                retainedCount += 1
                if page.route != nil { routeCount += 1 }
            }
            change(isReturning: newValue.count < oldRoutes.count) {
                let retained = Array(pages.prefix(retainedCount))
                let added = newValue.dropFirst(commonCount).map {
                    Page(id: UUID(), route: $0, content: nil, sourceID: nil)
                }
                returnSourceID = pages.last?.sourceID
                entryPageID = added.last?.id
                pages = retained + added
            }
        }
    }

    public func push(_ route: Route, sourceID: UUID? = nil) {
        append(Page(id: UUID(), route: route, content: nil, sourceID: sourceID))
    }

    fileprivate func push(_ content: AnyView, id: UUID = UUID(), sourceID: UUID? = nil) {
        append(Page(id: id, route: nil, content: content, sourceID: sourceID))
    }

    private func append(_ page: Page) {
        change(isReturning: false) {
            returnSourceID = nil
            entryPageID = page.id
            pages.append(page)
        }
    }

    public func pop() {
        guard let page = pages.last else { return }
        remove(from: page.id)
    }

    fileprivate func remove(from id: UUID) {
        guard let index = pages.firstIndex(where: { $0.id == id }) else { return }
        change(isReturning: true) {
            entryPageID = nil
            returnSourceID = pages[index].sourceID
            pages.removeSubrange(index...)
        }
    }

    public func reset() {
        transitionGeneration += 1
        pages.removeAll()
        returnSourceID = nil
        entryPageID = nil
        isTransitioning = false
        returnGeneration = 0
    }

    private func change(isReturning: Bool, _ update: () -> Void) {
        transitionGeneration += 1
        let generation = transitionGeneration
        isTransitioning = animationsEnabled
        withAnimation(animationsEnabled ? SettingsPageMotion.animation : nil, completionCriteria: .removed) {
            update()
        } completion: {
            guard self.transitionGeneration == generation else { return }
            self.isTransitioning = false
            if isReturning { self.returnGeneration += 1 }
        }
    }
}

public struct SettingsPageContext {
    public let isCurrent: Bool
    public let depth: Int
    let requestsEntryFocus: Bool
    let returnSourceID: UUID?
    let returnGeneration: Int
    let pageIDs: [UUID]
    let push: (AnyView, UUID, UUID?) -> Void
    let remove: (UUID) -> Void
    let pop: () -> Void
}

private struct SettingsPageContextKey: EnvironmentKey {
    static let defaultValue: SettingsPageContext? = nil
}

public extension EnvironmentValues {
    var settingsPageContext: SettingsPageContext? {
        get { self[SettingsPageContextKey.self] }
        set { self[SettingsPageContextKey.self] = newValue }
    }
}

/// Retains every parent while one current page owns input, accessibility and Back.
public struct SettingsPageStack<Route: Hashable, Root: View, Destination: View>: View {
    let navigation: SettingsPageNavigation<Route>
    let pageWidth: CGFloat
    let onRootBack: (() -> Void)?
    let fullWidthDestination: (Route) -> Bool
    let presentsSubpagesFullScreen: Bool
    let onSubpagesDismiss: (() -> Void)?
    let root: () -> Root
    let destination: (Route) -> Destination
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        navigation: SettingsPageNavigation<Route>, pageWidth: CGFloat,
        onRootBack: (() -> Void)?,
        fullWidthDestination: @escaping (Route) -> Bool = { _ in false },
        presentsSubpagesFullScreen: Bool = false,
        onSubpagesDismiss: (() -> Void)? = nil,
        @ViewBuilder root: @escaping () -> Root,
        @ViewBuilder destination: @escaping (Route) -> Destination
    ) {
        self.navigation = navigation
        self.pageWidth = pageWidth
        self.onRootBack = onRootBack
        self.fullWidthDestination = fullWidthDestination
        self.presentsSubpagesFullScreen = presentsSubpagesFullScreen
        self.onSubpagesDismiss = onSubpagesDismiss
        self.root = root
        self.destination = destination
    }

    public var body: some View {
        GeometryReader { geometry in
            let columnSize = CGSize(width: min(pageWidth, geometry.size.width), height: geometry.size.height)
            ZStack(alignment: .topLeading) {
                layer(id: nil, size: columnSize, viewport: geometry.size, content: root)
                if !presentsSubpagesFullScreen {
                    subpages(in: geometry.size)
                }
            }
        }
        .plozzFullScreenCover(isPresented: Binding(
            get: { presentsSubpagesFullScreen && !navigation.pages.isEmpty },
            set: { if !$0 { navigation.reset() } }
        ), onDismiss: onSubpagesDismiss) {
            GeometryReader { geometry in
                subpages(in: geometry.size)
            }
            .safeAreaPadding(.top, 36)
            .ignoresSafeArea(.container, edges: .vertical)
            .background {
                SettingsPageBackground()
                    .environment(\.settingsInWorkspace, false)
            }
        }
        .mask { Rectangle().ignoresSafeArea(.container, edges: .vertical) }
        .onChange(of: reduceMotion, initial: true) { _, value in
            navigation.animationsEnabled = !value
        }
    }

    private func subpages(in viewport: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(navigation.pages) { page in
                layer(
                    id: page.id,
                    size: CGSize(
                        width: page.route.map(fullWidthDestination) == true
                            ? viewport.width : min(pageWidth, viewport.width),
                        height: viewport.height
                    ),
                    viewport: viewport
                ) {
                    if let route = page.route {
                        destination(route)
                    } else {
                        page.content
                    }
                }
                .transition(reduceMotion ? .identity : SettingsPageMotion.transition(edge: .trailing))
            }
        }
    }

    private func layer<Content: View>(
        id: UUID?, size: CGSize, viewport: CGSize, @ViewBuilder content: () -> Content
    ) -> some View {
        let current = navigation.pages.last?.id == id
        let interactive = current && !navigation.isTransitioning
        let context = SettingsPageContext(
            isCurrent: interactive,
            depth: id.flatMap { id in navigation.pages.firstIndex { $0.id == id } }.map { $0 + 1 } ?? 0,
            requestsEntryFocus: interactive && id != nil && navigation.entryPageID == id,
            returnSourceID: navigation.returnSourceID,
            returnGeneration: navigation.returnGeneration,
            pageIDs: navigation.pages.map(\.id),
            push: { content, childID, source in
                guard navigation.pages.last?.id == id else { return }
                navigation.push(content, id: childID, sourceID: source)
            },
            remove: navigation.remove,
            pop: {
                guard navigation.pages.last?.id == id else { return }
                id == nil ? onRootBack?() : navigation.pop()
            }
        )
        return content()
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .frame(width: viewport.width, height: viewport.height, alignment: .top)
            .environment(\.settingsPageContext, context)
            .environment(\.settingsPageBackButton, id.map { _ in
                AnyView(SettingsBackButton(action: context.pop)
                    .settingsPageEntryFocus().accessibilityIdentifier("settings-workspace-back"))
            })
            .environment(\.isEnabled, isEnabled && interactive)
            .allowsHitTesting(interactive)
            .accessibilityElement(children: interactive ? .contain : .ignore)
            .accessibilityHidden(!interactive)
            .settingsPageVisibility(current)
            .onExitCommand(perform: current && (id != nil || onRootBack != nil) ? context.pop : nil)
    }
}

private struct SettingsPageEntryFocus: ViewModifier {
    let enabled: Bool
    @Environment(\.settingsPageContext) private var context
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content
            .focused($focused)
            .task(id: context?.requestsEntryFocus) {
                guard enabled, context?.requestsEntryFocus == true else { return }
                await Task.yield()
                guard !Task.isCancelled else { return }
                focused = true
            }
    }
}

public extension View {
    func settingsPageEntryFocus(enabled: Bool = true) -> some View {
        modifier(SettingsPageEntryFocus(enabled: enabled))
    }
}

public struct SettingsPageActionLink<Label: View>: View {
    let openOnMove: MoveCommandDirection?
    let action: (UUID) -> Void
    let label: () -> Label
    @State private var sourceID = UUID()
    @FocusState private var focused: Bool
    @Environment(\.settingsPageContext) private var context
    @Environment(\.isEnabled) private var isEnabled

    public init(
        openOnMove: MoveCommandDirection? = nil,
        action: @escaping (UUID) -> Void, @ViewBuilder label: @escaping () -> Label
    ) {
        self.openOnMove = openOnMove
        self.action = action
        self.label = label
    }

    public var body: some View {
        let eligible = isEnabled && (context?.isCurrent ?? true)
        Button { action(sourceID) } label: { label() }
            .focused($focused)
            .disabled(!eligible)
            .onMoveCommand { direction in
                if eligible, direction == openOnMove { action(sourceID) }
            }
            .task(id: context?.returnGeneration) {
                guard let context, context.isCurrent, context.returnGeneration > 0,
                      context.returnSourceID == sourceID else { return }
                focused = false
                await Task.yield()
                guard !Task.isCancelled else { return }
                focused = true
            }
    }
}
#endif

/// Native navigation outside the TV Settings workspace.
public struct SettingsPageLink<Destination: View, Label: View>: View {
    let destination: () -> Destination
    let label: () -> Label
    #if os(tvOS)
    @Environment(\.settingsPageContext) private var context
    #endif

    public init(@ViewBuilder destination: @escaping () -> Destination, @ViewBuilder label: @escaping () -> Label) {
        self.destination = destination
        self.label = label
    }

    public var body: some View {
        #if os(tvOS)
        if let context {
            SettingsPageActionLink { source in
                context.push(AnyView(destination()), UUID(), source)
            } label: { label() }
        } else {
            NavigationLink(destination: destination, label: label)
        }
        #else
        NavigationLink(destination: destination, label: label)
        #endif
    }
}

@propertyWrapper
public struct SettingsPageDismiss: DynamicProperty {
    @Environment(\.dismiss) private var nativeDismiss
    #if os(tvOS)
    @Environment(\.settingsPageContext) private var context
    #endif

    public init() {}

    public var wrappedValue: () -> Void {
        #if os(tvOS)
        if let context { return context.pop }
        #endif
        return { nativeDismiss() }
    }
}

public extension View {
    func settingsPageDestination<Destination: View>(
        isPresented: Binding<Bool>, @ViewBuilder destination: @escaping () -> Destination
    ) -> some View {
        modifier(SettingsPageDestination(isPresented: isPresented, destination: destination))
    }
}

private struct SettingsPageDestination<Destination: View>: ViewModifier {
    @Binding var isPresented: Bool
    let destination: () -> Destination
    #if os(tvOS)
    @Environment(\.settingsPageContext) private var context
    @State private var pageID = UUID()
    #endif

    func body(content: Content) -> some View {
        #if os(tvOS)
        if let context {
            content
                .onChange(of: isPresented) { _, presented in
                    if presented {
                        context.push(AnyView(destination()), pageID, nil)
                    } else {
                        context.remove(pageID)
                    }
                }
                .onChange(of: context.pageIDs.contains(pageID)) { wasPresented, presented in
                    if wasPresented && !presented { isPresented = false }
                }
        } else {
            content.navigationDestination(isPresented: $isPresented, destination: destination)
        }
        #else
        content.navigationDestination(isPresented: $isPresented, destination: destination)
        #endif
    }
}
#endif
