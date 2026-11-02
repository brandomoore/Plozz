#if canImport(SwiftUI)
import SwiftUI
#if os(iOS)
import UIKit
#endif

public extension View {
    func adaptiveStatusOverlay<Status: View>(
        isPresented: Bool, alignment: Alignment = .bottom, bottomPadding: CGFloat? = nil,
        @ViewBuilder status: () -> Status
    ) -> some View {
        overlay {
            AdaptiveStatusOverlay(
                isPresented: isPresented, alignment: alignment, bottomPadding: bottomPadding,
                status: status()
            )
        }
    }
}

private struct AdaptiveStatusOverlay<Status: View>: View {
    let isPresented: Bool
    let alignment: Alignment
    let bottomPadding: CGFloat?
    let status: Status
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var measuredArea: CGRect?

    var body: some View {
        #if os(iOS)
        GeometryReader { geometry in
            let area = bottomPadding.map {
                CGRect(x: 0, y: 0, width: geometry.size.width, height: max(0, geometry.size.height - $0))
            } ?? measuredArea ?? CGRect(origin: .zero, size: geometry.size)
            Color.clear
                .allowsHitTesting(false)
                .overlay(alignment: .top) {
                    status
                        .frame(width: area.width, alignment: alignment)
                        .alignmentGuide(.top) { $0[.bottom] }
                        .offset(x: area.midX - geometry.size.width / 2, y: area.maxY)
                        .opacity(bottomPadding != nil || measuredArea != nil ? 1 : 0)
                }
                .background {
                    StatusControlsReader(isActive: isPresented && bottomPadding == nil) { area in
                        guard measuredArea != area else { return }
                        let animation: Animation? = measuredArea == nil || reduceMotion
                            ? nil : .easeInOut(duration: TransientStatusLayout.placementAnimationDuration)
                        withAnimation(animation) { measuredArea = area }
                    }
                    .allowsHitTesting(false)
                }
        }
        #else
        status
            .padding(.bottom, bottomPadding ?? TransientStatusLayout.bottomPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
        #endif
    }
}

#if os(iOS)
private struct StatusControlsReader: UIViewControllerRepresentable {
    let isActive: Bool
    let onChange: (CGRect) -> Void

    func makeUIViewController(context: Context) -> Controller { Controller() }

    func updateUIViewController(_ controller: Controller, context: Context) {
        let becameActive = isActive && !controller.isActive
        controller.isActive = isActive
        controller.onChange = onChange
        if becameActive { controller.scheduleMeasurement() }
    }

    static func dismantleUIViewController(_ controller: Controller, coordinator: ()) {
        controller.isActive = false
        controller.onChange = nil
    }

    final class Controller: UIViewController {
        var isActive = false
        var onChange: ((CGRect) -> Void)?
        private var measurementScheduled = false

        override func loadView() {
            view = UIView()
            view.isUserInteractionEnabled = false
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            scheduleMeasurement()
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            scheduleMeasurement()
        }

        override func viewSafeAreaInsetsDidChange() {
            super.viewSafeAreaInsetsDidChange()
            scheduleMeasurement()
        }

        func scheduleMeasurement() {
            guard isActive, !measurementScheduled else { return }
            measurementScheduled = true
            // UIKit finishes laying out its bars after the SwiftUI content pass.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.measurementScheduled = false
                self.measure()
            }
        }

        private func measure() {
            guard isActive, let window = view.window, !view.bounds.isEmpty,
                  var surface = window.rootViewController else { return }
            while let presented = surface.presentedViewController, !presented.isBeingDismissed {
                surface = presented
            }
            let frame = view.convert(view.bounds, to: window)
            var area = frame.intersection(window.safeAreaLayoutGuide.layoutFrame)
            guard !area.isNull else { return }
            constrainToNativeContent(in: surface, window: window, area: &area)
            for control in controls(in: surface.view, window: window) {
                guard control.intersects(area) else { continue }
                if control.height > control.width, control.height > frame.height / 2 {
                    if control.midX > frame.midX {
                        area.size.width = max(0, min(area.maxX, control.minX - TransientStatusLayout.controlSpacing) - area.minX)
                    } else {
                        let right = area.maxX
                        area.origin.x = max(area.minX, control.maxX + TransientStatusLayout.controlSpacing)
                        area.size.width = max(0, right - area.minX)
                    }
                } else if control.minY > frame.midY {
                    area.size.height = max(0, min(area.maxY, control.minY) - area.minY)
                }
            }
            area.size.height = max(0, area.height - TransientStatusLayout.controlSpacing)
            onChange?(area.offsetBy(dx: -frame.minX, dy: -frame.minY))
        }

        private func constrainToNativeContent(in controller: UIViewController, window: UIWindow, area: inout CGRect) {
            guard controller.isViewLoaded, controller.view.window === window, !controller.view.isHidden else { return }
            if #available(iOS 26.0, *), let tabs = controller as? UITabBarController {
                // The native guide covers sidebars on either side, including overlapping layouts.
                let content = tabs.view.convert(tabs.contentLayoutGuide.layoutFrame, to: window)
                if !content.isEmpty {
                    let left = max(area.minX, content.minX)
                    let right = min(area.maxX, content.maxX)
                    area.origin.x = left
                    area.size.width = max(0, right - left)
                }
            }
            for child in controller.children {
                constrainToNativeContent(in: child, window: window, area: &area)
            }
        }

        private func controls(in candidate: UIView, window: UIWindow) -> [CGRect] {
            guard !candidate.isHidden, candidate.alpha > 0.01, candidate.window === window else { return [] }
            if candidate is UITabBar || candidate is UIToolbar || candidate is UISearchBar
                || candidate is UISearchTextField {
                let bounds = candidate.convert(candidate.bounds, to: window)
                if !bounds.isEmpty { return [bounds] }
            }
            return candidate.subviews.flatMap { controls(in: $0, window: window) }
        }
    }
}
#endif
#endif
