#if os(tvOS)
import CoreUI
import FeatureLiveTVCore
import Observation
import SwiftUI
import UIKit

@MainActor
final class PrototypeGuideScrollController {
    fileprivate weak var collection: UICollectionView?
    fileprivate var indices: [LiveTVGuideRowID: Int] = [:]

    func scrollTo(_ row: LiveTVGuideRowID, anchor: UnitPoint) {
        guard let collection, let index = indices[row] else { return }
        collection.layoutIfNeeded()
        collection.scrollToItem(
            at: IndexPath(item: index, section: 0),
            at: anchor == .top ? .top : .centeredVertically, animated: false)
    }
}

/// Guide rows have explicit heights. Compute only the requested frames instead
/// of asking a self-sizing compositional layout to prepare the entire catalog.
@MainActor
final class PrototypeGuideCollectionLayout: UICollectionViewLayout {
    private var rowCount = 0
    private var rowHeight: CGFloat = PrototypeLayout.rowHeight + PrototypeLayout.rowGap
    private var sectionHeight: CGFloat = 0
    private var sectionStarts: [Int] = []

    func update(rowCount: Int, rowHeight: CGFloat, sectionHeight: CGFloat, sectionStarts: [Int]) {
        guard self.rowCount != rowCount || self.rowHeight != rowHeight
                || self.sectionHeight != sectionHeight || self.sectionStarts != sectionStarts else { return }
        self.rowCount = rowCount
        self.rowHeight = rowHeight
        self.sectionHeight = sectionHeight
        self.sectionStarts = sectionStarts
        invalidateLayout()
    }

    override var collectionViewContentSize: CGSize {
        CGSize(
            width: collectionView?.bounds.width ?? 0,
            height: PrototypeLayout.smallGap + CGFloat(rowCount) * rowHeight
                + CGFloat(sectionStarts.count) * sectionHeight
        )
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard indexPath.section == 0, (0..<rowCount).contains(indexPath.item) else { return nil }
        let attributes = UICollectionViewLayoutAttributes(forCellWith: indexPath)
        attributes.frame = frame(at: indexPath.item)
        return attributes
    }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        guard rowCount > 0, !rect.isEmpty else { return [] }
        var lower = 0
        var upper = rowCount
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if frame(at: middle).maxY <= rect.minY { lower = middle + 1 }
            else { upper = middle }
        }
        var result: [UICollectionViewLayoutAttributes] = []
        var index = lower
        while index < rowCount {
            let frame = frame(at: index)
            guard frame.minY < rect.maxY else { break }
            if frame.intersects(rect) {
                let attributes = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: index, section: 0))
                attributes.frame = frame
                result.append(attributes)
            }
            index += 1
        }
        return result
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        newBounds.width != collectionView?.bounds.width
    }

    private func frame(at index: Int) -> CGRect {
        var lower = 0
        var upper = sectionStarts.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if sectionStarts[middle] < index { lower = middle + 1 }
            else { upper = middle }
        }
        let isSectionStart = lower < sectionStarts.count && sectionStarts[lower] == index
        return CGRect(
            x: 0, y: PrototypeLayout.smallGap + CGFloat(index) * rowHeight + CGFloat(lower) * sectionHeight,
            width: collectionView?.bounds.width ?? 0,
            height: rowHeight + (isSectionStart ? sectionHeight : 0)
        )
    }
}

/// UIKit recycles real visible rows instead of creating SwiftUI's catalog-wide
/// virtual focus fillers. The guide's existing row content still owns its controls.
struct PrototypeNativeGuideList<Revision: Equatable, Content: View>: UIViewControllerRepresentable {
    let rows: [LiveTVGuideRowID]
    var rowHeight: CGFloat = PrototypeLayout.rowHeight + PrototypeLayout.rowGap
    var sectionHeight: CGFloat = PrototypeLayout.guideSectionLabelHeight(fontSize: PrototypeLayout.sectionFontSize)
        + PrototypeLayout.smallGap + PrototypeLayout.sectionLabelGap
    let scrollController: PrototypeGuideScrollController
    let scrolled: (LiveTVGuideRowID?, CGFloat) -> Void
    let revision: (LiveTVGuideRowID) -> Revision
    var horizontalNavigation: () -> Void = {}
    var leadingExit: (() -> Void)?
    var isLeadingColumnFocused = false
    @ViewBuilder let content: (LiveTVGuideRowID) -> Content

    struct RowEnvironment: Equatable {
        let palette: ThemePalette
        let reduceTransparency: Bool
        let colorScheme: ColorScheme
        let contrast: ColorSchemeContrast
        let direction: LayoutDirection
        let dynamicType: DynamicTypeSize
        let locale: Locale
        let calendar: Calendar
        let timeZone: TimeZone
        let isEnabled: Bool

        init(_ environment: EnvironmentValues) {
            palette = environment.themePalette
            reduceTransparency = environment.plozzReduceTransparency
            colorScheme = environment.colorScheme
            contrast = environment.colorSchemeContrast
            direction = environment.layoutDirection
            dynamicType = environment.dynamicTypeSize
            locale = environment.locale
            calendar = environment.calendar
            timeZone = environment.timeZone
            isEnabled = environment.isEnabled
        }
    }

    @MainActor
    @Observable
    final class RowState {
        let id: LiveTVGuideRowID
        var content: Content
        var environment: RowEnvironment
        @ObservationIgnored var revision: Revision

        init(id: LiveTVGuideRowID, content: Content, environment: RowEnvironment, revision: Revision) {
            self.id = id
            self.content = content
            self.environment = environment
            self.revision = revision
        }
    }

    struct HostedRow: View {
        let state: RowState

        var body: some View {
            // Preserve presentation values without copying another hosting
            // controller's private focus/scroll environment into this row.
            state.content.id(state.id)
                .environment(\.themePalette, state.environment.palette)
                .environment(\.plozzReduceTransparency, state.environment.reduceTransparency)
                .environment(\.colorScheme, state.environment.colorScheme)
                .environment(\.layoutDirection, state.environment.direction)
                .environment(\.dynamicTypeSize, state.environment.dynamicType)
                .environment(\.locale, state.environment.locale)
                .environment(\.calendar, state.environment.calendar)
                .environment(\.timeZone, state.environment.timeZone)
                .environment(\.isEnabled, state.environment.isEnabled)
        }
    }

    func makeUIViewController(context: Context) -> Controller {
        let controller = Controller()
        controller.parentView = self
        controller.swiftUIEnvironment = context.environment
        controller.loadViewIfNeeded()
        return controller
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.update(self, environment: context.environment)
    }

    static func dismantleUIViewController(_ controller: Controller, coordinator: ()) {
        controller.collectionView.delegate = nil
        controller.collectionView.dataSource = nil
        controller.parentView?.scrollController.collection = nil
        controller.parentView = nil
        controller.swiftUIEnvironment = nil
        for child in controller.children {
            child.willMove(toParent: nil)
            child.removeFromParent()
        }
    }

    final class Controller: UICollectionViewController {
        var parentView: PrototypeNativeGuideList?
        var swiftUIEnvironment: EnvironmentValues?
        private var rowIDs: [LiveTVGuideRowID] = []
        private var sectionStarts: [Int] = []
        private var scrollReportScheduled = false
        private var isRequestingLeadingExit = false
        private let guideLayout: PrototypeGuideCollectionLayout

        init() {
            let layout = PrototypeGuideCollectionLayout()
            guideLayout = layout
            super.init(collectionViewLayout: layout)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .clear
            collectionView.backgroundColor = .clear
            collectionView.showsVerticalScrollIndicator = false
            collectionView.allowsSelection = false
            // Remembering a cell redirects directional moves to its first
            // descendant, instead of preserving the guide's content column.
            collectionView.remembersLastFocusedIndexPath = false
            collectionView.contentInsetAdjustmentBehavior = .never
            collectionView.register(Cell.self, forCellWithReuseIdentifier: "guide-row")
            collectionView.addGestureRecognizer(GuideHorizontalPressRecognizer(
                onHorizontal: { [weak self] in self?.parentView?.horizontalNavigation() },
                leadingExit: { [weak self] type in
                    guard let self, let parentView, parentView.isLeadingColumnFocused,
                          type == (swiftUIEnvironment?.layoutDirection == .rightToLeft ? .rightArrow : .leftArrow)
                    else { return nil }
                    return parentView.leadingExit
                }
            ))
            if let parentView, let swiftUIEnvironment { update(parentView, environment: swiftUIEnvironment) }
        }

        func update(_ parent: PrototypeNativeGuideList, environment: EnvironmentValues) {
            parentView = parent
            if parent.leadingExit == nil { isRequestingLeadingExit = false }
            swiftUIEnvironment = environment
            parent.scrollController.collection = collectionView
            if rowIDs != parent.rows {
                rowIDs = parent.rows
                sectionStarts = rowIDs.indices.filter {
                    $0 > 0 && rowIDs[$0].section != rowIDs[$0 - 1].section
                }
                parent.scrollController.indices = Dictionary(uniqueKeysWithValues: rowIDs.enumerated().map { ($0.element, $0.offset) })
                collectionView.reloadData()
            } else {
                for case let cell as Cell in collectionView.visibleCells {
                    guard let path = collectionView.indexPath(for: cell), rowIDs.indices.contains(path.item) else { continue }
                    configure(cell, row: rowIDs[path.item])
                }
            }
            guideLayout.update(
                rowCount: rowIDs.count, rowHeight: parent.rowHeight,
                sectionHeight: parent.sectionHeight, sectionStarts: sectionStarts
            )
            reportScroll()
        }

        override func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { rowIDs.count }

        override func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
            guard let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "guide-row", for: indexPath) as? Cell else {
                preconditionFailure("Expected native guide row cell")
            }
            configure(cell, row: rowIDs[indexPath.item])
            return cell
        }

        override func collectionView(
            _ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath
        ) {
            guard let host = (cell as? Cell)?.host, host.parent == nil else { return }
            addChild(host)
            host.didMove(toParent: self)
        }

        override func collectionView(
            _ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell, forItemAt indexPath: IndexPath
        ) {
            guard let host = (cell as? Cell)?.host, host.parent === self else { return }
            host.willMove(toParent: nil)
            host.removeFromParent()
        }

        override func scrollViewDidScroll(_ scrollView: UIScrollView) { reportScroll() }

        override func shouldUpdateFocus(in context: UIFocusUpdateContext) -> Bool {
            let leading: UIFocusHeading = swiftUIEnvironment?.layoutDirection == .rightToLeft ? .right : .left
            if context.focusHeading == leading,
               context.previouslyFocusedView?.isDescendant(of: collectionView) == true,
               context.nextFocusedView?.isDescendant(of: collectionView) != true,
               parentView?.leadingExit != nil {
                if !isRequestingLeadingExit {
                    isRequestingLeadingExit = true
                    DispatchQueue.main.async { [weak self] in self?.parentView?.leadingExit?() }
                }
                return false
            }
            return super.shouldUpdateFocus(in: context)
        }

        override func collectionView(
            _ collectionView: UICollectionView, didUpdateFocusIn context: UICollectionViewFocusUpdateContext,
            with coordinator: UIFocusAnimationCoordinator
        ) {
            guard context.focusHeading == .left || context.focusHeading == .right,
                  let previous = context.previouslyFocusedIndexPath,
                  previous == context.nextFocusedIndexPath else { return }
            parentView?.horizontalNavigation()
        }

        private func configure(_ cell: Cell, row: LiveTVGuideRowID) {
            guard let parentView, let swiftUIEnvironment else { return }
            let revision = parentView.revision(row)
            let environment = RowEnvironment(swiftUIEnvironment)
            if let state = cell.rowState, state.id == row {
                if state.revision != revision {
                    state.revision = revision
                    state.content = parentView.content(row)
                }
                state.environment = environment
            } else {
                let state = RowState(
                    id: row, content: parentView.content(row), environment: environment, revision: revision)
                if let host = cell.host {
                    host.rootView = HostedRow(state: state)
                } else {
                    let host = UIHostingController(rootView: HostedRow(state: state))
                    // Overscan insets change as a cell scrolls across screen
                    // edges; they must not resize or shift guide controls.
                    host.safeAreaRegions = []
                    host.sizingOptions = [.intrinsicContentSize]
                    host.view.backgroundColor = .clear
                    host.view.translatesAutoresizingMaskIntoConstraints = false
                    cell.contentView.addSubview(host.view)
                    NSLayoutConstraint.activate([
                        host.view.leadingAnchor.constraint(equalTo: cell.contentView.leadingAnchor),
                        host.view.trailingAnchor.constraint(equalTo: cell.contentView.trailingAnchor),
                        host.view.topAnchor.constraint(equalTo: cell.contentView.topAnchor),
                        host.view.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor)
                    ])
                    cell.host = host
                }
                cell.rowState = state
            }
        }

        private func reportScroll() {
            guard !scrollReportScheduled else { return }
            scrollReportScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.scrollReportScheduled = false
                guard let parentView = self.parentView else { return }
                let first = self.collectionView.indexPathsForVisibleItems.map(\.item).min()
                let row = first.flatMap { self.rowIDs.indices.contains($0) ? self.rowIDs[$0] : nil }
                parentView.scrolled(row, self.collectionView.contentOffset.y + self.collectionView.adjustedContentInset.top)
            }
        }
    }

    final class Cell: UICollectionViewCell {
        var host: UIHostingController<HostedRow>?
        var rowState: RowState?
        override var canBecomeFocused: Bool { false }

        override func preferredLayoutAttributesFitting(_ layoutAttributes: UICollectionViewLayoutAttributes) -> UICollectionViewLayoutAttributes {
            layoutAttributes
        }

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .clear
            contentView.backgroundColor = .clear
            preservesSuperviewLayoutMargins = false
            insetsLayoutMarginsFromSafeArea = false
            layoutMargins = .zero
            contentView.preservesSuperviewLayoutMargins = false
            contentView.layoutMargins = .zero
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    }
}

private final class GuideHorizontalPressRecognizer: UIGestureRecognizer {
    private let onHorizontal: () -> Void
    private let leadingExit: (UIPress.PressType) -> (() -> Void)?
    private var consumedPress: UIPress?
    private var exitAction: (() -> Void)?

    init(
        onHorizontal: @escaping () -> Void,
        leadingExit: @escaping (UIPress.PressType) -> (() -> Void)?
    ) {
        self.onHorizontal = onHorizontal
        self.leadingExit = leadingExit
        super.init(target: nil, action: nil)
        allowedPressTypes = [
            NSNumber(value: UIPress.PressType.leftArrow.rawValue),
            NSNumber(value: UIPress.PressType.rightArrow.rawValue)
        ]
        allowedTouchTypes = []
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { consumedPress != nil }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent) {
        guard let press = presses.first(where: { $0.type == .leftArrow || $0.type == .rightArrow }),
              DetailTransitionNavigation.navigationInputEpoch(in: view) != nil else {
            state = .failed
            return
        }
        onHorizontal()
        guard let action = leadingExit(press.type) else {
            state = .failed
            return
        }
        // Own this press through release so the native tab sidebar cannot also open.
        consumedPress = press
        exitAction = action
        state = .began
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent) {
        guard let consumedPress, presses.contains(where: { $0 === consumedPress }) else { return }
        let action = exitAction
        state = .ended
        action?()
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent) {
        state = .cancelled
    }

    override func reset() {
        consumedPress = nil
        exitAction = nil
        super.reset()
    }
}
#endif
