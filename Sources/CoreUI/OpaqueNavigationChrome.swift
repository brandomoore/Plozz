#if os(iOS)
import SwiftUI
import UIKit

struct OpaqueNavigationSurface {
    let fill: Color
    let border: Color
    let selection: Color
    let selectionForeground: Color

    init(palette: ThemePalette, gradientEnabled: Bool, bottom: Bool = false) {
        let base = gradientEnabled
            ? AmbientGradientBackground.meshColors(tint: nil, palette: palette)[bottom ? 7 : 1]
            : palette.raised.fill
        let resolved = base.resolve(in: EnvironmentValues())
        let tint = palette.isLight ? 0.0 : 1.0
        func composite(_ opacity: Double) -> Color {
            Color(
                red: Double(resolved.red) * (1 - opacity) + tint * opacity,
                green: Double(resolved.green) * (1 - opacity) + tint * opacity,
                blue: Double(resolved.blue) * (1 - opacity) + tint * opacity
            )
        }
        fill = composite(ThemePalette.gradientSurfaceFillOpacity)
        border = composite(0.12)
        selection = composite(0.16)
        selectionForeground = Color.accentColor.mix(with: palette.primaryText, by: 0.45)
    }
}

public extension View {
    func plozzOpaqueNavigationChrome() -> some View {
        modifier(OpaqueNavigationChromeModifier())
    }
}

private struct OpaqueNavigationChromeModifier: ViewModifier {
    @Environment(\.plozzReduceTransparency) private var reduced
    @Environment(\.accessibilityReduceTransparency) private var systemReduced
    @Environment(\.themePalette) private var palette
    @Environment(\.gradientBackgroundsEnabled) private var gradientEnabled

    func body(content: Content) -> some View {
        let surface = OpaqueNavigationSurface(palette: palette, gradientEnabled: gradientEnabled)
        content.background {
            if #available(iOS 26.0, *) {
                OpaqueNavigationBridge(
                    enabled: reduced && !systemReduced,
                    color: UIColor(surface.fill),
                    border: UIColor(surface.border)
                )
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
    }
}

@available(iOS 26.0, *)
private struct OpaqueNavigationBridge: UIViewControllerRepresentable {
    @MainActor private static let owners = NSMapTable<UINavigationController, NavigationOverride>.weakToWeakObjects()
    let enabled: Bool
    let color: UIColor
    let border: UIColor

    func makeUIViewController(context: Context) -> Controller { Controller() }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.enabled = enabled
        controller.color = color
        controller.border = border
        controller.scheduleUpdate()
    }

    static func dismantleUIViewController(_ controller: Controller, coordinator: ()) {
        controller.restore()
    }

    final class Controller: UIViewController {
        var enabled = false
        var color = UIColor.secondarySystemBackground
        var border = UIColor.separator
        private var pendingUpdate = false
        private var overrides: [ObjectIdentifier: NavigationOverride] = [:]

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            if parent == nil { restore() } else { scheduleUpdate() }
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            scheduleUpdate()
        }

        func scheduleUpdate() {
            guard !pendingUpdate else { return }
            pendingUpdate = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.pendingUpdate = false
                self.update()
            }
        }

        private func update() {
            guard enabled, parent != nil else { restore(); return }
            var ancestor = parent
            while let container = ancestor {
                let navigations = findNavigations(in: container)
                if !navigations.isEmpty {
                    for navigation in navigations {
                        let key = ObjectIdentifier(navigation)
                        if let existing = OpaqueNavigationBridge.owners.object(forKey: navigation),
                           overrides[key] !== existing {
                            continue
                        }
                        let appearance = overrides[key] ?? NavigationOverride(navigation)
                        overrides[key] = appearance
                        OpaqueNavigationBridge.owners.setObject(appearance, forKey: navigation)
                        appearance.apply(color: color, border: border)
                    }
                    break
                }
                ancestor = container.parent
            }
            overrides = overrides.filter { $0.value.navigation != nil }
        }

        private func findNavigations(in controller: UIViewController) -> [UINavigationController] {
            if let navigation = controller as? UINavigationController { return [navigation] }
            return controller.children.filter { $0 !== self }.flatMap { findNavigations(in: $0) }
        }

        func restore() {
            for appearance in overrides.values { appearance.restore() }
            overrides.removeAll()
        }
    }

    @MainActor final class NavigationOverride: NSObject {
        weak var navigation: UINavigationController?
        private var color: UIColor?
        private var border: UIColor?
        private var image: UIImage?
        private var backItems: [ObjectIdentifier: BackSnapshot] = [:]
        private var items: [ObjectIdentifier: ItemSnapshot] = [:]
        private var groups: [GroupSnapshot] = []
        private var updateLink: UIUpdateLink?
        private var applying = false

        init(_ navigation: UINavigationController) {
            self.navigation = navigation
            super.init()
        }

        func apply(color: UIColor, border: UIColor) {
            guard let navigation else { return }
            if self.color != color || self.border != border {
                self.color = color
                self.border = border
                image = UIGraphicsImageRenderer(size: CGSize(width: 45, height: 44)).image { _ in
                    color.withAlphaComponent(1).setFill()
                    UIBezierPath(
                        roundedRect: CGRect(x: 0, y: 0, width: 45, height: 44), cornerRadius: 22
                    ).fill()
                    border.setStroke()
                    let outline = UIBezierPath(
                        roundedRect: CGRect(x: 0.5, y: 0.5, width: 44, height: 43), cornerRadius: 21.5
                    )
                    outline.lineWidth = 1
                    outline.stroke()
                }.resizableImage(withCapInsets: UIEdgeInsets(top: 22, left: 22, bottom: 21, right: 22))
            }
            if updateLink == nil {
                let link = UIUpdateLink(view: navigation.navigationBar) { [weak self] _, _ in
                    self?.update(self?.navigation?.topViewController)
                }
                // Observe existing UI updates, never request a rendering loop.
                link.requiresContinuousUpdates = false
                link.isEnabled = true
                updateLink = link
            }
            update(navigation.topViewController)
        }

        private func update(_ controller: UIViewController?) {
            guard !applying, let navigation, let image, let color, let border else { return }
            applying = true
            defer { applying = false }
            for previous in navigation.viewControllers.dropLast() {
                let owner = previous.navigationItem
                let key = ObjectIdentifier(owner)
                if let existing = backItems[key], !existing.isCurrent {
                    backItems[key] = nil
                }
                let snapshot = backItems[key] ?? BackSnapshot(owner)
                backItems[key] = snapshot
                snapshot.apply(image: image)
            }
            if let item = controller?.navigationItem {
                splitGroups(item, key: \.leadingItemGroups)
                splitGroups(item, key: \.centerItemGroups)
                splitGroups(item, key: \.trailingItemGroups)
                for button in barButtons(in: item) {
                    let key = ObjectIdentifier(button)
                    if let existing = items[key], !existing.hasCurrentCustomView {
                        existing.restore()
                        items[key] = nil
                    }
                    let snapshot = items[key] ?? ItemSnapshot(button)
                    items[key] = snapshot
                    snapshot.apply(color: color, border: border, image: image)
                }
            }
            items = items.filter { $0.value.item != nil }
            pruneRemovedItems()
        }

        private func barButtons(in item: UINavigationItem) -> [UIBarButtonItem] {
            var buttons = item.leftBarButtonItems ?? []
            buttons += item.rightBarButtonItems ?? []
            let groups = item.leadingItemGroups + item.centerItemGroups + item.trailingItemGroups
            buttons += groups.flatMap(\.barButtonItems)
            return buttons
        }

        private func splitGroups(
            _ item: UINavigationItem, key: ReferenceWritableKeyPath<UINavigationItem, [UIBarButtonItemGroup]>
        ) {
            guard item[keyPath: key].contains(where: { $0.barButtonItems.count > 1 }) else { return }
            groups.removeAll { $0.owner === item && $0.key == key }
            let snapshot = GroupSnapshot(item, key: key)
            groups.append(snapshot)
            snapshot.apply()
        }

        func restore() {
            updateLink?.isEnabled = false
            updateLink = nil
            for snapshot in items.values { snapshot.restore() }
            for snapshot in groups { snapshot.restore() }
            for snapshot in backItems.values { snapshot.restore() }
            if !backItems.isEmpty, let navigation, navigation.viewControllers.count > 1,
               let item = navigation.topViewController?.navigationItem,
               !item.hidesBackButton {
                // UIKit caches the rendered Back background even after its item is restored.
                item.setHidesBackButton(true, animated: false)
                navigation.navigationBar.layoutIfNeeded()
                item.setHidesBackButton(false, animated: false)
            }
            items.removeAll()
            groups.removeAll()
            backItems.removeAll()
            if let navigation, OpaqueNavigationBridge.owners.object(forKey: navigation) === self {
                OpaqueNavigationBridge.owners.removeObject(forKey: navigation)
            }
        }

        private func pruneRemovedItems() {
            guard let navigation, navigation.transitionCoordinator == nil else { return }
            let activeItems = navigation.viewControllers.map(\.navigationItem)
            for (key, snapshot) in backItems where !activeItems.contains(where: { $0 === snapshot.owner }) {
                snapshot.restore()
                backItems[key] = nil
            }
            let activeButtons = Set(activeItems.flatMap { barButtons(in: $0) }.map(ObjectIdentifier.init))
            for (key, snapshot) in items where !activeButtons.contains(key) {
                snapshot.restore()
                items[key] = nil
            }
            groups.removeAll { snapshot in
                guard !activeItems.contains(where: { $0 === snapshot.owner }) else { return false }
                snapshot.restore()
                return true
            }
        }

        @MainActor private final class GroupSnapshot {
            weak var owner: UINavigationItem?
            let key: ReferenceWritableKeyPath<UINavigationItem, [UIBarButtonItemGroup]>
            private let originals: [UIBarButtonItemGroup]
            private let buttons: [[UIBarButtonItem]]
            private var replacements: [UIBarButtonItemGroup] = []

            init(_ owner: UINavigationItem, key: ReferenceWritableKeyPath<UINavigationItem, [UIBarButtonItemGroup]>) {
                self.owner = owner
                self.key = key
                originals = owner[keyPath: key]
                buttons = originals.map(\.barButtonItems)
            }

            func apply() {
                // UIKit ignores hidesSharedBackground for a multi-item group.
                replacements = zip(originals, buttons).flatMap { group, items in
                    items.count <= 1 ? [group] : items.map {
                        UIBarButtonItemGroup(barButtonItems: [$0], representativeItem: nil)
                    }
                }
                owner?[keyPath: key] = replacements
            }

            func restore() {
                guard let owner, owner[keyPath: key] == replacements else { return }
                for (group, items) in zip(originals, buttons) { group.barButtonItems = items }
                owner[keyPath: key] = originals
            }
        }

    }

    @MainActor private final class BackSnapshot {
        weak var owner: UINavigationItem?
        private let original: UIBarButtonItem?
        private let replacement: UIBarButtonItem
        var isCurrent: Bool { owner?.backBarButtonItem === replacement }

        init(_ owner: UINavigationItem) {
            self.owner = owner
            original = owner.backBarButtonItem
            replacement = UIBarButtonItem(
                title: original?.title ?? owner.backButtonTitle,
                style: original?.style ?? .plain,
                target: original?.target,
                action: original?.action
            )
            replacement.image = original?.image
            replacement.primaryAction = original?.primaryAction
            replacement.menu = original?.menu
            replacement.tintColor = original?.tintColor
            replacement.isEnabled = original?.isEnabled ?? true
            replacement.accessibilityLabel = original?.accessibilityLabel
            replacement.accessibilityHint = original?.accessibilityHint
        }

        func apply(image: UIImage) {
            if replacement.backButtonBackgroundImage(for: .normal, barMetrics: .default) !== image {
                replacement.setBackButtonBackgroundImage(image, for: .normal, barMetrics: .default)
                replacement.setBackButtonBackgroundImage(image, for: .highlighted, barMetrics: .default)
            }
            if !isCurrent { owner?.backBarButtonItem = replacement }
        }

        func restore() {
            if isCurrent { owner?.backBarButtonItem = original }
        }
    }

    @MainActor private final class ItemSnapshot {
        weak var item: UIBarButtonItem?
        private weak var customView: UIView?
        private let hidesSharedBackground: Bool
        private let backgroundImage: UIImage?
        private let backgroundColor: UIColor?
        private let cornerRadius: CGFloat
        private let borderColor: CGColor?
        private let borderWidth: CGFloat
        private var constraints: [NSLayoutConstraint] = []
        var hasCurrentCustomView: Bool { item?.customView === customView }

        init(_ item: UIBarButtonItem) {
            self.item = item
            customView = item.customView
            hidesSharedBackground = item.hidesSharedBackground
            backgroundImage = item.backgroundImage(for: .normal, barMetrics: .default)
            backgroundColor = item.customView?.backgroundColor
            cornerRadius = item.customView?.layer.cornerRadius ?? 0
            borderColor = item.customView?.layer.borderColor
            borderWidth = item.customView?.layer.borderWidth ?? 0
        }

        func apply(color: UIColor, border: UIColor, image: UIImage) {
            guard let item else { return }
            if !item.hidesSharedBackground { item.hidesSharedBackground = true }
            if item.backgroundImage(for: .normal, barMetrics: .default) !== image {
                item.setBackgroundImage(image, for: .normal, barMetrics: .default)
            }
            if let customView {
                if constraints.isEmpty {
                    constraints = [
                        customView.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
                        customView.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
                    ]
                    NSLayoutConstraint.activate(constraints)
                }
                let opaque = color.withAlphaComponent(1)
                if customView.backgroundColor != opaque { customView.backgroundColor = opaque }
                let radius = max(44, customView.bounds.height) / 2
                if customView.layer.cornerRadius != radius { customView.layer.cornerRadius = radius }
                if customView.layer.borderColor != border.cgColor { customView.layer.borderColor = border.cgColor }
                if customView.layer.borderWidth != 1 { customView.layer.borderWidth = 1 }
            }
        }

        func restore() {
            item?.hidesSharedBackground = hidesSharedBackground
            item?.setBackgroundImage(backgroundImage, for: .normal, barMetrics: .default)
            customView?.backgroundColor = backgroundColor
            customView?.layer.cornerRadius = cornerRadius
            customView?.layer.borderColor = borderColor
            customView?.layer.borderWidth = borderWidth
            NSLayoutConstraint.deactivate(constraints)
            constraints.removeAll()
        }
    }
}

public struct PlozzOpaqueTabBar<Item: Hashable, ItemLabel: View>: View {
    private let items: [Item]
    @Binding private var selection: Item
    private let label: (Item) -> ItemLabel
    @Environment(\.themePalette) private var palette
    @Environment(\.gradientBackgroundsEnabled) private var gradientEnabled

    private var surface: OpaqueNavigationSurface {
        OpaqueNavigationSurface(palette: palette, gradientEnabled: gradientEnabled, bottom: true)
    }

    public init(
        items: [Item], selection: Binding<Item>, @ViewBuilder label: @escaping (Item) -> ItemLabel
    ) {
        self.items = items
        _selection = selection
        self.label = label
    }

    public var body: some View {
        ViewThatFits(in: .horizontal) {
            buttons
            ScrollView(.horizontal) { buttons }
                .scrollIndicators(.hidden)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("opaque-navigation-overflow")
        }
        .padding(6)
        .background(surface.fill, in: Capsule())
        .overlay { Capsule().strokeBorder(surface.border, lineWidth: 1) }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var buttons: some View {
        HStack(spacing: 4) {
            ForEach(items, id: \.self) { item in
                Button { selection = item } label: {
                    label(item)
                        .labelStyle(OpaqueTabLabelStyle())
                        .foregroundStyle(selection == item ? surface.selectionForeground : palette.primaryText)
                        .frame(minWidth: 44, minHeight: 44)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .background(selection == item ? surface.selection : surface.fill, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == item ? .isSelected : [])
            }
        }
    }
}

private struct OpaqueTabLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(spacing: 2) {
            configuration.icon.font(.body)
            configuration.title.font(.caption2).lineLimit(1)
        }
    }
}
#endif
