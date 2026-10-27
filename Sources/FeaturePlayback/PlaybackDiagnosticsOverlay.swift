#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI

/// A compact, **non-interactive** heads-up panel that overlays the player with
/// live stream diagnostics, organized into logical sections.
///
/// Tuned for the living room: monospaced digits for stable columns, a Liquid
/// Glass surface (with a faint theme-aware scrim) for legibility over any frame,
/// and type sized to read from the couch. `allowsHitTesting(false)` is applied
/// by the host (`PlayerView`) so it never steals focus from the transport
/// controls.
struct PlaybackDiagnosticsOverlay: View {
    enum Presentation { case television, mobile }
    let diagnostics: PlaybackDiagnostics?
    var presentation: Presentation = .television
    var streamingError: StreamingQualityError?
    var televisionControlsLayout: SubtitleControlsLayout?

    @Environment(\.themePalette) private var palette
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.locale) private var locale

    @ViewBuilder
    var body: some View {
        if presentation == .mobile {
            GeometryReader { geometry in
                ScrollView {
                    mobileContent(width: geometry.size.width)
                        .padding(20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityIdentifier("playback-diagnostics-scroll")
            }
            .background { AppBackground(palette: palette) }
        } else {
            TelevisionDiagnosticsPlacement(controlsLayout: televisionControlsLayout) { width in
                televisionPanel(width: width)
            }
        }
    }

    func televisionPanel(width: CGFloat) -> some View {
        let columnWidth = max(0, (width - 96) / 3)
        return VStack(alignment: .leading, spacing: 0) {
            // Header with provider logo
            header

            if let diagnostics {
                sectionsGrid(for: diagnostics, columnWidth: columnWidth)
            } else {
                Text("Gathering metrics…")
                    .font(.system(size: 15, design: .monospaced))
                    .foregroundStyle(palette.secondaryText)
                    .padding(.top, 8)
            }
        }
        .padding(24)
        .frame(width: width, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .plozzGlassPanel(
            cornerRadius: PlozzTheme.Metrics.playerPanelCornerRadius,
            scrimOpacity: 0.45,
            refractEdgesOnly: true
        )
    }

    func mobileContent(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            if let streamingError {
                VStack(alignment: .leading, spacing: 8) {
                    Text(streamingError.userMessage).font(.callout)
                    if let code = streamingError.diagnosticCode { Text(verbatim: code).font(.caption.monospaced()) }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                if let provider = diagnostics?.sourceProvider {
                    Label {
                        Text("Playing from \(diagnostics?.serverName ?? provider.displayName)")
                    } icon: {
                        ProviderBrandMark(provider: provider, size: 20, showsBackground: false)
                            .frame(width: 20, height: 20)
                    }
                    .font(.headline)
                }
                if let engine = diagnostics?.engineName { Text(engine).font(.subheadline) }
                if diagnostics?.mode == .transcode {
                    Text("Video and audio details describe the current stream. Original-file details are shown separately.")
                        .font(.footnote)
                        .foregroundStyle(palette.secondaryText)
                }
            }
            if let diagnostics {
                LazyVGrid(
                    columns: Array(
                        repeating: GridItem(.flexible(minimum: 0), alignment: .topLeading),
                        count: width >= 700 && !dynamicTypeSize.isAccessibilitySize ? 2 : 1
                    ),
                    alignment: .leading, spacing: 24
                ) {
                    sourceSection(diagnostics)
                    videoSection(diagnostics)
                    audioSection(diagnostics)
                    if diagnostics.mode == .transcode { originalFileSection(diagnostics) }
                    subtitleSection(diagnostics)
                    if let live = diagnostics.liveStream { liveSection(live) }
                    playbackSection(diagnostics)
                    systemSection(diagnostics)
                }
            } else {
                Text("Gathering metrics…").foregroundStyle(palette.secondaryText)
            }
        }
        .foregroundStyle(palette.primaryText)
        #if os(iOS) || os(macOS)
        .textSelection(.enabled)
        #endif
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Playback Diagnostics")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(palette.primaryText)
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                if let provider = diagnostics?.sourceProvider {
                    HStack(spacing: 6) {
                        ProviderBrandMark(provider: provider, size: 14, showsBackground: false)
                            .frame(width: 14, height: 14)
                        Text("Playing from \(diagnostics?.serverName ?? provider.displayName)")
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let engine = diagnostics?.engineName {
                    Text(engine).fixedSize(horizontal: false, vertical: true)
                }
            }
            .font(.system(size: 14))
            .foregroundStyle(palette.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 16)
    }

    // MARK: - Sections

    @ViewBuilder
    private func sectionsGrid(for d: PlaybackDiagnostics, columnWidth: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 12) {
                sourceSection(d)
                if let live = d.liveStream {
                    liveSection(live)
                } else {
                    systemSection(d)
                }
            }
            .frame(width: columnWidth, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 12) {
                videoSection(d)
                audioSection(d)
                subtitleSection(d)
            }
            .frame(width: columnWidth, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 12) {
                playbackSection(d)
                if d.mode == .transcode { originalFileSection(d) }
                if d.liveStream != nil { systemSection(d) }
            }
            .frame(width: columnWidth, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func sourceSection(_ d: PlaybackDiagnostics) -> some View {
        section("SOURCE") {
            optionalRow("File", d.sourceFileNameText, lineLimit: presentation == .television ? 2 : nil)
            optionalRow("Size", d.sourceFileSizeText)
            row(LocalizedStringResource("Delivery", comment: "Playback diagnostics label for how media is delivered: direct play, remuxing, or server transcoding."),
                d.mode.displayName)
            optionalRow(LocalizedStringResource("Stream", comment: "Playback diagnostics label for the current stream host and transport format."), streamTransportText(d.streamTransport))
            if d.mode != .transcode {
                optionalRow(LocalizedStringResource("Container", comment: "Playback diagnostics label for the media container format, such as MKV or MP4."), containerText(d))
            }
        }
    }

    @ViewBuilder
    func videoSection(_ d: PlaybackDiagnostics) -> some View {
        section(d.mode == .transcode ? "CURRENT VIDEO" : "VIDEO") {
            if d.mode == .transcode {
                row(LocalizedStringResource("Codec", comment: "Playback diagnostics label for the video or audio encoding format."), d.videoCodecText)
                row("Resolution", d.resolutionWithQualityText)
            } else {
                optionalRow(LocalizedStringResource("Codec", comment: "Playback diagnostics label for the video or audio encoding format."), d.videoCodecText)
                optionalRow("Resolution", d.resolutionWithQualityText)
            }
            optionalRow(LocalizedStringResource("Frame Rate", comment: "Playback diagnostics label for video frames per second."),
                        presentation == .television ? compactFrameRate(d) : frameRateCombined(d))
            if d.mode == .transcode {
                if let bitrate = d.videoBitrate {
                    row(LocalizedStringResource("Estimated bitrate", comment: "Playback diagnostics label for the estimated bitrate of the current transcoded video."), PlaybackDiagnostics.formatBitrate(bitrate))
                }
            } else {
                optionalRow("Bitrate", PlaybackDiagnostics.formatBitrate(d.videoBitrate))
            }
            optionalRow(d.mode == .transcode ? Text("Stream") : Text("Source"), d.videoFormatText)
            optionalRow(LocalizedStringResource("Codec Tag", comment: "Playback diagnostics label for the technical codec identifier stored in the media container."), d.videoCodecTagText)
        }
    }

    @ViewBuilder
    private func audioSection(_ d: PlaybackDiagnostics) -> some View {
        section(d.mode == .transcode ? "CURRENT AUDIO" : "AUDIO") {
            if d.mode == .transcode {
                row(LocalizedStringResource("Codec", comment: "Playback diagnostics label for the video or audio encoding format."), d.audioCodecText)
                row("Channels", d.audioChannelsText)
            } else {
                optionalRow(LocalizedStringResource("Codec", comment: "Playback diagnostics label for the video or audio encoding format."), d.audioCodecText)
                optionalRow("Channels", d.audioChannelsText)
            }
            optionalRow(LocalizedStringResource("Sample Rate", comment: "Playback diagnostics label for the audio sampling frequency."), d.audioSampleRateText)
            optionalRow("Bitrate", d.audioBitrateText)
            if d.mode == .plozzigen {
                optionalRow(LocalizedStringResource("Encoding", comment: "Playback diagnostics: the active engine's audio encoding step, not the original recording's quality or the receiver's output."),
                            d.audioEncodingDescription)
                row(LocalizedStringResource("Processing", comment: "Playback diagnostics label for the engine's actual audio conversion or stream-copy pipeline."),
                    d.audioPipelineDescription ?? PlaybackDiagnostics.placeholder)
            }
            if presentation == .television {
                optionalRow(LocalizedStringResource("System output", comment: "Playback diagnostics: the current audio rendering mode reported by the operating system, not a detected physical speaker layout."),
                            systemOutputText(d.audioOutput))
            } else {
                optionalRow(LocalizedStringResource("System output", comment: "Playback diagnostics: the current audio rendering mode reported by the operating system, not a detected physical speaker layout."),
                            d.audioOutput?.renderingMode.map(audioOutputText))
                if let connections = d.audioOutput?.connections, let first = connections.first {
                    row(LocalizedStringResource("Connection", comment: "Playback diagnostics: the audio output connection type, such as HDMI, Bluetooth, or AirPlay."),
                        connections.dropFirst().reduce(audioOutputText(first)) { $0 + Text(verbatim: " · ") + audioOutputText($1) })
                }
            }
        }
    }

    private func originalFileSection(_ d: PlaybackDiagnostics) -> some View {
        let source = PlaybackDiagnostics.base(from: d.originalSource, mode: .directPlay)
        return section("ORIGINAL FILE") {
            optionalRow(LocalizedStringResource("Container", comment: "Playback diagnostics label for the media container format, such as MKV or MP4."), containerText(source))
            optionalRow(LocalizedStringResource("Video", comment: "Playback diagnostics label for the original file's video format and quality."), source.videoLineText)
            optionalRow("Audio", source.audioLineText)
        }
    }

    @ViewBuilder
    private func subtitleSection(_ d: PlaybackDiagnostics) -> some View {
        if d.subtitleText != PlaybackDiagnostics.placeholder {
            section("SUBTITLES") {
                row(LocalizedStringResource("Track", comment: "Playback diagnostics label for the selected subtitle track."), d.subtitleText)
            }
        }
    }

    /// The live channel's HLS session: route, delay behind the playlist's
    /// newest segment, rewind window, start-up cost and segment delivery.
    @ViewBuilder
    private func liveSection(_ live: PlaybackDiagnostics.LiveStreamFacts) -> some View {
        section(LocalizedStringResource("LIVE", comment: "Playback diagnostics section heading for live TV stream tracking.")) {
            optionalRow(LocalizedStringResource("Route", comment: "Playback diagnostics label for how the live engine plays the stream, such as native HLS."), live.route ?? PlaybackDiagnostics.placeholder)
            optionalRow(LocalizedStringResource("Playlist", comment: "Playback diagnostics label for the HLS playlist type, such as LIVE or EVENT."), live.playlistType ?? PlaybackDiagnostics.placeholder)
            optionalRow(LocalizedStringResource("Variant", comment: "Playback diagnostics label for the HLS quality level playing now: its resolution and bitrate."), live.variantText ?? PlaybackDiagnostics.placeholder)
            optionalRow(LocalizedStringResource("Behind live", comment: "Playback diagnostics label for how far playback trails the newest live segment."), live.behindText ?? PlaybackDiagnostics.placeholder)
            optionalRow(LocalizedStringResource("Rewind window", comment: "Playback diagnostics label for how far back a live stream can be rewound."), live.windowText ?? PlaybackDiagnostics.placeholder)
            optionalRow(LocalizedStringResource("Stream clock", comment: "Playback diagnostics label for the wall-clock time a live stream reports at the playhead."), live.programDate.map(streamClockText) ?? PlaybackDiagnostics.placeholder)
            optionalRow(LocalizedStringResource("Start-up", comment: "Playback diagnostics label for how long a live stream took to start."), live.startupText ?? PlaybackDiagnostics.placeholder)
            optionalRow(LocalizedStringResource("Segments", comment: "Playback diagnostics label for HLS segment requests, data transferred and late segments."), live.segmentsText ?? PlaybackDiagnostics.placeholder)
            optionalRow(LocalizedStringResource("Errors", comment: "Playback diagnostics label for the count of HLS errors the player logged."), live.errorsText ?? PlaybackDiagnostics.placeholder)
        }
    }

    private func streamClockText(_ date: Date) -> String { // l10n:content — locale-formatted time
        date.formatted(.dateTime.hour().minute().second())
    }

    @ViewBuilder
    private func playbackSection(_ d: PlaybackDiagnostics) -> some View {
        // Transport measurements stay separate from source video/audio facts.
        section("PLAYBACK") {
            optionalRow(d.mode == .plozzigen
                ? .init("AVPlayer time", comment: "Playback diagnostics label for the internal AVPlayer playback position. Keep AVPlayer unchanged.")
                : "Position", d.positionText)
            optionalRow(d.mode == .plozzigen
                ? .init("AVPlayer window", comment: "Playback diagnostics label for the internal AVPlayer seekable time range. Keep AVPlayer unchanged.")
                : .init("Seekable", comment: "Playback diagnostics label for the time range available for seeking."), seekWindowText(d.seekWindowFacts))
            optionalRow(LocalizedStringResource("State", comment: "Playback diagnostics label for the current player state."), d.playbackStateText)
            if presentation == .television {
                row(LocalizedStringResource("Buffer", comment: "Playback diagnostics label for the player's buffered media and buffer health."), compactBufferText(d))
            } else {
                row(LocalizedStringResource("Buffer", comment: "Playback diagnostics label for the player's buffered media and buffer health."), bufferStatusText(d.bufferStatusFacts))
                optionalRow(LocalizedStringResource("Engine buffer", comment: "Playback diagnostics label for media buffered ahead by the playback engine."), PlaybackDiagnostics.formatBuffer(d.engineBufferedSecondsAhead))
            }
            if let cache = d.sessionCache {
                let format = ByteCountFormatStyle(style: .binary, allowedUnits: [.mb, .gb], spellsOutZero: false)
                    .locale(locale)
                row(LocalizedStringResource("Cache storage", comment: "Playback diagnostics: whether buffered media is kept in memory or on disk."),
                    cache.storage == .memory
                        ? Text(LocalizedStringResource("playback.diagnostics.cache.memory", defaultValue: "Memory", comment: "Playback cache storage in RAM."))
                        : Text(LocalizedStringResource("playback.diagnostics.cache.disk", defaultValue: "Disk", comment: "Playback cache storage in temporary files.")))
                row("Playback cache",
                    "\(cache.residentBytes.formatted(format)) / \(cache.effectiveBudgetBytes.formatted(format))")
                if let target = cache.targetSeconds, target.isFinite, target > 0 {
                    row(LocalizedStringResource("Read-ahead target", comment: "Requested buffer duration, not the amount already buffered."),
                        Duration.seconds(target).formatted(
                            .units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2)
                                .locale(locale)))
                }
                if cache.byteLimitReached {
                    row(LocalizedStringResource("Read-ahead", comment: "Playback diagnostics: the current constraint on buffering ahead."),
                        cache.storage == .memory
                            ? Text(LocalizedStringResource("Memory limit reached", comment: "The playback read-ahead memory budget is full, not the device's total RAM."))
                            : Text(LocalizedStringResource("Cache limit reached", comment: "The playback read-ahead cache budget is full, not necessarily the device's disk.")))
                }
            }
            optionalRow(LocalizedStringResource("Stalls", comment: "Playback diagnostics label for the count of playback stalls."), d.stallCount.map(String.init) ?? PlaybackDiagnostics.placeholder)
            row(LocalizedStringResource("Dropped", comment: "Playback diagnostics label for dropped video frames."), "\(d.droppedFramesText) frames")
            optionalRow("Declared stream bitrate", d.indicatedBitrateText)
            optionalRow(LocalizedStringResource("Network throughput", comment: "Playback diagnostics label for measured network data transfer rate, not encoded media bitrate."), d.observedBitrateText)
        }
    }

    @ViewBuilder
    private func systemSection(_ d: PlaybackDiagnostics) -> some View {
        section("SYSTEM") {
            optionalRow(LocalizedStringResource("playback.diagnostics.device", defaultValue: "Device", comment: "Playback diagnostics label for the hardware model and operating system. Not the audio-language option that follows device settings."), d.deviceText)
            optionalRow(LocalizedStringResource("Disk", comment: "Playback diagnostics label for free and total device storage."), diskSpaceText(d.diskSpaceFacts))
            optionalRow(LocalizedStringResource("Memory", comment: "Playback diagnostics label for app memory usage."), d.memoryText)
            optionalRow(LocalizedStringResource("Thermal", comment: "Playback diagnostics label for the device's thermal condition."), d.thermalResource)
            optionalRow(LocalizedStringResource("Instances", comment: "Playback diagnostics label for live playback object counts."), d.liveInstancesText)
        }
    }

    // MARK: - Section builder

    @ViewBuilder
    private func section(_ title: LocalizedStringResource, @ViewBuilder rows: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(presentation == .mobile ? .caption.weight(.bold) : .system(size: 11, weight: .semibold))
                .foregroundStyle(palette.secondaryText.opacity(presentation == .mobile ? 1 : 0.6))
                .padding(.bottom, 1)
            if presentation == .mobile {
                VStack(alignment: .leading, spacing: 12) { rows() }
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 3) { rows() }
            }
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func optionalRow(_ label: LocalizedStringResource, _ value: String, lineLimit: Int? = nil) -> some View {   // l10n:content — diagnostic value
        if value != PlaybackDiagnostics.placeholder {
            row(Text(label), Text(verbatim: value), lineLimit: lineLimit)
        }
    }

    @ViewBuilder
    private func optionalRow(_ label: Text, _ value: String) -> some View {   // l10n:content — diagnostic value
        if value != PlaybackDiagnostics.placeholder {
            row(label, Text(verbatim: value))
        }
    }

    private func row(_ label: LocalizedStringResource, _ value: String) -> some View {   // l10n:content — diagnostic value
        row(Text(label), Text(verbatim: value))
    }

    /// Row overload for CoreModels-supplied copy resources (e.g. `PlaybackMode`,
    /// `ThermalLevel`, `audioOutputDescription`) — kept distinct from the
    /// `String` overload above so these values go through SwiftUI's catalog
    /// lookup instead of being rendered verbatim.
    private func row(_ label: LocalizedStringResource, _ value: LocalizedStringResource) -> some View {
        row(Text(label), Text(value))
    }

    @ViewBuilder
    private func optionalRow(_ label: LocalizedStringResource, _ value: LocalizedStringResource?) -> some View {
        if let value {
            row(label, value)
        }
    }

    @ViewBuilder
    private func optionalRow(_ label: LocalizedStringResource, _ value: Text?) -> some View {
        if let value {
            row(Text(label), value)
        }
    }

    private func row(_ label: LocalizedStringResource, _ value: Text) -> some View {
        row(Text(label), value)
    }

    @ViewBuilder
    private func row(_ label: Text, _ value: Text, lineLimit: Int? = nil) -> some View {
        if presentation == .mobile {
            MobileDiagnosticsRow(label: label, value: value)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                label
                    .font(.system(size: 14))
                    .foregroundStyle(palette.secondaryText)
                    .frame(width: 120, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                value
                    .font(.system(size: 14, weight: .medium).monospacedDigit())
                    .foregroundStyle(palette.primaryText)
                    .lineLimit(lineLimit)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    struct MobileDiagnosticsRow: View {
        let label: Text
        let value: Text
        @Environment(\.themePalette) private var palette

        var body: some View {
            VStack(alignment: .leading, spacing: 2) {
                label.font(.caption).foregroundStyle(palette.secondaryText)
                value.font(.callout.monospacedDigit())
                    .foregroundStyle(palette.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .combine)
        }
    }

    /// Composes the stream transport row from CoreModels facts: `hostAndPort`/
    /// `container`/`scheme` are content, "App-local" is our own copy word
    /// prefixed only when the facts say the delivery is local.
    private func streamTransportText(_ facts: PlaybackDiagnostics.StreamTransportFacts?) -> Text? {
        guard let facts else { return nil }
        let tag = facts.container ?? facts.scheme
        guard let host = facts.hostAndPort else {
            return tag.map { Text(verbatim: $0) }
        }
        var text = facts.isLocal ? Text("App-local ") + Text(verbatim: host) : Text(verbatim: host)
        if let tag {
            text = text + Text(verbatim: " · ") + Text(verbatim: tag)
        }
        return text
    }

    /// Composes the seekable-window row from CoreModels facts: `window`/
    /// `totalDuration` are content, "full timeline" / "server window …" are our
    /// own copy words.
    private func seekWindowText(_ facts: PlaybackDiagnostics.SeekWindowFacts?) -> Text? {
        guard let facts else { return nil }
        var text = Text(verbatim: facts.window)
        guard let totalDuration = facts.totalDuration else { return text }
        text = text + Text(" of ") + Text(verbatim: totalDuration) + Text(verbatim: " · ")
        if facts.coversWholeTimeline {
            return text + Text("full timeline")
        }
        if let trailingWindowSeconds = facts.trailingWindowSeconds {
            let secondsText = Duration.seconds(Int(trailingWindowSeconds.rounded()))
                .formatted(.units(allowed: [.seconds], width: .abbreviated))
            return text + Text("server window ") + Text(verbatim: secondsText)
        }
        return text
    }

    /// Composes the buffer-health row from CoreModels facts: `status` is our own
    /// copy word ("Buffering"/"Low"/"Healthy"), `secondsAhead` is content; the
    /// "… ahead" qualifier is our own copy word too.
    private func bufferStatusText(_ facts: PlaybackDiagnostics.BufferStatusFacts) -> Text {
        let base = facts.status.map { Text($0) } ?? Text(verbatim: PlaybackDiagnostics.placeholder)
        guard let secondsAhead = facts.secondsAhead else { return base }
        return base + Text(verbatim: " · ") + Text(verbatim: secondsAhead) + Text(" ahead")
    }

    /// Composes the disk-space row from CoreModels facts: both figures are
    /// content, "… free" is our own copy word.
    private func diskSpaceText(_ facts: PlaybackDiagnostics.DiskSpaceFacts?) -> Text? {
        guard let facts else { return nil }
        var text = Text(verbatim: facts.freeText) + Text(" free")
        if let totalText = facts.totalText {
            text = text + Text(verbatim: " / ") + Text(verbatim: totalText)
        }
        return text
    }

    // MARK: - Helpers

    private func compactParts(_ values: [String]) -> String {
        let parts = values.filter { $0 != PlaybackDiagnostics.placeholder && !$0.isEmpty }
        return parts.isEmpty ? PlaybackDiagnostics.placeholder : parts.joined(separator: " · ")
    }

    private func containerText(_ d: PlaybackDiagnostics) -> String {
        guard presentation == .television, let container = d.container?.trimmingCharacters(in: .whitespaces),
              !container.isEmpty else { return d.containerText }
        return container.uppercased()
    }

    private func compactFrameRate(_ d: PlaybackDiagnostics) -> String { // l10n:content — nominal and measured FPS
        let observed = d.observedFpsText
        return compactParts([d.frameRateText, observed == PlaybackDiagnostics.placeholder ? observed : "\(observed) live"])
    }

    private func systemOutputText(_ output: PlaybackDiagnostics.AudioOutput?) -> Text? {
        guard let output else { return nil }
        let parts = [output.renderingMode].compactMap { $0 } + output.connections
        guard let first = parts.first else { return nil }
        return parts.dropFirst().reduce(audioOutputText(first)) { $0 + Text(verbatim: " · ") + audioOutputText($1) }
    }

    private func audioOutputText(_ label: PlaybackDiagnostics.AudioOutput.Label) -> Text {
        switch label {
        case .localized(let resource): Text(resource)
        case .format(let value): Text(verbatim: value)
        }
    }

    private func compactBufferText(_ d: PlaybackDiagnostics) -> Text {
        let player = d.bufferStatusFacts
        var text = Text("Player") + Text(verbatim: " ") + Text(verbatim: player.secondsAhead ?? PlaybackDiagnostics.placeholder)
        if let status = player.status { text = text + Text(verbatim: " (") + Text(status) + Text(verbatim: ")") }
        let engine = PlaybackDiagnostics.formatBuffer(d.engineBufferedSecondsAhead)
        if engine != PlaybackDiagnostics.placeholder {
            text = text + Text(verbatim: " · ") + Text("Engine") + Text(verbatim: " ") + Text(verbatim: engine)
        }
        return text
    }

    /// Leading numeric token of a formatted value ("24 fps" → "24",
    /// "11.9 Mbps" → "11.9"), or `nil` for the placeholder. Lets a live/observed
    /// value be folded next to its nominal counterpart without repeating the unit.
    private func numericToken(_ text: String) -> String? {
        guard text != PlaybackDiagnostics.placeholder else { return nil }
        return text.split(separator: " ").first.map(String.init)
    }

    /// A nominal value with its live counterpart folded in as "nominal · N live"
    /// (unit shown once). Falls back to the live value alone when there's no
    /// nominal, or the placeholder when neither exists.
    private func withLive(nominal: String, live: String) -> String {   // l10n:content — diagnostic value
        if nominal != PlaybackDiagnostics.placeholder {
            guard let n = numericToken(live) else { return nominal }
            return "\(nominal) · \(n) live"
        }
        return live
    }

    /// Nominal frame rate with the live observed FPS folded in.
    private func frameRateCombined(_ d: PlaybackDiagnostics) -> String {
        withLive(nominal: d.frameRateText, live: d.observedFpsText)
    }

}

#Preview("Diagnostics HUD") {
    var d = PlaybackDiagnostics(
        videoCodec: "HEVC", audioCodec: "EAC3", audioChannels: 6, container: "mkv",
        mode: .directPlay, engineName: "AetherEngine v7.44.0",
        droppedVideoFrames: 0, frameRate: 23.976, observedFps: 23.9
    )
    d.serverName = "Brandoland"
    d.sourceProvider = .plex
    d.observedBitrate = 11_900_000
    return ZStack {
        LinearGradient(colors: [.cyan, .white, .orange], startPoint: .topLeading, endPoint: .bottomTrailing)
        PlaybackDiagnosticsOverlay(diagnostics: d)
    }
    .ignoresSafeArea()
}
#endif
