#if canImport(SwiftUI)
import CoreModels
import CoreUI
import SwiftUI

public struct PlaybackReadAheadControl: View {
    @AppStorage private var selection: PlaybackReadAhead

    public init(defaults: UserDefaults = .standard) {
        _selection = AppStorage(
            wrappedValue: PlaybackReadAhead.default,
            PlaybackReadAheadStore.storageKey,
            store: defaults
        )
    }

    public var body: some View {
        SettingsDescribedControl {
            #if os(tvOS)
            SettingsMenuRow(title: "Video buffer", value: Text(selection.title)) {
                picker
            }
            .accessibilityIdentifier("playback-read-ahead")
            #else
            picker.accessibilityIdentifier("playback-read-ahead")
            #endif
        } description: {
            PlaybackReadAheadHelp()
        }
    }

    private var picker: some View {
        Picker("Video buffer", selection: $selection) {
            ForEach(PlaybackReadAhead.allCases, id: \.self) { Text($0.title).tag($0) }
        }
    }
}

private struct PlaybackReadAheadHelp: View {
    var body: some View {
        Text("Larger buffers use more temporary storage. Duration depends on the video and available space. Unavailable with Apple’s native player.")
            .fixedSize(horizontal: false, vertical: true)
    }
}

public struct LivePlaybackBufferControl: View {
    @AppStorage private var selection: LivePlaybackBuffer

    public init(defaults: UserDefaults = .standard) {
        _selection = AppStorage(
            wrappedValue: LivePlaybackBuffer.default,
            LivePlaybackBufferStore.storageKey,
            store: defaults
        )
    }

    public var body: some View {
        SettingsDescribedControl {
            #if os(tvOS)
            SettingsMenuRow(title: "Live TV buffer", value: Text(selection.title)) {
                picker
            }
            .accessibilityIdentifier("live-playback-buffer")
            #else
            picker.accessibilityIdentifier("live-playback-buffer")
            #endif
        } description: {
            help
        }
    }

    private var picker: some View {
        Picker("Live TV buffer", selection: $selection) {
            ForEach(LivePlaybackBuffer.allCases, id: \.self) { Text($0.title).tag($0) }
        }
    }

    private var help: some View {
        Text("More buffering can reduce interruptions, but adds live delay and may slow channel changes.")
            .fixedSize(horizontal: false, vertical: true)
    }
}
#endif
