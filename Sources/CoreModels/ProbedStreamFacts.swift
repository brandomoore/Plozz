import Foundation

/// Real, per-file technical facts obtained by PROBING a file's own headers —
/// independent of any provider/server metadata. This is how the app gets accurate
/// resolution / dynamic range / audio for SMB shares, which carry no server-side
/// description. Codable so it can be persisted in the per-file cache.
///
/// Every field is optional and asserted only when the probe actually resolved it:
/// a `nil` means "not known", and the UI must render nothing for it rather than
/// guessing. Notably, the Dolby Vision *profile number* is NOT carried here (the
/// engine's header probe can say "this is Dolby Vision" but does not reliably
/// resolve profile 5 vs 8.1), so DoVi is surfaced for DISPLAY only, never fed into
/// playback-compatibility prediction.
public struct ProbedStreamFacts: Codable, Hashable, Sendable {
    public var videoWidth: Int?
    public var videoHeight: Int?
    /// Provider-agnostic dynamic-range token (matches Jellyfin's vocabulary the rest
    /// of the app uses): "SDR" / "HDR10" / "HDR10Plus" / "HLG" / "DOVI". nil = unknown.
    public var videoRangeType: String?
    /// Positive HDR10+ metadata evidence, independent of the primary range.
    /// Dolby Vision remains DOVI even when the same file also carries HDR10+.
    /// nil (including in older persisted facts) means unconfirmed, not absent.
    public var carriesHDR10PlusMetadata: Bool?
    public var videoCodec: String?
    /// Demuxer stream index for the probed/default audio track.
    public var audioTrackID: Int?
    public var audioCodec: String?
    public var audioChannels: Int?
    public var audioIsAtmos: Bool
    public var durationSeconds: Double?

    public init(
        videoWidth: Int? = nil,
        videoHeight: Int? = nil,
        videoRangeType: String? = nil,
        videoCodec: String? = nil,
        audioTrackID: Int? = nil,
        audioCodec: String? = nil,
        audioChannels: Int? = nil,
        audioIsAtmos: Bool = false,
        durationSeconds: Double? = nil,
        carriesHDR10PlusMetadata: Bool? = nil
    ) {
        self.videoWidth = videoWidth
        self.videoHeight = videoHeight
        self.videoRangeType = videoRangeType
        self.carriesHDR10PlusMetadata = carriesHDR10PlusMetadata == true ? true : nil
        self.videoCodec = videoCodec
        self.audioTrackID = audioTrackID
        self.audioCodec = audioCodec
        self.audioChannels = audioChannels
        self.audioIsAtmos = audioIsAtmos
        self.durationSeconds = durationSeconds
    }
}

public extension ProbedStreamFacts {
    /// Combines independent inspections of the same file representation. A
    /// bounded unknown/negative scan cannot erase a positive confirmation.
    /// Audio evidence from a different track cannot relabel the default track.
    func merging(_ newer: ProbedStreamFacts) -> ProbedStreamFacts {
        var copy = self
        copy.videoWidth = newer.videoWidth ?? videoWidth
        copy.videoHeight = newer.videoHeight ?? videoHeight
        copy.videoCodec = newer.videoCodec ?? videoCodec
        copy.videoRangeType = Self.mergedVideoRange(
            existing: videoRangeType, incoming: newer.videoRangeType
        )
        copy.carriesHDR10PlusMetadata =
            carriesHDR10PlusMetadata == true || newer.carriesHDR10PlusMetadata == true ? true : nil
        copy.durationSeconds = newer.durationSeconds ?? durationSeconds
        if audioTrackID == nil || newer.audioTrackID == nil || audioTrackID == newer.audioTrackID {
            copy.audioTrackID = audioTrackID ?? newer.audioTrackID
            copy.audioCodec = audioCodec ?? newer.audioCodec
            copy.audioChannels = audioChannels ?? newer.audioChannels
            copy.audioIsAtmos = audioIsAtmos || newer.audioIsAtmos
        }
        return copy
    }

    /// Merges authoritative probe output into existing source metadata. Unknown
    /// fields remain untouched and a negative Atmos result never clears a profile
    /// previously confirmed by a provider.
    func applying(to metadata: MediaSourceMetadata? = nil) -> MediaSourceMetadata {
        var copy = metadata ?? MediaSourceMetadata()
        if videoCodec != nil || videoWidth != nil || videoHeight != nil || videoRangeType != nil {
            var video = copy.video ?? MediaSourceMetadata.VideoStream()
            if let videoCodec { video.codec = videoCodec }
            if let videoWidth { video.width = videoWidth }
            if let videoHeight { video.height = videoHeight }
            video.videoRangeType = Self.mergedVideoRange(
                existing: video.videoRangeType,
                existingKind: SourceDynamicRange.providerHint(from: copy),
                incoming: videoRangeType
            )
            copy.video = video
        }
        if audioCodec != nil || audioChannels != nil || audioIsAtmos {
            var audio = copy.audio ?? MediaSourceMetadata.AudioStream()
            if let audioCodec { audio.codec = audioCodec }
            if let audioChannels { audio.channels = audioChannels }
            if audioIsAtmos { audio.profile = "Dolby Atmos" }
            copy.audio = audio
        }
        return copy
    }

    fileprivate static func mergedVideoRange(
        existing: String?,
        existingKind: SourceDynamicRange? = nil,
        incoming: String?
    ) -> String? {
        guard let incoming else { return existing }
        let incomingKind = SourceDynamicRange.classify(videoRangeType: incoming)
        switch existingKind ?? SourceDynamicRange.classify(videoRangeType: existing) {
        case .dolbyVision, .hlg, .sdr:
            return existing
        case .hdr10Plus:
            return incomingKind == .dolbyVision ? incoming : existing
        case .hdr10:
            return incomingKind == .dolbyVision || incomingKind == .hdr10Plus ? incoming : existing
        case nil:
            return incoming
        }
    }
}

public extension MediaSourceMetadata {
    /// Additively records an authoritative Atmos confirmation.
    func confirmingAtmos() -> MediaSourceMetadata {
        ProbedStreamFacts(audioIsAtmos: true).applying(to: self)
    }

    func confirmingHDR10Plus() -> MediaSourceMetadata {
        guard SourceDynamicRange.providerHint(from: self) != .dolbyVision else { return self }
        return ProbedStreamFacts(videoRangeType: "HDR10Plus").applying(to: self)
    }
}

public extension MediaItem {
    /// Applies authoritative delayed probe output to the item and the version the
    /// user will play so detail, picker, and playback surfaces agree.
    func applyingSupplementalStreamFacts(_ facts: ProbedStreamFacts) -> MediaItem {
        var copy = self
        copy.mediaInfo = facts.applying(to: copy.mediaInfo)
        if copy.runtime == nil, let durationSeconds = facts.durationSeconds {
            copy.runtime = durationSeconds
        }
        let targetVersionID = copy.selectedVersionID
            ?? copy.versions.first(where: \.isDefault)?.id
            ?? copy.versions.first?.id
        copy.versions = copy.versions.map { version in
            var version = version
            guard version.id == targetVersionID else { return version }
            if let videoWidth = facts.videoWidth { version.width = videoWidth }
            if let videoHeight = facts.videoHeight { version.height = videoHeight }
            if let videoCodec = facts.videoCodec { version.videoCodec = videoCodec }
            if version.duration == nil { version.duration = facts.durationSeconds }
            version.videoRange = ProbedStreamFacts.mergedVideoRange(
                existing: version.videoRange,
                existingKind: SourceDynamicRange.classify(videoRangeType: version.videoRange)
                    ?? SourceDynamicRange.providerHint(from: version.sourceMetadata),
                incoming: facts.videoRangeType
            )
            if let audioCodec = facts.audioCodec { version.audioCodec = audioCodec }
            if let audioChannels = facts.audioChannels { version.audioChannels = audioChannels }
            if facts.audioIsAtmos { version.audioProfile = "Dolby Atmos" }
            let versionMetadata = ProbedStreamFacts(videoRangeType: version.videoRange)
                .applying(to: version.sourceMetadata)
            version.sourceMetadata = facts.applying(to: versionMetadata)
            return version
        }
        return copy
    }

    /// Additively records an authoritative Atmos confirmation.
    func confirmingAtmos() -> MediaItem {
        applyingSupplementalStreamFacts(ProbedStreamFacts(audioIsAtmos: true))
    }

    func confirmingHDR10Plus() -> MediaItem {
        guard SourceDynamicRange.providerHint(from: mediaInfo) != .dolbyVision else { return self }
        return applyingSupplementalStreamFacts(ProbedStreamFacts(videoRangeType: "HDR10Plus"))
    }
}

public struct SupplementalStreamProbeRequirements: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let atmos = Self(rawValue: 1 << 0)
    public static let hdr10Plus = Self(rawValue: 1 << 1)
    /// Network-file header metadata, independently of either packet scan.
    /// Every network probe reads headers; this also permits a headers-only probe.
    public static let streamDetails = Self(rawValue: 1 << 2)

    /// Shares have no authoritative server stream description. Inspect missing
    /// headers and independently request eligible audio/video confirmations;
    /// Aether, not the provider, decides which video codecs it can scan.
    public static func missingNetworkFileFacts(in metadata: MediaSourceMetadata?) -> Self {
        var result: Self = []
        let audioCodec = metadata?.audio?.codec?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if (audioCodec.isEmpty || audioCodec == "eac3"),
           metadata?.audio?.profile?.localizedCaseInsensitiveContains("atmos") != true {
            result.insert(.atmos)
        }
        let range = SourceDynamicRange.providerHint(from: metadata)
        if range == nil || range == .hdr10 {
            result.insert(.hdr10Plus)
        }
        if metadata?.video?.codec?.isEmpty != false
            || metadata?.video?.width == nil || metadata?.video?.height == nil
            || audioCodec.isEmpty || metadata?.audio?.channels == nil {
            result.insert(.streamDetails)
        }
        return result
    }

    public static func missingEmbyFacts(in metadata: MediaSourceMetadata?) -> Self {
        var result: Self = []
        if metadata?.audio?.codec?.lowercased() == "eac3",
           metadata?.audio?.profile?.localizedCaseInsensitiveContains("atmos") != true {
            result.insert(.atmos)
        }
        let range = SourceDynamicRange.providerHint(from: metadata)
        if ["hevc", "h265", "h.265"].contains(metadata?.video?.codec?.lowercased() ?? ""),
           range == nil || range == .hdr10 {
            result.insert(.hdr10Plus)
        }
        return result
    }
}

/// Probes a credential-free network file's headers for real stream facts.
/// Implemented by the engine layer and injected into providers so transport
/// packages never depend on the demuxer. Must run off the main actor.
public protocol NetworkFileStreamProbing: Sendable {
    /// Resolve `locator`, read its headers, and return the probed facts — or nil
    /// if the probe failed/timed out (the caller then shows nothing, never a guess).
    func probe(locator: NetworkFileLocator) async -> ProbedStreamFacts?
    /// Packet scans are independently selectable; `.streamDetails` asks only
    /// for headers. Implementations must preserve the file's default audio track.
    func probe(
        locator: NetworkFileLocator, requirements: SupplementalStreamProbeRequirements
    ) async -> ProbedStreamFacts?
}

public extension NetworkFileStreamProbing {
    func probe(
        locator: NetworkFileLocator, requirements: SupplementalStreamProbeRequirements
    ) async -> ProbedStreamFacts? {
        await probe(locator: locator)
    }
}

/// Probes a managed provider's credential-free authenticated HTTP locator.
/// Implementations resolve credentials only at the I/O boundary; the locator
/// and returned facts remain secret-free.
public protocol AuthenticatedHTTPStreamProbing: Sendable {
    func probe(locator: AuthenticatedHTTPPlaybackLocator) async -> ProbedStreamFacts?
    func probe(
        locator: AuthenticatedHTTPPlaybackLocator, requirements: SupplementalStreamProbeRequirements
    ) async -> ProbedStreamFacts?
}

public extension AuthenticatedHTTPStreamProbing {
    func probe(
        locator: AuthenticatedHTTPPlaybackLocator, requirements: SupplementalStreamProbeRequirements
    ) async -> ProbedStreamFacts? {
        await probe(locator: locator)
    }
}

/// Optional provider capability for delayed, authoritative stream inspection.
/// Detail pages invoke this only after first paint and never await it for Play.
public protocol SupplementalStreamFactsProviding: Sendable {
    func supplementalStreamFacts(for item: MediaItem) async -> ProbedStreamFacts?
}
