#if canImport(UIKit)
import UIKit

final class PlayerSurfacePanGestureRecognizer: UIPanGestureRecognizer {
    var click = RemoteClickInterpreter()
    private(set) var contactStartTimestamp: TimeInterval?
    private(set) var sampleTimestamp: TimeInterval?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        click.touchBegan()
        contactStartTimestamp = event.timestamp
        sampleTimestamp = event.timestamp
        ScrubDiagnostics.note("remote-touch began")
        super.touchesBegan(touches, with: event)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        sampleTimestamp = event.timestamp
        super.touchesMoved(touches, with: event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        sampleTimestamp = event.timestamp
        ScrubDiagnostics.note("remote-touch ended click=\(click.suppressesPan)")
        super.touchesEnded(touches, with: event)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        sampleTimestamp = event.timestamp
        super.touchesCancelled(touches, with: event)
    }
}
#endif

#if os(tvOS)
import GameController

/// Reads the old remote's absolute position without taking input away from UIKit.
/// No GameController handlers are installed: menus retain native focus behavior.
@MainActor
final class RemoteTouchInput {
    private var pads: [(pad: GCMicroGamepad, originalAbsolute: Bool)] = []

    func start() {
        stop()
        NotificationCenter.default.addObserver(
            self, selector: #selector(controllersChanged),
            name: .GCControllerDidConnect, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(controllersChanged),
            name: .GCControllerDidDisconnect, object: nil)
        refreshControllers()
    }

    func stop() {
        NotificationCenter.default.removeObserver(self)
        for (pad, originalAbsolute) in pads {
            pad.reportsAbsoluteDpadValues = originalAbsolute
        }
        pads.removeAll()
    }

    func pressedPosition(at timestamp: TimeInterval) -> RemoteClickInterpreter.Position? {
        refreshControllers()
        let nowUptime = ProcessInfo.processInfo.systemUptime
        let nowUnixTime = Date().timeIntervalSince1970
        for (pad, _) in pads {
            let snapshot = pad.capture()
            let inputUnixTime = pad.lastEventTimestamp
            let age = nowUnixTime - (nowUptime - timestamp) - inputUnixTime
            ScrubDiagnostics.note(
                "remote-click-sample x=\(snapshot.dpad.xAxis.value) y=\(snapshot.dpad.yAxis.value) "
                    + "pressed=\(snapshot.buttonA.isPressed) age=\(age)")
            // UIKit may deliver a short click after GameController has already
            // published its release. Match the event streams by timestamp rather
            // than requiring the button to still be physically down.
            guard RemoteClickInterpreter.matchesInput(
                pressUptime: timestamp, inputUnixTime: inputUnixTime,
                nowUptime: nowUptime, nowUnixTime: nowUnixTime) else { continue }
            return .init(x: snapshot.dpad.xAxis.value, y: snapshot.dpad.yAxis.value)
        }
        return nil
    }

    @objc private func controllersChanged() {
        refreshControllers()
    }

    private func refreshControllers() {
        let connected = GCController.controllers().compactMap { controller -> GCMicroGamepad? in
            guard let pad = controller.microGamepad, !(pad is GCDirectionalGamepad) else { return nil }
            return pad
        }
        pads.removeAll { entry in
            guard !connected.contains(where: { $0 === entry.pad }) else { return false }
            entry.pad.reportsAbsoluteDpadValues = entry.originalAbsolute
            return true
        }
        for pad in connected where !pads.contains(where: { $0.pad === pad }) {
            pads.append((pad, pad.reportsAbsoluteDpadValues))
            pad.reportsAbsoluteDpadValues = true
            ScrubDiagnostics.note("remote-controller connected first-generation touchpad")
        }
    }
}
#endif
