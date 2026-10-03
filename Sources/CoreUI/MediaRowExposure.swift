#if os(tvOS)
import CoreModels
import SwiftUI
import UIKit

/// One low-frequency sampler per opted-in row, with no observable render state.
/// Native clipping matters: a realized LazyHStack card is not necessarily visible,
/// and Showcase's vertical viewport lives outside the row's SwiftUI hosting tree.
@MainActor
final class MediaRowExposureTracker: NSObject {
    private let anchors = NSHashTable<MediaRowExposureAnchorView>.weakObjects()
    private var visibleSince: [String: TimeInterval] = [:]
    private var recordedIDs: Set<String> = []
    private var timer: Timer?
    var onExposure: ((MediaItem) -> Void)?
    private(set) var isActive = false

    func register(_ anchor: MediaRowExposureAnchorView) {
        anchors.add(anchor)
    }

    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        visibleSince.removeAll()
        timer?.invalidate()
        timer = nil
        guard active else { return }
        let timer = Timer(timeInterval: 0.5, target: self, selector: #selector(tick),
                          userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    @objc private func tick() {
        sample(at: CACurrentMediaTime())
    }

    func sample(at now: TimeInterval) {
        guard isActive else { return }
        var visible: Set<String> = []
        for anchor in anchors.allObjects {
            guard let item = anchor.item else { continue }
            let id = item.stablePresentationID
            guard !recordedIDs.contains(id), Self.isVisible(anchor) else { continue }
            visible.insert(id)
            let start = visibleSince[id] ?? now
            visibleSince[id] = start
            guard now - start >= 2 else { continue }
            recordedIDs.insert(id)
            onExposure?(item)
        }
        visibleSince = visibleSince.filter {
            visible.contains($0.key) && !recordedIDs.contains($0.key)
        }
    }

    static func isVisible(_ view: UIView) -> Bool {
        guard let window = view.window, !view.bounds.isEmpty else { return false }
        let frame = view.convert(view.bounds, to: window)
        var visible = frame.intersection(window.bounds)
        var ancestor: UIView? = view
        while let current = ancestor {
            guard !current.isHidden, current.alpha > 0.01 else { return false }
            if current.clipsToBounds {
                visible = visible.intersection(current.convert(current.bounds, to: window))
            }
            if let mask = current.layer.mask {
                visible = visible.intersection(current.convert(mask.frame, to: window))
            }
            ancestor = current.superview
        }
        guard !visible.isNull, !visible.isEmpty else { return false }
        return visible.width * visible.height >= frame.width * frame.height * 0.5
    }
}

@MainActor
final class MediaRowExposureAnchorView: UIView {
    var item: MediaItem?
}

struct MediaRowExposureAnchor: UIViewRepresentable {
    let tracker: MediaRowExposureTracker
    let item: MediaItem

    func makeUIView(context: Context) -> MediaRowExposureAnchorView {
        let view = MediaRowExposureAnchorView()
        view.isUserInteractionEnabled = false
        tracker.register(view)
        return view
    }

    func updateUIView(_ view: MediaRowExposureAnchorView, context: Context) {
        view.item = item
    }
}

struct MediaRowExposureDriver: UIViewRepresentable {
    let tracker: MediaRowExposureTracker
    let isActive: Bool
    let onExposure: (MediaItem) -> Void
    @Environment(\.scenePhase) private var scenePhase

    func makeUIView(context: Context) -> DriverView {
        DriverView(tracker: tracker)
    }

    func updateUIView(_ view: DriverView, context: Context) {
        tracker.onExposure = onExposure
        view.isActive = isActive && scenePhase == .active
        view.updateActivity()
    }

    static func dismantleUIView(_ view: DriverView, coordinator: ()) {
        view.tracker.setActive(false)
        view.tracker.onExposure = nil
    }

    final class DriverView: UIView {
        let tracker: MediaRowExposureTracker
        var isActive = false

        init(tracker: MediaRowExposureTracker) {
            self.tracker = tracker
            super.init(frame: .zero)
            isUserInteractionEnabled = false
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            updateActivity()
        }

        func updateActivity() {
            tracker.setActive(isActive && window != nil)
        }
    }
}
#endif
