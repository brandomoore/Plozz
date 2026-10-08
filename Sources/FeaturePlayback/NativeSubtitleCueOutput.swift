#if canImport(AVFoundation)
import AVFoundation
import CoreMedia
import CoreModels
import CoreNetworking
import Foundation

/// AVFoundation delivers complete presentation states, including empty clearing
/// states, on the item timeline. Callback arrival time is not presentation time.
struct NativeSubtitleTimeline {
    struct Event {
        var time: Double
        var cues: [SubtitleCue]
    }

    private(set) var events: [Event] = []
    private var nextID = 0
    static let retention: Double = 15

    mutating func reset() {
        events.removeAll(keepingCapacity: true)
    }

    mutating func receive(_ text: [SubtitleText], at time: Double, playhead: Double) -> [SubtitleCue] {
        guard time.isFinite, playhead.isFinite else { return cues }
        let newCues = text.filter { !$0.string.isEmpty }.map { text in
            defer { nextID &+= 1 }
            return SubtitleCue(id: nextID, start: time, end: .infinity, body: .text(text))
        }
        if let index = events.firstIndex(where: { $0.time >= time }) {
            if events[index].time == time {
                events[index] = Event(time: time, cues: newCues)
            } else {
                events.insert(Event(time: time, cues: newCues), at: index)
            }
        } else {
            events.append(Event(time: time, cues: newCues))
        }
        // Retain the state crossing the history boundary, not just events that
        // start inside it. Positive subtitle delay still needs that state.
        if let lastPast = events.lastIndex(where: { $0.time <= playhead - Self.retention }), lastPast > 0 {
            events.removeFirst(lastPast)
        }
        return cues
    }

    var cues: [SubtitleCue] {
        events.indices.flatMap { index in
            let end = index + 1 < events.count ? events[index + 1].time : .infinity
            return events[index].cues.map { cue in
                var cue = cue
                cue.end = end
                return cue
            }
        }
    }
}

enum NativeSubtitleText {
    static func decode(_ string: NSAttributedString) -> SubtitleText {
        var runs: [SubtitleTextRun] = []
        var bold = false
        var italic = false
        string.enumerateAttributes(in: NSRange(location: 0, length: string.length)) { attributes, range, _ in
            bold = bold || bool(attributes, kCMTextMarkupAttribute_BoldStyle)
            italic = italic || bool(attributes, kCMTextMarkupAttribute_ItalicStyle)
            let color = (attributes[.init(kCMTextMarkupAttribute_ForegroundColorARGB as String)] as? [NSNumber])
                .flatMap { components -> SubtitleColor? in
                    guard components.count == 4, components.allSatisfy({ $0.doubleValue.isFinite }) else { return nil }
                    return SubtitleColor(
                        red: components[1].doubleValue, green: components[2].doubleValue,
                        blue: components[3].doubleValue, alpha: components[0].doubleValue
                    )
                }
            runs.append(.init((string.string as NSString).substring(with: range), color: color))
        }
        // tx3g declares opaque white as its default even for unstyled text.
        // Like our ASS decoder, do not mistake that default for an inline color.
        if runs.allSatisfy({ $0.color == nil || $0.color == .white }) {
            runs = runs.map { .init($0.text) }
        }
        let attributes = string.length > 0 ? string.attributes(at: 0, effectiveRange: nil) : [:]
        return SubtitleText(runs: runs, isItalic: italic, isBold: bold, layout: layout(attributes))
    }

    /// WebVTT cue settings as AVFoundation reports them. It passes `line:` and
    /// `position:` percentages through unchanged but drops line numbers and the
    /// `line`/`position` alignment keywords, and reports an unpositioned cue as
    /// line 100, position 50. So a `line:` percentage takes WebVTT's default line
    /// alignment (the box's top edge sits on the line), and `position:` pins the
    /// edge `align:` implies: left for start/left, right for end/right, the
    /// centre otherwise. `size:` is limited to what fits beside that anchor, as
    /// WebVTT does.
    static func layout(_ attributes: [NSAttributedString.Key: Any]) -> SubtitleCueLayout? {
        let position = number(attributes, kCMTextMarkupAttribute_TextPositionPercentageRelativeToWritingDirection)
        let line = number(attributes, kCMTextMarkupAttribute_OrthogonalLinePositionPercentageRelativeToWritingDirection)
            .flatMap { $0 == 100 ? nil : $0 }
        let size = number(attributes, kCMTextMarkupAttribute_WritingDirectionSizePercentage)
        let alignment = attributes[.init(kCMTextMarkupAttribute_Alignment as String)] as? String
        let horizontal: SubtitleAlignment.Horizontal
        if alignment == kCMTextMarkupAlignmentType_Start as String || alignment == kCMTextMarkupAlignmentType_Left as String {
            horizontal = .leading
        } else if alignment == kCMTextMarkupAlignmentType_End as String
                    || alignment == kCMTextMarkupAlignmentType_Right as String {
            horizontal = .trailing
        } else {
            horizontal = .center
        }
        guard line != nil || (position != nil && position != 50) || horizontal != .center else { return nil }

        let x = min(100, max(0, position ?? 50))
        let room = switch horizontal {
        case .leading: 100 - x
        case .trailing: x
        case .center: 2 * min(x, 100 - x)
        }
        let width = min(size ?? 100, room)
        let plane: SubtitleAlignment = switch (line != nil, horizontal) {
        case (true, .leading): .topLeft
        case (true, .center): .topCenter
        case (true, .trailing): .topRight
        case (false, .leading): .bottomLeft
        case (false, .center): .bottomCenter
        case (false, .trailing): .bottomRight
        }
        return SubtitleCueLayout(
            alignment: plane,
            anchor: CGPoint(x: x / 100, y: line.map { min(100, max(0, $0)) / 100 } ?? 1),
            boxWidth: width > 0 ? width / 100 : nil
        )
    }

    private static func bool(_ attributes: [NSAttributedString.Key: Any], _ key: CFString) -> Bool {
        (attributes[.init(key as String)] as? NSNumber)?.boolValue == true
    }

    private static func number(_ attributes: [NSAttributedString.Key: Any], _ key: CFString) -> Double? {
        guard let value = (attributes[.init(key as String)] as? NSNumber)?.doubleValue, value.isFinite else { return nil }
        return value
    }
}

/// Owns one item's native caption extraction. Replacing the output on selection
/// fences queued callbacks from the previous track without guessing its cue end.
@MainActor
public final class NativeSubtitleCueOutput: NSObject, AVPlayerItemLegibleOutputPushDelegate {
    private weak var player: AVPlayer?
    private weak var item: AVPlayerItem?
    private var output: AVPlayerItemLegibleOutput?
    private var timeline = NativeSubtitleTimeline()
    private let onCues: @MainActor ([SubtitleCue]) -> Void
    private var selectionEnabled = false
    private var selectedOption: AVMediaSelectionOption?
    private var systemPresentation = false
    private var externalPlayback = false
    private var routeObservation: NSKeyValueObservation?
    private var renderingTask: Task<Void, Never>?
    private var renderingGeneration = 0
    private var style: SubtitleStyle

    public init(player: AVPlayer, item: AVPlayerItem, style: SubtitleStyle,
                onCues: @escaping @MainActor ([SubtitleCue]) -> Void) {
        self.player = player
        self.item = item
        self.style = style
        self.onCues = onCues
        externalPlayback = player.isExternalPlaybackActive
        super.init()
        replaceOutput()
        routeObservation = player.observe(\.isExternalPlaybackActive, options: [.new]) { [weak self] _, change in
            guard let active = change.newValue else { return }
            Task { @MainActor [weak self] in
                guard let self, self.externalPlayback != active else { return }
                self.externalPlayback = active
                self.updateRenderingOwner()
            }
        }
    }

    private var wantsPlayerRendering: Bool { systemPresentation || externalPlayback }
    public var rendersThroughPlayer: Bool {
        output.map { !$0.suppressesPlayerRendering } ?? wantsPlayerRendering
    }

    public func select(enabled: Bool) {
        renderingGeneration &+= 1
        renderingTask?.cancel()
        renderingTask = nil
        selectionEnabled = enabled
        selectedOption = nil
        replaceOutput()
    }

    public func updateStyle(_ style: SubtitleStyle) {
        self.style = style
        item?.textStyleRules = rendersThroughPlayer ? style.textStyleRules() : nil
    }

    public func setSystemPresentation(_ active: Bool) {
        guard systemPresentation != active else { return }
        systemPresentation = active
        updateRenderingOwner()
    }

    public func detach() {
        renderingGeneration &+= 1
        renderingTask?.cancel()
        renderingTask = nil
        routeObservation = nil
        output?.setDelegate(nil, queue: nil)
        if let output { item?.remove(output) }
        output = nil
        item = nil
        player = nil
        selectedOption = nil
        timeline.reset()
        onCues([])
    }

    private func replaceOutput() {
        guard let item else { return }
        let previous = output
        let next = AVPlayerItemLegibleOutput()
        next.suppressesPlayerRendering = !wantsPlayerRendering
        next.textStylingResolution = .sourceAndRulesOnly
        // The UI permits +/-10 seconds. Scheduling still uses itemTime, never
        // the early callback's arrival, and clear states are delayed equally.
        next.advanceIntervalForDelegateInvocation = 12
        next.setDelegate(self, queue: .main)
        output = next
        // Avoid overlapping registrations while the paused rendition changes.
        previous?.setDelegate(nil, queue: nil)
        if let previous { item.remove(previous) }
        item.add(next)
        item.textStyleRules = rendersThroughPlayer ? style.textStyleRules() : nil
        timeline.reset()
        onCues([])
    }

    private func updateRenderingOwner() {
        renderingGeneration &+= 1
        let generation = renderingGeneration
        renderingTask?.cancel()
        renderingTask = Task { @MainActor [weak self, weak item] in
            guard let self, let item else { return }
            let group: AVMediaSelectionGroup?
            do {
                group = try await item.asset.loadMediaSelectionGroup(for: .legible)
            } catch {
                guard !Task.isCancelled, self.item === item else { return }
                PlozzLog.playback.error("Unable to update native caption presentation ownership.")
                return
            }
            guard let group, !Task.isCancelled,
                  self.renderingGeneration == generation, self.item === item else { return }
            let current = item.currentMediaSelection.selectedMediaOption(in: group)
            if let current { self.selectedOption = current }
            let selected = self.selectionEnabled ? (current ?? self.selectedOption) : nil
            item.select(nil, in: group)
            // Clear the old native line before changing drawing ownership.
            await Task.yield()
            guard !Task.isCancelled, self.renderingGeneration == generation, self.item === item else { return }
            item.select(selected, in: group)
            self.replaceOutput()
        }
    }

    nonisolated public func legibleOutput(
        _ output: AVPlayerItemLegibleOutput, didOutputAttributedStrings strings: [NSAttributedString],
        nativeSampleBuffers nativeSamples: [Any], forItemTime itemTime: CMTime
    ) {
        MainActor.assumeIsolated {
            guard self.output === output, selectionEnabled, !rendersThroughPlayer,
                  let player, let item, player.currentItem === item else { return }
            guard itemTime.seconds.isFinite, player.currentTime().seconds.isFinite else {
                PlozzLog.playback.error("Native captions supplied an invalid presentation time.")
                return
            }
            let cues = timeline.receive(strings.map(NativeSubtitleText.decode), at: itemTime.seconds,
                                        playhead: player.currentTime().seconds)
            onCues(cues)
        }
    }

    nonisolated public func outputSequenceWasFlushed(_ output: AVPlayerItemOutput) {
        MainActor.assumeIsolated {
            guard self.output === output else { return }
            timeline.reset()
            onCues([])
        }
    }
}
#endif
