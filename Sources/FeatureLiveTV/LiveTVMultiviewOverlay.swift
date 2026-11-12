import CoreModels
import CoreUI
import FeatureLiveTVCore
import SwiftUI

enum LiveTVMultiviewGeometry {
    static var videoCornerRadius: CGFloat {
        #if os(tvOS)
        20
        #else
        10
        #endif
    }

    static func presentationFrame(
        in slot: CGRect, aspectRatio: CGFloat?, focusActive: Bool, layout: LiveTVMultiviewLayout = .corner
    ) -> CGRect {
        let picture = contentFrame(in: slot, aspectRatio: aspectRatio)
        #if os(tvOS)
        let inset = focusActive && layout == .corner ? focusInset(for: picture.width) : 0
        return picture.insetBy(dx: inset, dy: inset * picture.height / max(1, picture.width))
        #else
        return picture
        #endif
    }

    static func focusInset(for width: CGFloat) -> CGFloat {
        min(width * 0.2, max(28, width * 0.02))
    }

    static func focusContainerFrame(
        for picture: CGRect, horizontalInset: CGFloat, layout: LiveTVMultiviewLayout
    ) -> CGRect {
        guard layout != .corner else { return picture }
        // Packed frames describe the resting video; transparent clearance must not shrink it.
        return picture.insetBy(
            dx: -horizontalInset, dy: -horizontalInset * picture.height / max(1, picture.width))
    }

    @MainActor
    static func aspectRatios(in panes: [LiveTVMultiviewPane]) -> [UUID: CGFloat] {
        Dictionary(uniqueKeysWithValues: panes.map { ($0.id, CGFloat($0.videoAspectRatio ?? 16 / 9)) })
    }

    static func viewport(in size: CGSize, isEditing: Bool = false, editingInsets: EdgeInsets? = nil) -> CGRect {
        let canvas = CGRect(origin: .zero, size: size)
        guard isEditing else { return canvas }
        if let insets = editingInsets {
            return CGRect(
                x: insets.leading, y: insets.top,
                width: max(1, size.width - insets.leading - insets.trailing),
                height: max(1, size.height - insets.top - insets.bottom)
            )
        }
        #if os(tvOS)
        let margin = min(CGFloat(24), min(size.width, size.height) / 12)
        return CGRect(
            x: margin, y: margin, width: max(1, size.width - 2 * margin),
            height: max(1, size.height - margin - min(156, size.height / 4)))
        #else
        let horizontal = min(CGFloat(24), size.width / 12)
        let vertical = min(CGFloat(100), size.height / 4)
        return canvas.insetBy(dx: horizontal, dy: vertical)
        #endif
    }

    static func focusViewport(
        in size: CGSize, chromeVisible: Bool, isEditing: Bool = false, editingInsets: EdgeInsets? = nil
    ) -> CGRect {
        if isEditing { return viewport(in: size, isEditing: true, editingInsets: editingInsets) }
        guard chromeVisible else { return viewport(in: size) }
        #if os(tvOS)
        let top = min(CGFloat(156), size.height / 4)
        let bottom = min(CGFloat(156), size.height / 4)
        #else
        let top = min(CGFloat(90), size.height / 4)
        let bottom = min(CGFloat(110), size.height / 4)
        #endif
        return CGRect(x: 0, y: top, width: size.width, height: max(1, size.height - top - bottom))
    }

    static func frame(
        for id: UUID, panes: [UUID], primary: UUID,
        layout: LiveTVMultiviewLayout, corner: LiveTVMultiviewCorner,
        insetSize: LiveTVMultiviewInsetSize, expanded: UUID?, size: CGSize,
        isEditing: Bool = false, aspectRatio: CGFloat? = nil, editingInsets: EdgeInsets? = nil,
        aspectRatios: [UUID: CGFloat] = [:]
    ) -> CGRect {
        if expanded != nil { return viewport(in: size) }
        let area = viewport(in: size, isEditing: isEditing, editingInsets: editingInsets)
        let ordered = [primary] + panes.filter { $0 != primary }
        if ordered.count == 1 {
            return isEditing ? contentFrame(in: area, aspectRatio: aspectRatio) : area
        }
        let index = ordered.firstIndex(of: id) ?? 0
        #if os(tvOS)
        if layout == .mainAndStack || layout == .sideBySide {
            let ratios = ordered.map { validAspectRatio(aspectRatios[$0] ?? aspectRatio) }
            return packedFrame(index: index, ratios: ratios, area: area, layout: layout, gap: isEditing ? 24 : 8)
        }
        #endif
        if layout == .mainAndStack {
            let gap = min(CGFloat(16), max(0, min(area.width, area.height) / 12))
            let sideWidth = area.width * 0.28
            let mainWidth = area.width - sideWidth - gap
            let slot: CGRect
            if id == primary {
                slot = CGRect(x: area.minX, y: area.minY, width: mainWidth, height: area.height)
            } else {
                let count = CGFloat(ordered.count - 1)
                let height = (area.height - gap * (count - 1)) / count
                slot = CGRect(
                    x: area.maxX - sideWidth, y: area.minY + CGFloat(index - 1) * (height + gap),
                    width: sideWidth, height: height)
            }
            return isEditing ? contentFrame(in: slot, aspectRatio: aspectRatio) : slot
        }
        if layout == .sideBySide {
            #if os(tvOS)
            let gap: CGFloat = isEditing ? 0 : 8
            #else
            let gap: CGFloat = 0
            #endif
            let horizontal = area.width >= area.height
            let slot: CGRect
            if ordered.count > 2 {
                let row = index / 2
                let columns = min(2, ordered.count - row * 2)
                let width = (area.width - gap * CGFloat(columns - 1)) / CGFloat(columns)
                let height = (area.height - gap) / 2
                slot = CGRect(
                    x: area.minX + CGFloat(index % 2) * (width + gap),
                    y: area.minY + CGFloat(row) * (height + gap),
                    width: width, height: height)
            } else if horizontal {
                let width = (area.width - gap) / 2
                slot = CGRect(
                    x: area.minX + CGFloat(index) * (width + gap), y: area.minY,
                    width: width, height: area.height)
            } else {
                let height = (area.height - gap) / 2
                slot = CGRect(
                    x: area.minX, y: area.minY + CGFloat(index) * (height + gap),
                    width: area.width, height: height)
            }
            return isEditing ? contentFrame(in: slot.insetBy(dx: 8, dy: 8), aspectRatio: aspectRatio) : slot
        }
        guard id != primary else {
            return isEditing ? contentFrame(in: area, aspectRatio: aspectRatio) : area
        }
        let insetBounds = insetPlacementBounds(in: area)
        let count = CGFloat(ordered.count - 1)
        let spacing: CGFloat = 12
        let availableHeight = max(1, insetBounds.height - 32 - spacing * (count - 1))
        let width = min(insetBounds.width * CGFloat(insetSize.fraction), availableHeight / count * 16 / 9)
        let height = width * 9 / 16
        let left = corner == .topLeading || corner == .bottomLeading
        let atTop = corner == .topLeading || corner == .topTrailing
        let columnHeight = height * count + spacing * (count - 1)
        let top = atTop ? insetBounds.minY + 16 : insetBounds.maxY - columnHeight - 16
        let slot = CGRect(
            x: left ? insetBounds.minX + 16 : insetBounds.maxX - width - 16,
            y: top + CGFloat(index - 1) * (height + spacing),
            width: width, height: height
        )
        return isEditing ? contentFrame(in: slot, aspectRatio: aspectRatio) : slot
    }

    static func focusFrame(
        for id: UUID, panes: [UUID], primary: UUID,
        layout: LiveTVMultiviewLayout, corner: LiveTVMultiviewCorner,
        insetSize: LiveTVMultiviewInsetSize, expanded: UUID?, size: CGSize,
        chromeVisible: Bool, isEditing: Bool = false, aspectRatio: CGFloat? = nil, editingInsets: EdgeInsets? = nil,
        aspectRatios: [UUID: CGFloat] = [:]
    ) -> CGRect {
        let picture = frame(
            for: id, panes: panes, primary: primary, layout: layout, corner: corner,
            insetSize: insetSize, expanded: expanded, size: size,
            isEditing: isEditing, aspectRatio: aspectRatio, editingInsets: editingInsets, aspectRatios: aspectRatios
        )
        var region = contentFrame(in: picture, aspectRatio: aspectRatio)
        if expanded == nil, layout == .corner, id == primary,
           let secondary = panes.first(where: { $0 != primary }) {
            let inset = frame(
                for: secondary, panes: panes, primary: primary, layout: layout, corner: corner,
                insetSize: insetSize, expanded: nil, size: size,
                isEditing: isEditing, editingInsets: editingInsets
            )
            // Keep the primary target beside, never surrounding, the inset.
            let leading = corner == .topLeading || corner == .bottomLeading
            let x = leading ? inset.maxX + 16 : picture.minX
            let right = leading ? picture.maxX : inset.minX - 16
            region = region.intersection(
                CGRect(x: x, y: picture.minY, width: max(1, right - x), height: picture.height))
        }
        return region.intersection(focusViewport(
            in: size, chromeVisible: chromeVisible, isEditing: isEditing, editingInsets: editingInsets))
    }

    static func contentFrame(in area: CGRect, aspectRatio: CGFloat?) -> CGRect {
        let ratio = validAspectRatio(aspectRatio)
        let width = min(area.width, area.height * ratio)
        let height = width / ratio
        return CGRect(x: area.midX - width / 2, y: area.midY - height / 2, width: width, height: height)
    }

    private static func insetPlacementBounds(in area: CGRect) -> CGRect {
        contentFrame(in: area, aspectRatio: 16 / 9)
    }

    private static func validAspectRatio(_ ratio: CGFloat?) -> CGFloat {
        ratio.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 16 / 9
    }

    #if os(tvOS)
    private static func packedFrame(
        index: Int, ratios: [CGFloat], area: CGRect, layout: LiveTVMultiviewLayout, gap: CGFloat
    ) -> CGRect {
        if layout == .mainAndStack {
            let sideRatios = ratios.dropFirst()
            let verticalGaps = gap * CGFloat(max(2, sideRatios.count) - 1)
            let sideHeightPerWidth = sideRatios.reduce(CGFloat.zero) { $0 + 1 / $1 }
                * (sideRatios.count == 1 ? 2 : 1)
            let width = min(
                (area.width - gap - ratios[0] * verticalGaps) / (1 + ratios[0] * sideHeightPerWidth),
                (area.height - verticalGaps) / sideHeightPerWidth)
            let height = width * sideHeightPerWidth + verticalGaps
            let mainWidth = height * ratios[0]
            let x = area.midX - (mainWidth + gap + width) / 2
            let y = area.midY - height / 2
            if index == 0 { return CGRect(x: x, y: y, width: mainWidth, height: height) }
            let precedingHeight = ratios.dropFirst().prefix(index - 1).reduce(CGFloat.zero) { $0 + width / $1 }
            return CGRect(
                x: x + mainWidth + gap,
                y: sideRatios.count == 1 ? area.midY - width / ratios[index] / 2
                    : y + precedingHeight + gap * CGFloat(index - 1),
                width: width, height: width / ratios[index])
        }
        let columns = ratios.count == 2 && area.width < area.height ? 1 : 2
        let rows = stride(from: 0, to: ratios.count, by: columns).map {
            Array(ratios[$0..<min($0 + columns, ratios.count)])
        }
        let height = rows.reduce((area.height - gap * CGFloat(rows.count - 1)) / CGFloat(rows.count)) {
            min($0, (area.width - gap * CGFloat($1.count - 1)) / $1.reduce(0, +))
        }
        let row = index / columns
        let rowWidth = rows[row].reduce(0, +) * height + gap * CGFloat(rows[row].count - 1)
        let x = area.midX - rowWidth / 2
            + rows[row].prefix(index % columns).reduce(0, +) * height + gap * CGFloat(index % columns)
        let y = area.midY - (height * CGFloat(rows.count) + gap * CGFloat(rows.count - 1)) / 2
            + CGFloat(row) * (height + gap)
        return CGRect(x: x, y: y, width: height * ratios[index], height: height)
    }
    #endif
}

struct LiveTVMultiviewChromeState: Equatable {
    private(set) var isVisible = true
    private(set) var isEditing = false
    private(set) var inactivity = PlaybackControlsInactivity()

    mutating func activity(at time: TimeInterval, blocked: Bool = false) {
        guard !blocked else { return }
        #if !os(tvOS)
        guard !isEditing else { return }
        #endif
        inactivity.recordInteraction(at: time)
        isVisible = true
    }

    mutating func editing(at time: TimeInterval, blocked: Bool = false) {
        guard !blocked else { return }
        #if !os(tvOS)
        guard !isEditing else { return }
        #endif
        activity(at: time)
        isEditing = true
    }

    mutating func watching(at time: TimeInterval) {
        isEditing = false
        activity(at: time)
    }

    mutating func hide() {
        isVisible = false
        isEditing = false
    }

    func canAutoHide(blocked: Bool) -> Bool {
        #if os(tvOS)
        isVisible && !blocked
        #else
        isVisible && !isEditing && !blocked
        #endif
    }
}

struct LiveTVMultiviewOverlay: View {
    let coordinator: LiveTVMultiviewCoordinator
    var safeAreaInsets = EdgeInsets()
    var editingInsets: EdgeInsets?
    var onEditingInsetsChange: (EdgeInsets) -> Void = { _ in }
    var onFocusPresentationChange: (Bool) -> Void = { _ in }
    var nativeFocusedPaneID: UUID?
    var onRestoreVideoFocus: () -> Void = {}
    var onRequestVideoFocus: (UUID) -> Void = { _ in }
    var backRequest = 0
    let exit: () -> Void
    let returnToGuide: () -> Void
    let addChannel: () -> Void
    let replaceChannel: (UUID) -> Void
    var isFavorite = false
    var toggleFavorite: (() -> Void)?
    @State private var exitDestination: ExitDestination?
    @State private var chrome = LiveTVMultiviewChromeState()
    @State private var focusedPaneID: UUID?
    @State private var restoringSetupFocus = false
    @State private var showsFocusPresentation = false
    @State private var focusOutsideContent = false
    @Namespace private var paneFocusScope
    @Namespace private var controlsFocusScope
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver

    private enum ExitDestination { case player, guide }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                ZStack(alignment: .topLeading) {
                    LiveTVMultiviewPaneViewport(
                        coordinator: coordinator, size: geometry.size,
                        editingInsets: editingInsets,
                        chromeVisible: chrome.isVisible, focusScope: paneFocusScope,
                        focusedPaneID: focusedPaneID,
                        showsFocusPresentation: showsFocusPresentation && coordinator.expandedPaneID == nil,
                        preparedWhileFocused: { id in
                            selectPreparedAudio(id)
                            onRequestVideoFocus(id)
                        },
                        fallbackFocusChanged: paneFocusChanged,
                        activate: promote,
                        editing: beginEditing,
                        replace: { beginEditing(); replaceChannel($0) }
                    )
                    if chrome.isVisible {
                        LiveTVMultiviewChrome(
                            coordinator: coordinator,
                            safeAreaInsets: safeAreaInsets,
                            onEditingInsetsChange: onEditingInsetsChange,
                            exit: { exitDestination = .player }, collapse: collapse, watch: finishSetup, setup: startSetup,
                            focusScope: controlsFocusScope,
                            restoresSetupFocus: restoringSetupFocus,
                            setupFocused: { restoringSetupFocus = false },
                            editing: beginEditing,
                            add: { beginEditing(); addChannel() },
                            replace: { beginEditing(); replaceChannel(coordinator.audiblePaneID) },
                            isFavorite: isFavorite, toggleFavorite: toggleFavorite
                        )
                        .transition(.identity)
                    }
                }
                #if os(tvOS)
                .background {
                    TVFocusActivityObserver(
                        onActivity: {},
                        onFocusedFrame: { activity(keeping: $0, size: geometry.size) },
                        onFocusOutsideContent: { outside in
                            let wasOutside = focusOutsideContent
                            focusOutsideContent = outside
                            if wasOutside, !outside, chrome.isVisible { activity() }
                        },
                        ignoresProgrammaticFocusChanges: true,
                        observesDirectionalPresses: false,
                        onFailedMove: moveAcrossOverlappingPictures)
                }
                .onChange(of: nativeFocusedPaneID, initial: true) { _, id in
                    if let previous = focusedPaneID, previous != id { paneFocusChanged(previous, false) }
                    if let id { paneFocusChanged(id, true) }
                }
                .onChange(of: showsFocusPresentation) { _, shown in
                    onFocusPresentationChange(shown)
                }
                .onDisappear { onFocusPresentationChange(false) }
                #endif
                .onAppear {
                    if coordinator.isEditingLayout { beginEditing() } else { activity() }
                    presentFocus()
                    restoreAudiblePaneFocus()
                }
                .onChange(of: voiceOver) { _, enabled in
                    if enabled { activity() }
                    if focusedPaneID != nil { presentFocus() }
                }
                .task(id: autoHideRequest) {
                    guard autoHideRequest != nil else { return }
                    let now = ProcessInfo.processInfo.systemUptime
                    let delay = chrome.inactivity.remainingDelay(
                        startedAt: chrome.inactivity.lastInteractionAt ?? now, now: now,
                        grace: idleDelay
                    )
                    try? await Task.sleep(for: .seconds(delay))
                    guard !Task.isCancelled, autoHideRequest != nil else { return }
                    #if os(tvOS)
                    coordinator.finishEditingLayout()
                    showsFocusPresentation = false
                    #endif
                    chrome.hide()
                }
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: coordinator.layout)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: coordinator.primaryPaneID)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: coordinator.corner)
            }
        }
        .alert(
            "Multiview",
            isPresented: Binding(
                get: { coordinator.issue != nil },
                set: { if !$0 { coordinator.dismissIssue() } }
            )
        ) {
            Button("OK", role: .cancel) { coordinator.dismissIssue() }
        } message: {
            if let issue = coordinator.issue { Text(issue) }
        }
        .confirmationDialog(
            "Close Multiview?",
            isPresented: Binding(
                get: { exitDestination != nil },
                set: { if !$0 { exitDestination = nil } }),
            titleVisibility: .visible, presenting: exitDestination
        ) { destination in
            Button("Close Multiview", role: .destructive) {
                exitDestination = nil
                if destination == .player { exit() } else { returnToGuide() }
            }
            Button("Keep watching", role: .cancel) { exitDestination = nil }
        } message: { _ in
            if isFavorite {
                Text("This Multiview will close. Its favorite will remain available in the guide.")
            } else {
                Text("This Multiview will close. Favorite it first if you want to open this setup again.")
            }
        }
        .playerPlatformAppearance()
        #if os(tvOS)
        .onExitCommand(perform: back)
        .onChange(of: backRequest) { _, _ in back() }
        #endif
    }

    private var autoHideRequest: TimeInterval? {
        #if os(tvOS)
        let editingBlocks = false
        #else
        let editingBlocks = coordinator.isEditingLayout
        #endif
        let blocked = editingBlocks || focusOutsideContent || exitDestination != nil || coordinator.issue != nil || voiceOver
            || coordinator.panes.contains {
                $0.preparation.failure != nil
                    || ($0.preparation.current == nil && $0.preparation.isPreparing)
            }
        return chrome.canAutoHide(blocked: blocked) ? (chrome.inactivity.lastInteractionAt ?? 0) : nil
    }

    private var idleDelay: TimeInterval {
        #if os(tvOS)
        10
        #else
        PlaybackControlsInactivity.defaultGrace
        #endif
    }

    private func activity() {
        #if os(tvOS)
        guard !focusOutsideContent else { return }
        if !chrome.isVisible {
            coordinator.beginEditingLayout()
        }
        presentFocus()
        #else
        guard !chrome.isEditing else { return }
        #endif
        chrome.activity(at: ProcessInfo.processInfo.systemUptime)
    }

    private func beginEditing() {
        #if os(tvOS)
        guard !focusOutsideContent else { return }
        presentFocus()
        #else
        guard !chrome.isEditing else { return }
        #endif
        chrome.editing(at: ProcessInfo.processInfo.systemUptime, blocked: focusOutsideContent)
    }

    private func startSetup() {
        #if os(tvOS)
        restoringSetupFocus = true
        #endif
        coordinator.beginEditingLayout()
        beginEditing()
    }

    private func finishSetup() {
        restoringSetupFocus = false
        coordinator.finishEditingLayout()
        hideChrome()
    }

    private func paneFocusChanged(_ id: UUID, _ focused: Bool) {
        if focused {
            focusedPaneID = id
            if chrome.isVisible { presentFocus() }
            if chrome.isVisible && !coordinator.isEditingLayout {
                chrome.watching(at: ProcessInfo.processInfo.systemUptime)
            }
            #if os(tvOS)
            // Ordinary TV audio follows completed user movement, not a style's default-focus handoff.
            if chrome.isVisible, voiceOver { selectPreparedAudio(id) }
            #else
            if chrome.isVisible { selectPreparedAudio(id) }
            #endif
        } else if focusedPaneID == id {
            focusedPaneID = nil
            // Native context-menu focus can leave the anchor without entering another SwiftUI view.
            if chrome.isVisible { beginEditing() }
        }
    }

    private func presentFocus() {
        #if os(tvOS)
        showsFocusPresentation = true
        #endif
    }

    #if os(tvOS)
    private func activity(keeping nativeFrame: CGRect, size: CGSize) {
        guard !focusOutsideContent else { return }
        let waking = !chrome.isVisible
        let focusedPicture = coordinator.panes.first { pane in
            guard coordinator.expandedPaneID == nil || coordinator.expandedPaneID == pane.id else { return false }
            let slot = LiveTVMultiviewGeometry.frame(
                for: pane.id, panes: coordinator.panes.map(\.id),
                primary: coordinator.primaryPaneID, layout: coordinator.layout,
                corner: coordinator.corner, insetSize: coordinator.insetSize,
                expanded: coordinator.expandedPaneID, size: size,
                isEditing: coordinator.isEditingLayout,
                aspectRatio: pane.videoAspectRatio.map { CGFloat($0) },
                editingInsets: editingInsets,
                aspectRatios: LiveTVMultiviewGeometry.aspectRatios(in: coordinator.panes))
            return abs(slot.midX - nativeFrame.midX) < max(2, slot.width * 0.1)
                && abs(slot.midY - nativeFrame.midY) < max(2, slot.height * 0.1)
        }
        activity()
        if let focusedPicture {
            // Preserve the destination UIKit selected before changing card style or layout.
            selectPreparedAudio(focusedPicture.id)
            if waking { onRequestVideoFocus(focusedPicture.id) }
        }
    }

    private func moveAcrossOverlappingPictures(_ direction: MoveCommandDirection) {
        guard !focusOutsideContent, coordinator.layout == .corner,
              coordinator.expandedPaneID == nil, let focusedPaneID else { return }
        let insets = coordinator.panes.map(\.id).filter { $0 != coordinator.primaryPaneID }
        let leading = coordinator.corner == .topLeading || coordinator.corner == .bottomLeading
        let toward: MoveCommandDirection = leading ? .left : .right
        let away: MoveCommandDirection = leading ? .right : .left
        // UIKit cannot leave a large focus rectangle for a picture contained
        // inside it. Bridge only a movement the native engine already declined.
        if focusedPaneID == coordinator.primaryPaneID, direction == toward, let first = insets.first {
            focusPicture(first)
        } else if insets.contains(focusedPaneID), direction == away {
            focusPicture(coordinator.primaryPaneID)
        } else if let index = insets.firstIndex(of: focusedPaneID) {
            if direction == .up, index > 0 { focusPicture(insets[index - 1]) }
            if direction == .down, index + 1 < insets.count { focusPicture(insets[index + 1]) }
        }
    }

    private func focusPicture(_ id: UUID) {
        selectPreparedAudio(id)
        onRequestVideoFocus(id)
    }
    #endif

    private func back() {
        if coordinator.expandedPaneID != nil {
            collapse()
        } else if coordinator.isEditingLayout {
            finishSetup()
        } else if chrome.isEditing {
            hideChrome()
        } else {
            exitDestination = .guide
        }
    }

    private func selectPreparedAudio(_ id: UUID) {
        guard !restoringSetupFocus,
              coordinator.expandedPaneID == nil || coordinator.expandedPaneID == id,
              let pane = coordinator.panes.first(where: { $0.id == id }),
              pane.preparation.current != nil else { return }
        coordinator.selectAudio(id)
    }

    private func promote(_ id: UUID) {
        guard coordinator.panes.first(where: { $0.id == id })?.preparation.current != nil else {
            activity()
            return
        }
        selectPreparedAudio(id)
        coordinator.promote(id)
        activity()
    }

    private func collapse() {
        coordinator.collapse()
        hideChrome()
    }

    private func hideChrome() {
        chrome.hide()
        showsFocusPresentation = false
        restoreAudiblePaneFocus()
    }

    private func restoreAudiblePaneFocus() {
        #if os(tvOS)
        if coordinator.audiblePane?.preparation.current != nil {
            onRestoreVideoFocus()
        }
        #endif
    }

}

private struct LiveTVMultiviewPaneViewport: View {
    let coordinator: LiveTVMultiviewCoordinator
    let size: CGSize
    let editingInsets: EdgeInsets?
    let chromeVisible: Bool
    let focusScope: Namespace.ID
    let focusedPaneID: UUID?
    let showsFocusPresentation: Bool
    let preparedWhileFocused: (UUID) -> Void
    let fallbackFocusChanged: (UUID, Bool) -> Void
    let activate: (UUID) -> Void
    let editing: () -> Void
    let replace: (UUID) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Revealing controls must not reshape the native focus section under the current picture.
        let viewport = LiveTVMultiviewGeometry.focusViewport(
            in: size, chromeVisible: true, isEditing: coordinator.isEditingLayout, editingInsets: editingInsets)
        ZStack(alignment: .topLeading) {
            ForEach(coordinator.panes) { pane in
                let frame = LiveTVMultiviewGeometry.frame(
                    for: pane.id, panes: coordinator.panes.map(\.id),
                    primary: coordinator.primaryPaneID, layout: coordinator.layout,
                    corner: coordinator.corner, insetSize: coordinator.insetSize,
                    expanded: coordinator.expandedPaneID, size: size,
                    isEditing: coordinator.isEditingLayout,
                    aspectRatio: pane.videoAspectRatio.map { CGFloat($0) },
                    editingInsets: editingInsets,
                    aspectRatios: LiveTVMultiviewGeometry.aspectRatios(in: coordinator.panes)
                )
                let focusFrame = LiveTVMultiviewGeometry.focusFrame(
                    for: pane.id, panes: coordinator.panes.map(\.id),
                    primary: coordinator.primaryPaneID, layout: coordinator.layout,
                    corner: coordinator.corner, insetSize: coordinator.insetSize,
                    expanded: coordinator.expandedPaneID, size: size,
                    chromeVisible: true, isEditing: coordinator.isEditingLayout,
                    aspectRatio: pane.videoAspectRatio.map { CGFloat($0) },
                    editingInsets: editingInsets,
                    aspectRatios: LiveTVMultiviewGeometry.aspectRatios(in: coordinator.panes)
                )
                let visible = coordinator.expandedPaneID == nil || coordinator.expandedPaneID == pane.id
                if visible {
                    let pictureFrame = LiveTVMultiviewGeometry.presentationFrame(
                        in: frame, aspectRatio: pane.videoAspectRatio.map { CGFloat($0) },
                        focusActive: showsFocusPresentation, layout: coordinator.layout)
                    LiveTVMultiviewPaneControl(
                        pane: pane, audible: coordinator.audiblePaneID == pane.id,
                        focusFrame: focusFrame.offsetBy(dx: -frame.minX, dy: -frame.minY),
                        pictureFrame: pictureFrame.offsetBy(dx: -frame.minX, dy: -frame.minY),
                        isInteractive: visible, chromeVisible: chromeVisible,
                        showsOutline: paneOutlineVisible, focusScope: focusScope,
                        nativeFocused: focusedPaneID == pane.id,
                        preparedWhileFocused: { preparedWhileFocused(pane.id) },
                        fallbackFocusChanged: { fallbackFocusChanged(pane.id, $0) },
                        activate: { activate(pane.id) }, editing: editing,
                        listen: { coordinator.selectAudio(pane.id) },
                        promote: { coordinator.promote(pane.id) },
                        replace: { replace(pane.id) },
                        remove: coordinator.panes.count > 1 ? { coordinator.remove(pane.id) } : nil,
                        retry: { coordinator.retry(pane.id) }
                    )
                    .frame(width: frame.width, height: frame.height)
                    #if os(tvOS)
                    .allowsHitTesting(pane.preparation.current == nil || pane.preparation.failure != nil)
                    #endif
                    .position(x: frame.midX - viewport.minX, y: frame.midY - viewport.minY)
                    .zIndex(pane.id == coordinator.primaryPaneID ? 0 : 1)
                    #if os(tvOS)
                    .animation(reduceMotion ? nil : MultiviewMotion.animation, value: frame)
                    .animation(reduceMotion ? nil : MultiviewMotion.animation, value: focusFrame)
                    .animation(reduceMotion ? nil : MultiviewMotion.animation, value: pictureFrame)
                    #endif
                }

            }
        }
        // Prepared pictures own native focus in the retained video layer below this overlay.
        .frame(width: viewport.width, height: viewport.height, alignment: .topLeading)
        #if os(tvOS)
        .focusScope(focusScope)
        #endif
        .position(x: viewport.midX, y: viewport.midY)
        #if os(tvOS)
        .animation(reduceMotion ? nil : MultiviewMotion.animation, value: viewport)
        #endif
    }

    private var paneOutlineVisible: Bool {
        #if os(tvOS)
        false
        #else
        coordinator.isEditingLayout
        #endif
    }
}

private struct LiveTVMultiviewChrome: View {
    let coordinator: LiveTVMultiviewCoordinator
    let safeAreaInsets: EdgeInsets
    let onEditingInsetsChange: (EdgeInsets) -> Void
    let exit: () -> Void
    let collapse: () -> Void
    let watch: () -> Void
    let setup: () -> Void
    let focusScope: Namespace.ID
    let restoresSetupFocus: Bool
    let setupFocused: () -> Void
    let editing: () -> Void
    let add: () -> Void
    let replace: () -> Void
    let isFavorite: Bool
    let toggleFavorite: (() -> Void)?
    @State private var toolbarHeight: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        #if os(iOS)
        LiveTVMultiviewTouchChrome(
            coordinator: coordinator, safeAreaInsets: safeAreaInsets,
            exit: exit, collapse: collapse, watch: watch, setup: setup,
            editing: editing, add: add, replace: replace,
            isFavorite: isFavorite, toggleFavorite: toggleFavorite,
            onEditingInsetsChange: onEditingInsetsChange
        )
        #else
        GeometryReader { geometry in
            LiveTVMultiviewToolbar(
                coordinator: coordinator, add: add,
                collapse: collapse, setup: setup, focusScope: focusScope,
                restoresSetupFocus: restoresSetupFocus, setupFocused: setupFocused, editing: editing,
                isFavorite: isFavorite, toggleFavorite: toggleFavorite
            )
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { toolbarHeight = $0 }
            .modifier(LiveTVMultiviewToolbarEntrance(reduceMotion: reduceMotion))
            .padding(.horizontal, 72)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, 24)
            .background {
                LinearGradient(colors: [.clear, .black.opacity(0.72)], startPoint: .top, endPoint: .bottom)
                    .allowsHitTesting(false)
            }
            .padding(.top, toolbarTop(in: geometry.size) + 24)
        }
        .focusScope(focusScope)
        .onChange(of: televisionEditingInsets, initial: true) { _, insets in
            guard toolbarHeight > 0 else { return }
            onEditingInsetsChange(insets)
        }
        #endif
    }

    private var televisionEditingInsets: EdgeInsets {
        EdgeInsets(top: 24, leading: 24, bottom: toolbarHeight + 48, trailing: 24)
    }

    private func toolbarTop(in size: CGSize) -> CGFloat {
        let bottom = coordinator.panes
            .filter { coordinator.expandedPaneID == nil || coordinator.expandedPaneID == $0.id }
            .reduce(CGFloat.zero) { bottom, pane in
                let slot = LiveTVMultiviewGeometry.frame(
                    for: pane.id, panes: coordinator.panes.map(\.id), primary: coordinator.primaryPaneID,
                    layout: coordinator.layout, corner: coordinator.corner, insetSize: coordinator.insetSize,
                    expanded: coordinator.expandedPaneID, size: size, isEditing: coordinator.isEditingLayout,
                    aspectRatio: pane.videoAspectRatio.map { CGFloat($0) },
                    editingInsets: televisionEditingInsets,
                    aspectRatios: LiveTVMultiviewGeometry.aspectRatios(in: coordinator.panes))
                return max(bottom, LiveTVMultiviewGeometry.contentFrame(
                    in: slot, aspectRatio: pane.videoAspectRatio.map { CGFloat($0) }).maxY)
        }
        return min(bottom, LiveTVMultiviewGeometry.viewport(
            in: size, isEditing: true, editingInsets: televisionEditingInsets).maxY)
    }
}

struct LiveTVMultiviewVideoEntrance: ViewModifier {
    let enabled: Bool
    let reduceMotion: Bool
    @State private var appeared = false

    func body(content: Content) -> some View {
        content
            .opacity(!enabled || appeared ? 1 : 0)
            .animation(reduceMotion ? nil : MultiviewMotion.animation, value: appeared)
            .onAppear { appeared = true }
    }
}

struct LiveTVMultiviewToolbarEntrance: ViewModifier {
    let reduceMotion: Bool
    @State private var appeared = false

    func body(content: Content) -> some View {
        content
            .opacity(reduceMotion || appeared ? 1 : 0)
            .offset(y: reduceMotion || appeared ? 0 : 20)
            .animation(reduceMotion ? nil : MultiviewMotion.animation, value: appeared)
            .onAppear { appeared = true }
    }
}

private struct LiveTVMultiviewPaneControl: View {
    let pane: LiveTVMultiviewPane
    let audible: Bool
    let focusFrame: CGRect
    let pictureFrame: CGRect
    let isInteractive: Bool
    let chromeVisible: Bool
    let showsOutline: Bool
    let focusScope: Namespace.ID
    let nativeFocused: Bool
    let preparedWhileFocused: () -> Void
    let fallbackFocusChanged: (Bool) -> Void
    let activate: () -> Void
    let editing: () -> Void
    let listen: () -> Void
    let promote: () -> Void
    let replace: () -> Void
    let remove: (() -> Void)?
    let retry: () -> Void
    @FocusState private var focused: Bool
    @State private var pendingFocus = false
    @Environment(\.themePalette) private var palette
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        ZStack(alignment: .top) {
            if pane.preparation.isPreparing, pane.preparation.current == nil {
                VideoLoadingPlaceholder()
                    .clipShape(RoundedRectangle(
                        cornerRadius: LiveTVMultiviewGeometry.videoCornerRadius, style: .continuous
                    ))
                    .frame(width: pictureFrame.width, height: pictureFrame.height)
                    .position(x: pictureFrame.midX, y: pictureFrame.midY)
            }
            #if os(tvOS)
            if pane.preparation.isPreparing, pane.preparation.current != nil {
                ProgressView()
                    .tint(.white)
                    .position(x: focusFrame.midX, y: focusFrame.midY)
            }
            #endif
            #if !os(tvOS)
            if chromeVisible {
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    LiveTVMultiviewCaption(pane: pane, audible: audible)
                }
                .frame(width: focusFrame.width, height: focusFrame.height)
                .position(x: focusFrame.midX, y: focusFrame.midY)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            #endif
            #if os(tvOS)
            if pane.preparation.current == nil {
                interactivePictureControl
            }
            #else
            interactivePictureControl
            #endif

            if let failure = pane.preparation.failure {
                LiveTVMultiviewFailure(
                    message: pane.preparation.playbackFailure?.message ?? failure.userDescription,
                    report: pane.preparation.playbackFailure.map(PlaybackDiagnosticReport.playback),
                    hasCurrentPicture: pane.preparation.current != nil,
                    retry: retry, replace: replace, remove: remove, editing: editing
                )
                .disabled(pane.preparation.isPreparing)
                .frame(width: focusFrame.width, height: focusFrame.height, alignment: .top)
                .position(x: focusFrame.midX, y: focusFrame.midY)
            }
        }
        .overlay {
            if chromeVisible && showsOutline {
                if nativeFocused {
                    PrototypeFocusOutline(cornerRadius: LiveTVMultiviewGeometry.videoCornerRadius)
                        #if os(tvOS)
                        .frame(width: pictureFrame.width, height: pictureFrame.height)
                        .position(x: pictureFrame.midX, y: pictureFrame.midY)
                        #endif
                } else {
                    #if !os(tvOS)
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(audible ? palette.accent : .white.opacity(0.15), lineWidth: 2)
                        .allowsHitTesting(false)
                    #endif
                }
            }
        }
        .foregroundStyle(.white)
        .onChange(of: focused) { _, value in
            if pane.preparation.current == nil {
                pendingFocus = value
                fallbackFocusChanged(value)
            } else if pendingFocus {
                pendingFocus = false
                preparedWhileFocused()
            }
        }
        .onChange(of: pane.preparation.current?.id) { _, current in
            if pendingFocus, current != nil, isInteractive {
                pendingFocus = false
                preparedWhileFocused()
            }
        }
    }

    private var interactivePictureControl: some View {
        pictureControl
            .disabled(!isInteractive || (pane.preparation.current == nil && pane.preparation.failure != nil))
            .accessibilityLabel(liveTVChannelLabel(pane.channel?.name))
            .accessibilityValue(audible ? Text("Audio on") : Text("Muted"))
            .accessibilityIdentifier("live-multiview-pane-\(pane.id.uuidString)")
            .contextMenu {
                #if !os(tvOS)
                Button("Listen", systemImage: "speaker.wave.2") { editing(); listen() }
                    .disabled(pane.preparation.current == nil)
                #endif
                Button("Make main video", systemImage: "rectangle.inset.filled") { editing(); promote() }
                    .disabled(pane.preparation.current == nil)
                Button("Replace channel", systemImage: "arrow.triangle.2.circlepath", action: replace)
                #if os(tvOS)
                if let remove {
                    Button("Remove", systemImage: "minus.circle", role: .destructive, action: remove)
                }
                #endif
            }
            #if os(tvOS)
            .frame(width: focusFrame.width, height: focusFrame.height)
            .position(x: focusFrame.midX, y: focusFrame.midY)
            #endif
    }

    @ViewBuilder
    private var pictureControl: some View {
        #if os(tvOS)
        Color.clear
            .accessibilityElement(children: .ignore)
            .focusableCard(
                isFocused: $focused, cornerRadius: LiveTVMultiviewGeometry.videoCornerRadius,
                isEnabled: isEnabled && isInteractive
                    && pane.preparation.current == nil && pane.preparation.failure == nil,
                action: activate
            )
            .prefersDefaultFocus(audible && pane.preparation.current != nil, in: focusScope)
        #else
        Button(action: activate) { Color.clear.contentShape(Rectangle()) }
            .buttonStyle(.plain)
        #endif
    }
}

#if os(tvOS)
struct LiveTVMultiviewFocusCaption: View {
    let channel: LiveTVPrototypeChannel?
    let isFocused: Bool
    @State private var expiredChannelID: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.playerUsesNativeGlass) private var nativeGlass
    @Environment(\.plozzReduceTransparency) private var reduceTransparency

    private var focusedChannelID: String? { isFocused ? channel?.id : nil }
    private var isVisible: Bool {
        focusedChannelID != nil && (voiceOver || expiredChannelID != focusedChannelID)
    }

    var body: some View {
        HStack(spacing: 12) {
            if let channel {
                if channel.logoURL != nil || channel.source == .plozz {
                    PrototypeStationMark(channel: channel, size: 32, cornerRadius: 6)
                }
                Text(verbatim: channel.name)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
            }
        }
        .foregroundStyle(.white)
        .padding(12)
        .background {
            let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
            if #available(tvOS 26.0, *), nativeGlass {
                PlayerNativeGlassSurface(shape)
            } else {
                shape.fill(.black.opacity(reduceTransparency ? 1 : 0.82))
            }
        }
        .opacity(isVisible ? 1 : 0)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: isVisible)
        .task(id: focusedChannelID) {
            expiredChannelID = nil
            guard let focusedChannelID else { return }
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            expiredChannelID = focusedChannelID
        }
    }
}
#endif

private struct LiveTVMultiviewCaption: View {
    let pane: LiveTVMultiviewPane
    let audible: Bool

    var body: some View {
        Group {
            #if os(iOS)
            ViewThatFits(in: .horizontal) {
                contents.fixedSize(horizontal: true, vertical: false)
                liveTVChannelLabel(pane.channel?.name).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            #else
            contents
            #endif
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(.black.opacity(0.7))
    }

    private var contents: some View {
        HStack(spacing: 10) {
            if audible { Image(systemName: "speaker.wave.2.fill") }
            liveTVChannelLabel(pane.channel?.name)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
            Spacer(minLength: 0)
            if pane.preparation.isPreparing { ProgressView().tint(.white) }
        }
    }
}

private struct LiveTVMultiviewFailure: View {
    let message: LocalizedStringResource
    let report: PlaybackDiagnosticReport?
    let hasCurrentPicture: Bool
    let retry: () -> Void
    let replace: () -> Void
    let remove: (() -> Void)?
    let editing: () -> Void
    @State private var showsDetails = false

    var body: some View {
        ViewThatFits(in: .vertical) {
            VStack(spacing: 12) {
                Text(message).font(.callout).multilineTextAlignment(.center)
                actions
            }
            actions
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: hasCurrentPicture ? nil : .infinity)
        .background(.black.opacity(0.78))
        .plozzSheet(isPresented: $showsDetails) {
            if let report { PlaybackDiagnosticDetailsSheet(report: report) }
        }
    }

    private var actions: some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                if report != nil {
                    LiveTVMultiviewAction(
                        title: "Details", symbol: "info.circle",
                        action: { showsDetails = true }, editing: editing
                    )
                }
                LiveTVMultiviewAction(title: "Retry", symbol: "arrow.clockwise", action: retry, editing: editing)
                LiveTVMultiviewAction(title: "Replace", symbol: "arrow.triangle.2.circlepath", action: replace, editing: editing)
                #if os(tvOS)
                if let remove {
                    Button("Remove", systemImage: "minus.circle", role: .destructive, action: remove)
                        .playerGlassButton(prominent: false)
                }
                #endif
            }
            HStack {
                if report != nil {
                    Button("Details", systemImage: "info.circle") { showsDetails = true }
                }
                Button("Retry", systemImage: "arrow.clockwise", action: retry)
                Button("Replace", systemImage: "arrow.triangle.2.circlepath", action: replace)
                #if os(tvOS)
                if let remove {
                    Button("Remove", systemImage: "minus.circle", role: .destructive, action: remove)
                }
                #endif
            }
            .labelStyle(.iconOnly)
        }
    }
}

private struct LiveTVMultiviewToolbar: View {
    let coordinator: LiveTVMultiviewCoordinator
    let add: () -> Void
    let collapse: () -> Void
    let setup: () -> Void
    let focusScope: Namespace.ID
    let restoresSetupFocus: Bool
    let setupFocused: () -> Void
    let editing: () -> Void
    let isFavorite: Bool
    let toggleFavorite: (() -> Void)?
    @FocusState private var layoutFocused: Bool
    @FocusState private var moreFocused: Bool

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 16) {
                if coordinator.canAdd {
                    LiveTVMultiviewAction(title: "Add channel", symbol: "plus", action: add, editing: editing)
                        .accessibilityIdentifier("live-multiview-add")
                }
                Menu {
                    LiveTVMultiviewLayoutOptions(coordinator: coordinator, setup: setup)
                } label: {
                    Label { Text("Layout") } icon: { layoutSymbol }
                    #if os(tvOS)
                        .labelStyle(.titleAndIcon)
                    #endif
                }
                .focused($layoutFocused)
                .onChange(of: layoutFocused) { _, focused in
                    if focused { editing(); setupFocused() }
                }
                #if os(tvOS)
                .prefersDefaultFocus(true, in: focusScope)
                .task(id: restoresSetupFocus) {
                    guard restoresSetupFocus else { return }
                    await Task.yield()
                    guard !Task.isCancelled else { return }
                    if layoutFocused { setupFocused() } else { layoutFocused = true }
                }
                #endif
                #if os(tvOS)
                .playerGlassButton(prominent: false)
                #else
                .plozzActionButton(role: .secondary)
                #endif
                .accessibilityIdentifier("live-multiview-layout")
                .accessibilityLabel(Text("Layout"))
                if toggleFavorite != nil || coordinator.expandedPaneID != nil {
                    Menu {
                        if let toggleFavorite {
                            Button(
                                isFavorite ? "Unfavorite" : "Favorite",
                                systemImage: isFavorite ? "star.fill" : "star",
                                action: toggleFavorite)
                                .accessibilityIdentifier("live-multiview-favorite")
                        }
                        if coordinator.expandedPaneID != nil {
                            Button(action: collapse) {
                                Label { Text("Show all") } icon: { layoutSymbol }
                            }
                            .accessibilityIdentifier("live-multiview-collapse")
                        }
                    } label: {
                        Label("More", systemImage: "ellipsis")
                            .labelStyle(.titleAndIcon)
                    }
                    .focused($moreFocused)
                    .onChange(of: moreFocused) { _, focused in
                        if focused { editing() }
                    }
                    .playerGlassButton(prominent: false)
                    .accessibilityIdentifier("live-multiview-more")
                    .accessibilityLabel(Text("More"))
                }
            }
            .padding(8)
        }
        .scrollIndicators(.hidden)
        .defaultScrollAnchor(.center, for: .alignment)
        .fixedSize(horizontal: false, vertical: true)
        .environment(\.colorScheme, .dark)
        #if os(tvOS)
        .background { VideoCardFocusReturnGuide().padding(.top, -24) }
        .focusSection()
        #endif
    }

    private var layoutSymbol: Image {
        MultiviewLayoutSymbol(
            layout: coordinator.layout, count: coordinator.panes.count,
            corner: coordinator.corner, insetSize: coordinator.insetSize).image
    }
}

struct LiveTVMultiviewLayoutOptions: View {
    let coordinator: LiveTVMultiviewCoordinator
    let setup: () -> Void
    var isPortrait = false

    var body: some View {
        Picker("Layout", selection: Binding(
            get: { coordinator.layout },
            set: { setup(); coordinator.layout = $0 }
        )) {
            ForEach(LiveTVMultiviewLayout.allCases, id: \.self) { layout in
                Label { Text(layout.title(count: coordinator.panes.count, isPortrait: isPortrait)) } icon: {
                    symbol(layout: layout, corner: coordinator.corner, size: coordinator.insetSize)
                }
                .tag(layout)
            }
        }
        .pickerStyle(.inline)
        if coordinator.layout == .corner {
            Picker("Position", selection: Binding(
                get: { coordinator.corner },
                set: { setup(); coordinator.corner = $0 }
            )) {
                ForEach(LiveTVMultiviewCorner.allCases, id: \.self) { corner in
                    Label { Text(corner.title) } icon: {
                        symbol(layout: .corner, corner: corner, size: coordinator.insetSize)
                    }
                    .tag(corner)
                }
            }
            .pickerStyle(.inline)
            Picker("Size", selection: Binding(
                get: { coordinator.insetSize },
                set: { setup(); coordinator.insetSize = $0 }
            )) {
                ForEach(LiveTVMultiviewInsetSize.allCases, id: \.self) { size in
                    Label { Text(size.title) } icon: {
                        symbol(layout: .corner, corner: coordinator.corner, size: size)
                    }
                    .tag(size)
                }
            }
            .pickerStyle(.inline)
        }
    }

    private func symbol(
        layout: LiveTVMultiviewLayout, corner: LiveTVMultiviewCorner, size: LiveTVMultiviewInsetSize
    ) -> Image {
        MultiviewLayoutSymbol(
            layout: layout, count: coordinator.panes.count, corner: corner,
            insetSize: size, isPortrait: isPortrait).image
    }
}

private func liveTVChannelLabel(_ name: String?) -> Text {
    if let name {
        Text(verbatim: name)
    } else {
        Text("Channel")
    }
}

private struct LiveTVMultiviewAction: View {
    let title: LocalizedStringResource
    let symbol: String
    let action: () -> Void
    var editing: () -> Void = {}
    @FocusState private var focused: Bool

    var body: some View {
        Button {
            editing()
            action()
        } label: {
            Label(title, systemImage: symbol)
            #if os(tvOS)
                .labelStyle(.titleAndIcon)
            #endif
        }
        #if os(tvOS)
        .playerGlassButton(prominent: false)
        #else
        .plozzActionButton(role: .secondary)
        #endif
        .focused($focused)
        .onChange(of: focused) { _, focused in
            if focused { editing() }
        }
    }
}
