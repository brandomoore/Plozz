import CoreUI
import FeatureShareOnboarding
import SwiftUI
import UIKit

struct ShareLocationList: View {
    let locations: [UnifiedAddShareModel.LocationItem]
    let onSelect: (UnifiedAddShareModel.LocationItem) -> Void

    @State private var viewport = Viewport()

    var body: some View {
        NativeList(
            locations: locations, onSelect: onSelect, onViewport: { viewport = $0 }
        )
        .frame(height: viewport.height > 0 ? viewport.height : 620)
        // Reserve space inside native cells for the shared focus card and shadow,
        // without narrowing the rows or clipping their horizontal overflow.
        .padding(.horizontal, -32)
        .mask(VerticalEdgeFadeMask(
            topFade: viewport.top ? 34 : 0,
            bottomFade: viewport.bottom ? 34 : 0,
            horizontalOverhang: 400
        ))
    }

    fileprivate struct Viewport: Equatable {
        var height: CGFloat = 620
        var top = false
        var bottom = false
    }
}

private struct NativeList: UIViewRepresentable {
    let locations: [UnifiedAddShareModel.LocationItem]
    let onSelect: (UnifiedAddShareModel.LocationItem) -> Void
    let onViewport: (ShareLocationList.Viewport) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> FolderTableView {
        context.coordinator.environment = context.environment
        let table = FolderTableView(frame: .zero, style: .plain)
        table.backgroundColor = .clear
        table.clipsToBounds = false
        table.showsVerticalScrollIndicator = false
        table.contentInsetAdjustmentBehavior = .never
        table.contentInset = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        table.rowHeight = UITableView.automaticDimension
        table.estimatedRowHeight = 80
        table.register(UITableViewCell.self, forCellReuseIdentifier: "folder")
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.onLayout = { [weak coordinator = context.coordinator] table in
            coordinator?.reportViewport(table)
        }
        return table
    }

    func updateUIView(_ table: FolderTableView, context: Context) {
        let previous = context.coordinator.parent
        context.coordinator.parent = self
        context.coordinator.environment = context.environment
        if previous.locations != locations {
            table.reloadData()
        } else {
            for cell in table.visibleCells { cell.setNeedsUpdateConfiguration() }
        }
    }

    static func dismantleUIView(_ table: FolderTableView, coordinator: Coordinator) {
        table.onLayout = nil
        table.delegate = nil
        table.dataSource = nil
    }

    @MainActor
    final class Coordinator: NSObject, UITableViewDataSource, UITableViewDelegate {
        var parent: NativeList
        var environment = EnvironmentValues()
        private var lastViewport: ShareLocationList.Viewport?

        init(_ parent: NativeList) { self.parent = parent }

        func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
            parent.locations.count
        }

        func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
            let cell = tableView.dequeueReusableCell(withIdentifier: "folder", for: indexPath)
            let item = parent.locations[indexPath.row]
            cell.backgroundColor = .clear
            cell.selectionStyle = .none
            cell.focusStyle = .custom
            cell.clipsToBounds = false
            cell.contentView.clipsToBounds = false
            cell.isAccessibilityElement = true
            cell.accessibilityLabel = item.name
            cell.accessibilityIdentifier = "share-location:\(item.path)"
            cell.accessibilityTraits = .button
            cell.configurationUpdateHandler = { [weak self] cell, state in
                guard let self else { return }
                cell.contentConfiguration = UIHostingConfiguration {
                    SettingsFocusRow(isFocused: state.isFocused, isPressed: state.isHighlighted, size: .prominent) {
                        HStack(spacing: 16) {
                            Image(systemName: item.isBrowsable ? "folder.fill" : "externaldrive.fill")
                                .plozzForeground(.secondary)
                            Text(item.name).font(.headline)
                            Spacer(minLength: 12)
                            Image(systemName: "chevron.forward").plozzForeground(.tertiary)
                        }
                        .padding(.vertical, 10)
                        .padding(.horizontal, 12)
                    }
                    .environment(\.self, self.environment)
                }
                .minSize(width: 0, height: 0)
                .margins(.horizontal, 32)
                .margins(.vertical, 6)
                .background(Color.clear)
            }
            cell.setNeedsUpdateConfiguration()
            return cell
        }

        func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
            parent.onSelect(parent.locations[indexPath.row])
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) { reportViewport(scrollView) }

        func reportViewport(_ scrollView: UIScrollView) {
            let value = ShareLocationList.Viewport(
                height: min(620, scrollView.contentSize.height + scrollView.contentInset.top + scrollView.contentInset.bottom),
                top: scrollView.contentOffset.y + scrollView.contentInset.top > 2,
                bottom: scrollView.contentOffset.y + scrollView.bounds.height
                    < scrollView.contentSize.height + scrollView.contentInset.bottom - 2
            )
            guard value != lastViewport else { return }
            lastViewport = value
            DispatchQueue.main.async { [weak self] in self?.parent.onViewport(value) }
        }
    }
}

private final class FolderTableView: UITableView {
    var onLayout: ((FolderTableView) -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?(self)
    }
}
