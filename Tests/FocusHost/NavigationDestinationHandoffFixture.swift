import CoreModels
import CoreUI
import Observation
import SwiftUI
import UIKit
@testable import AppShell

struct NavigationDestinationHandoffFixture: View {
    @State private var model = NavigationDestinationHandoffFixtureModel()

    var body: some View {
        NavigationRailShell(
            profile: model.profile,
            entries: model.entries,
            destinations: [.home, .music] + model.entries.map(\.destination) + [.settings],
            selection: Binding(
                get: { model.requested },
                set: { model.select($0) }
            ),
            onOpenProfileSwitcher: {},
            chrome: model.chrome,
            content: NavigationHandoffFixturePage(model: model),
            contentDestination: model.presented
        )
        .background(NavigationHandoffProfileFocusObserver { model.profileFocusCount += 1 })
        .task(id: model.requested) {
            await model.finishLoading()
        }
        .onPlayPauseCommand { model.releaseHeldPage() }
    }
}

@MainActor
@Observable
private final class NavigationDestinationHandoffFixtureModel {
    let profile = Profile(name: "Viewer")
    let chrome = NavigationChromeModel()
    let entries: [NavigationRailLibraryEntry] = {
        guard ProcessInfo.processInfo.arguments.contains("--navigation-long-rail") else { return [] }
        return (0..<12).map { index in
            let library = AggregatedLibrary(
                accountID: "fixture", accountName: "Fixture", serverName: "Fixture", providerKind: .jellyfin,
                library: MediaLibrary(id: "\(index)", title: "Library \(index)", kind: .movie)
            )
            return NavigationRailLibraryEntry(key: library.key, library: library)
        }
    }()
    var requested = NavigationRailDestination.home
    var presented = NavigationRailDestination.home
    var prematureFocusCount = 0
    var laterCardFocusCount = 0
    var contentFocusCount = 0
    var profileFocusCount = 0
    private let holdsPages = ProcessInfo.processInfo.arguments.contains("--manual-navigation-handoff")

    func select(_ destination: NavigationRailDestination) {
        prematureFocusCount = 0
        laterCardFocusCount = 0
        contentFocusCount = 0
        profileFocusCount = 0
        requested = destination
        if ProcessInfo.processInfo.arguments.contains("--navigation-immediate-page") {
            presented = destination
        }
    }

    func focused(_ destination: NavigationRailDestination) {
        contentFocusCount += 1
        if destination != requested { prematureFocusCount += 1 }
    }

    func finishLoading() async {
        let destination = requested
        guard destination != presented, !holdsPages else { return }
        do { try await Task.sleep(for: .milliseconds(750)) }
        catch is CancellationError { return }
        catch {
            assertionFailure("Fixture loading failed: \(error)")
            return
        }
        guard !Task.isCancelled, requested == destination else { return }
        presented = destination
    }

    func releaseHeldPage() {
        if holdsPages { presented = requested }
    }
}

private struct NavigationHandoffFixturePage: View {
    let model: NavigationDestinationHandoffFixtureModel

    var body: some View {
        VStack(spacing: 40) {
            if ProcessInfo.processInfo.arguments.contains("--navigation-card-row") {
                HStack(spacing: 40) {
                    NavigationHandoffFixtureButton(destination: model.presented, onFocus: model.focused)
                        .frame(width: 240, height: 160)
                    NavigationHandoffFixtureButton(
                        destination: model.presented, suffix: "-second", onFocus: {
                            model.focused($0)
                            model.laterCardFocusCount += 1
                        }
                    )
                    .frame(width: 240, height: 160)
                    NavigationHandoffFixtureButton(
                        destination: model.presented, suffix: "-third", onFocus: {
                            model.focused($0)
                            model.laterCardFocusCount += 1
                        }
                    )
                    .frame(width: 240, height: 160)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 80)
                .id(model.presented)
            } else {
                NavigationHandoffFixtureButton(destination: model.presented, onFocus: model.focused)
                    .frame(width: 500, height: 90)
                    .id(model.presented)
            }
            Text("Ready \(model.presented.storageValue)")
            Text("\(model.prematureFocusCount)")
                .accessibilityIdentifier("handoff-premature-focus")
            Text("\(model.laterCardFocusCount)")
                .accessibilityIdentifier("handoff-later-card-focus")
            Text("\(model.contentFocusCount)")
                .accessibilityIdentifier("handoff-content-focus")
            Text("\(model.profileFocusCount)")
                .accessibilityIdentifier("handoff-profile-focus")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
    }
}

private struct NavigationHandoffProfileFocusObserver: UIViewRepresentable {
    let onProfileFocus: () -> Void

    func makeUIView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: ObserverView, context: Context) {
        view.onProfileFocus = onProfileFocus
    }

    final class ObserverView: UIView {
        var onProfileFocus: (() -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            guard window != nil else { return }
            NotificationCenter.default.addObserver(
                self, selector: #selector(focusDidUpdate(_:)),
                name: UIFocusSystem.didUpdateNotification, object: nil
            )
        }

        @objc private func focusDidUpdate(_ notification: Notification) {
            guard let window,
                  let context = notification.userInfo?[UIFocusSystem.focusUpdateContextUserInfoKey]
                    as? UIFocusUpdateContext,
                  let item = context.nextFocusedItem,
                  let frame = NavigationRowFocusRequester.frame(of: item, relativeTo: window),
                  let profile = rowMarkers(in: window).min(by: {
                      $0.convert($0.bounds, to: window).midY < $1.convert($1.bounds, to: window).midY
                  }) else { return }
            let marker = profile.convert(profile.bounds, to: window)
            if frame.contains(CGPoint(x: marker.midX, y: marker.midY)) { onProfileFocus?() }
        }

        private func rowMarkers(in view: UIView) -> [NavigationRowFocusRequester.RequestView] {
            if let marker = view as? NavigationRowFocusRequester.RequestView { return [marker] }
            return view.subviews.flatMap { rowMarkers(in: $0) }
        }

        deinit { NotificationCenter.default.removeObserver(self) }
    }
}

private struct NavigationHandoffFixtureButton: UIViewRepresentable {
    let destination: NavigationRailDestination
    var suffix = ""
    let onFocus: (NavigationRailDestination) -> Void

    func makeUIView(context: Context) -> Button {
        let button = Button(type: .system)
        button.setTitle("Page \(destination.storageValue)", for: .normal)
        button.accessibilityIdentifier = "handoff-page-\(destination.storageValue)\(suffix)"
        return button
    }

    func updateUIView(_ button: Button, context: Context) {
        button.isEnabled = context.environment.isEnabled
        button.onFocus = { onFocus(destination) }
    }

    final class Button: UIButton {
        var onFocus: (() -> Void)?

        override func didUpdateFocus(
            in context: UIFocusUpdateContext,
            with coordinator: UIFocusAnimationCoordinator
        ) {
            super.didUpdateFocus(in: context, with: coordinator)
            if context.nextFocusedView === self { onFocus?() }
        }
    }
}
