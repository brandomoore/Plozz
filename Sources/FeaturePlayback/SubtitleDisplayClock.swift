#if canImport(UIKit)
import SwiftUI
import UIKit

/// Caption boundaries need display cadence, not the live player's 250ms status
/// monitor. The model publishes only when the active cue set actually changes.
struct SubtitleDisplayClock: UIViewRepresentable {
    let engine: any VideoEngine
    let subtitles: LiveSubtitleModel

    func makeUIView(context: Context) -> SubtitleDisplayClockView {
        let view = SubtitleDisplayClockView()
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        view.engine = engine
        view.subtitles = subtitles
        return view
    }

    func updateUIView(_ uiView: SubtitleDisplayClockView, context: Context) {
        uiView.engine = engine
        uiView.subtitles = subtitles
    }

    static func dismantleUIView(_ uiView: SubtitleDisplayClockView, coordinator: ()) {
        uiView.stop()
    }
}

final class SubtitleDisplayClockView: UIView {
    weak var engine: (any VideoEngine)?
    weak var subtitles: LiveSubtitleModel?
    private var link: CADisplayLink?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { stop() }
        else if link == nil {
            let link = CADisplayLink(target: self, selector: #selector(tick))
            link.add(to: .main, forMode: .common)
            self.link = link
        }
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func tick() {
        guard let engine, let subtitles, subtitles.hasContent else { return }
        subtitles.tick(engine.subtitlePresentationTime)
    }
}
#endif
