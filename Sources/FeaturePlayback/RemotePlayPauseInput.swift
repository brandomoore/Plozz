import Foundation

/// The two routes the Siri Remote's Play/Pause takes into the player, kept as one
/// viewer input.
///
/// While the video plays and the app owns Now Playing, tvOS hands the button to
/// MediaRemote, so it arrives as a system command through
/// ``VideoNowPlayingCoordinator`` instead of as a press on the input surface;
/// while paused it arrives as an ordinary press. The press path has always
/// revealed the transport and restarted its idle countdown. The command path
/// reaches only the view model, so without `onSystemCommand` a pause showed no
/// controls and an older countdown kept running as though the viewer had done
/// nothing.
///
/// Should both routes ever carry the same press, the second delivery lands on
/// the other path within `echoWindow` of the first. It is that press's echo, and
/// acting on it would toggle playback straight back, so it is dropped.
@MainActor
final class RemotePlayPauseInput {
    enum Path: Equatable {
        /// A press handled by the player's own input layer (surface, control bar,
        /// Skip button or Up Next card).
        case press
        /// A play, pause or toggle command delivered through Now Playing.
        case systemCommand
    }

    /// Longest gap between two deliveries of one press. Deliberate presses on
    /// alternating paths (pause by command, resume by press) come ~1s apart on
    /// device, so this stays well clear of a real follow-up press.
    static let echoWindow: TimeInterval = 0.3

    /// Set by the input controller that draws the shared transport. The view model
    /// calls it after applying a system command's intent, so the reveal and the
    /// restarted countdown read the new paused state.
    var onSystemCommand: (@MainActor () -> Void)?

    private let now: () -> TimeInterval
    private var last: (path: Path, at: TimeInterval)?

    init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.now = now
    }

    /// Records a Play/Pause arriving on `path` and returns whether to act on it.
    /// `false` means the other path delivered this same press a moment ago.
    func admit(_ path: Path) -> Bool {
        let at = now()
        if let last, last.path != path, at - last.at < Self.echoWindow {
            // One press has at most one echo; whatever follows is new input.
            self.last = nil
            return false
        }
        last = (path, at)
        return true
    }
}
