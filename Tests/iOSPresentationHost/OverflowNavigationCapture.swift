import Foundation
import UIKit

@MainActor
enum OverflowNavigationCapture {
    static func captureTabs(selecting title: String?) async throws {
        let deadline = ContinuousClock.now + .seconds(8)
        while ContinuousClock.now < deadline {
            if let root = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                .flatMap(\.windows).first(where: \.isKeyWindow)?.rootViewController,
               let tabs = findTabs(in: root),
               max(tabs.tabs.count, tabs.viewControllers?.count ?? 0) > 0 {
                if let title {
                    if let tab = tabs.tabs.first(where: { $0.title == title }) {
                        tabs.selectedTab = tab
                    } else if let controller = tabs.viewControllers?.first(where: { $0.tabBarItem.title == title }) {
                        tabs.selectedViewController = controller
                    } else {
                        try await Task.sleep(for: .milliseconds(50))
                        continue
                    }
                }
                try await Task.sleep(for: .seconds(1))
                let report: [String: Any] = [
                    "processIdentifier": ProcessInfo.processInfo.processIdentifier,
                    "nativeTabs": tabs.tabs.map(\.title),
                    "legacyTabs": (tabs.viewControllers ?? []).compactMap(\.tabBarItem.title),
                    "tabBarItems": (tabs.tabBar.items ?? []).compactMap(\.title),
                    "selectedTab": tabs.selectedTab?.title ?? ""
                ]
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(
                    to: URL.documentsDirectory.appendingPathComponent("navigation-tabs-capture.json")
                )
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw CaptureError.rowUnavailable
    }

    static func openRow(named title: String) async throws {
        let deadline = ContinuousClock.now + .seconds(8)
        while ContinuousClock.now < deadline {
            if let root = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                .flatMap(\.windows).first(where: \.isKeyWindow)?.rootViewController,
               let tabs = findTabs(in: root),
               max(tabs.tabs.count, tabs.viewControllers?.count ?? 0) > 5 {
                let more = tabs.moreNavigationController
                tabs.selectedViewController = more
                more.view.layoutIfNeeded()
                if let table = more.viewControllers.first.flatMap({ findTable(in: $0.view) }) {
                    for row in 0..<table.numberOfRows(inSection: 0) {
                        let indexPath = IndexPath(row: row, section: 0)
                        guard let cell = table.cellForRow(at: indexPath),
                              labels(in: cell).contains(title) else { continue }
                        guard let delegate = table.delegate else { break }
                        let selected: IndexPath
                        if delegate.responds(to: #selector(UITableViewDelegate.tableView(_:willSelectRowAt:))) {
                            guard let allowed = delegate.tableView?(table, willSelectRowAt: indexPath) else {
                                throw CaptureError.selectionRejected
                            }
                            selected = allowed
                        } else {
                            selected = indexPath
                        }
                        table.selectRow(at: selected, animated: false, scrollPosition: .none)
                        delegate.tableView?(table, didSelectRowAt: selected)
                        try await Task.sleep(for: .seconds(1))
                        let report: [String: Any] = [
                            "processIdentifier": ProcessInfo.processInfo.processIdentifier,
                            "destination": title,
                            "moreStack": more.viewControllers.map { String(describing: type(of: $0)) },
                            "moreDelegate": String(describing: more.delegate),
                            "outerBarHidden": more.isNavigationBarHidden,
                            "topMatchesTab": (tabs.viewControllers ?? []).map { $0 === more.topViewController },
                            "tabTypes": (tabs.viewControllers ?? []).map { String(describing: type(of: $0)) },
                            "nativeTabs": tabs.tabs.map(\.title),
                            "topMatchesNativeTab": tabs.tabs.map { $0.viewController === more.topViewController }
                        ]
                        let url = URL.documentsDirectory.appendingPathComponent("overflow-navigation-capture.json")
                        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: url)
                        if ProcessInfo.processInfo.arguments.contains("--navigation-more-round-trip") {
                            more.popToRootViewController(animated: true)
                            try await Task.sleep(for: .seconds(1))
                            guard more.viewControllers.count == 1, !more.isNavigationBarHidden else {
                                throw CaptureError.returnToMoreFailed
                            }
                            try Data("Returned to the native More bar\n".utf8).write(
                                to: URL.documentsDirectory.appendingPathComponent("overflow-navigation-return.txt")
                            )
                        }
                        return
                    }
                }
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw CaptureError.rowUnavailable
    }

    private static func findTabs(in controller: UIViewController) -> UITabBarController? {
        if let tabs = controller as? UITabBarController { return tabs }
        return controller.children.lazy.compactMap { findTabs(in: $0) }.first
    }

    private static func findTable(in view: UIView) -> UITableView? {
        if let table = view as? UITableView { return table }
        return view.subviews.lazy.compactMap { findTable(in: $0) }.first
    }

    private static func labels(in view: UIView) -> [String] {
        (view as? UILabel).flatMap(\.text).map { [$0] } ?? view.subviews.flatMap { labels(in: $0) }
    }

    private enum CaptureError: Error {
        case rowUnavailable
        case selectionRejected
        case returnToMoreFailed
    }
}
