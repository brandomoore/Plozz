#if os(tvOS)
import CoreModels
import Observation
import SwiftUI
import UIKit

@MainActor
@Observable
final class NavigationDestinationFocusHandoff {
    struct Request: Equatable {
        let destination: NavigationRailDestination
        let generation: UInt64
    }

    private(set) var request: Request?
    @ObservationIgnored private var generation: UInt64 = 0

    var isWaiting: Bool { request != nil }

    func begin(_ destination: NavigationRailDestination) {
        guard request?.destination != destination else { return }
        generation &+= 1
        request = Request(destination: destination, generation: generation)
    }

    func complete(_ presented: Request) -> Bool {
        guard request == presented else { return false }
        request = nil
        return true
    }

    func cancel() {
        request = nil
    }
}

/// Reports the content's actual presentation, not the earlier selection write.
struct NavigationDestinationPresentationAnchor: UIViewControllerRepresentable {
    let destination: NavigationRailDestination
    let request: NavigationDestinationFocusHandoff.Request?
    let onPresented: (NavigationDestinationFocusHandoff.Request) -> Void

    func makeUIViewController(context: Context) -> Controller {
        Controller()
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.update(
            request: request?.destination == destination ? request : nil,
            onPresented: onPresented
        )
    }

    static func dismantleUIViewController(_ controller: Controller, coordinator: ()) {
        controller.update(request: nil, onPresented: nil)
    }

    final class Controller: UIViewController {
        private var request: NavigationDestinationFocusHandoff.Request?
        private var onPresented: ((NavigationDestinationFocusHandoff.Request) -> Void)?
        private var hasAppeared = false
        private var displayLink: CADisplayLink?
        private var crossedFrame = false

        override func loadView() {
            let marker = UIView()
            marker.isUserInteractionEnabled = false
            marker.isAccessibilityElement = false
            view = marker
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            hasAppeared = true
            schedule()
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            schedule()
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            hasAppeared = false
            stop()
        }

        func update(
            request: NavigationDestinationFocusHandoff.Request?,
            onPresented: ((NavigationDestinationFocusHandoff.Request) -> Void)?
        ) {
            if self.request != request {
                stop()
                self.request = request
            }
            self.onPresented = onPresented
            schedule()
        }

        private func schedule() {
            guard displayLink == nil, request != nil, hasAppeared,
                  let view = viewIfLoaded, view.window != nil, !view.bounds.isEmpty else { return }
            let link = CADisplayLink(target: self, selector: #selector(framePresented))
            displayLink = link
            link.add(to: .main, forMode: .common)
        }

        @objc private func framePresented() {
            guard hasAppeared, let request,
                  let view = viewIfLoaded, view.window != nil, !view.bounds.isEmpty else {
                stop()
                return
            }
            // The first callback precedes rendering. The next crosses that commit,
            // so focus cannot redraw the old page before the new surface is painted.
            guard crossedFrame else {
                crossedFrame = true
                return
            }
            stop()
            self.request = nil
            onPresented?(request)
        }

        private func stop() {
            displayLink?.invalidate()
            displayLink = nil
            crossedFrame = false
        }
    }
}
#endif
