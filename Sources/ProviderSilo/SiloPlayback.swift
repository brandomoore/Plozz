import Foundation
import CoreModels
import CoreNetworking

struct SiloPlaybackDecision: Decodable, Sendable {
    struct Terminal: Decodable, Sendable { let reason: String }
    let protocol_version: Int
    let outcome: String
    let session_id: String?
    let playback_plan: SiloPlaybackPlan?
    let terminal: Terminal?
}

struct SiloPlaybackPlan: Decodable, Sendable {
    struct Recipe: Decodable, Sendable {
        let video_codec: String?
        let audio_codec: String?
        let width: Int?
        let height: Int?
        let bitrate_kbps: Int?
        let audio_channels: Int?
    }
    struct Warning: Decodable, Sendable { let code: String }
    struct Stream: Decodable, Sendable {
        let url: String
        let headers: [String: String]
        let header_refresh: String
    }
    struct Timeline: Decodable, Sendable {
        let source_start_seconds: Double
        let player_start_seconds: Double
        let timeline_offset_seconds: Double
        let can_seek_anywhere: Bool
    }
    struct Subtitles: Decodable, Sendable {
        let mode: String
        let track_id: String?
        let inventory: [Subtitle]
    }
    struct Subtitle: Decodable, Sendable {
        let track_id: String
        let combined_index: Int
        let source: String
        let codec: String?
        let language: String?
        let label: String?
        let forced: Bool
        let `default`: Bool
        let hearing_impaired: Bool
        let delivery: String
        let url: String?
    }
    let protocol_version: Int
    let session_id: String?
    let delivery: String
    let effective_media_file_id: String
    let stream: Stream
    let timeline: Timeline
    let subtitle: Subtitles
    let expires_at: String?
    let effective_recipe: Recipe?
    let degradation_warnings: [Warning]?
}

actor SiloPlaybackSessions {
    struct PendingLibraryStart: Sendable {
        let attemptID: String
        let itemID: String
        let installationID: String
        let body: Data
    }
    private struct PendingLibraryRelease {
        let itemID: String
        let installationID: String
        let stopID: String
    }
    struct Session: Sendable {
        let itemID: String
        let sourceID: String
        let installationID: String
        let expiry: Date?
        let streamURL: URL
        var isLibraryChannel = false
        var resources: [String: URL]
        var subtitleCandidates: [String: SiloRemoteSubtitle] = [:]
        var downloadedTracks: [String: MediaTrack] = [:]
        var sequence: Int64 = 0
        var stopID: String?
    }
    private var sessions: [String: Session] = [:]
    private var libraryStarts: [String: PendingLibraryStart] = [:]
    private var libraryReleases: [String: PendingLibraryRelease] = [:]

    func retainLibraryStart(_ start: PendingLibraryStart) { libraryStarts[start.attemptID] = start }
    func pendingLibraryStarts() -> [PendingLibraryStart] { Array(libraryStarts.values) }
    func removeLibraryStart(_ attemptID: String) { libraryStarts[attemptID] = nil }

    func retainLibraryRelease(id: String, itemID: String, installationID: String) {
        guard libraryReleases[id] == nil else { return }
        libraryReleases[id] = PendingLibraryRelease(
            itemID: itemID, installationID: installationID, stopID: UUID().uuidString.lowercased())
    }

    func insert(_ session: Session, id: String) throws {
        guard sessions.count < 128 || sessions[id] != nil else { throw AppError.invalidResponse }
        sessions[id] = session
    }

    func resource(_ locator: AuthenticatedHTTPPlaybackLocator) throws -> URL {
        guard let id = locator.playSessionID, let session = sessions[id],
              session.itemID == locator.itemID, session.sourceID == locator.mediaSourceID,
              session.stopID == nil,
              session.expiry.map({ $0 > Date() }) != false,
              let url = session.resources[locator.resource.path] else { throw AppError.notFound }
        return url
    }

    func subtitleSession(_ context: RemoteSubtitleContext) throws -> (id: String, session: Session) {
        guard let id = context.playSessionID, let session = sessions[id],
              session.itemID == context.itemID, session.sourceID == context.mediaSourceID,
              session.stopID == nil, session.expiry.map({ $0 > Date() }) != false else {
            throw RemoteSubtitleError.unsupportedPlayback
        }
        return (id, session)
    }

    func subtitleContext(itemID: String) throws -> RemoteSubtitleContext {
        let matches = sessions.filter {
            $0.value.itemID == itemID && $0.value.stopID == nil
                && $0.value.expiry.map({ $0 > Date() }) != false
        }
        guard matches.count == 1, let match = matches.first else { throw RemoteSubtitleError.unsupportedPlayback }
        return RemoteSubtitleContext(itemID: itemID, mediaSourceID: match.value.sourceID, playSessionID: match.key)
    }

    func cacheSubtitleCandidates(_ candidates: [SiloRemoteSubtitle], context: RemoteSubtitleContext) throws -> [RemoteSubtitle] {
        var (id, session) = try subtitleSession(context)
        guard candidates.count <= 512 else { throw AppError.invalidResponse }
        if session.subtitleCandidates.count + candidates.count > 512 {
            session.subtitleCandidates.removeAll()
        }
        let results = candidates.map { candidate in
            let key = UUID().uuidString
            session.subtitleCandidates[key] = candidate
            return candidate.presentation(id: key)
        }
        sessions[id] = session
        return results
    }

    func takeSubtitleCandidate(_ key: String, context: RemoteSubtitleContext) throws -> SiloRemoteSubtitle {
        var (id, session) = try subtitleSession(context)
        guard let candidate = session.subtitleCandidates.removeValue(forKey: key) else {
            throw RemoteSubtitleError.expiredSearch
        }
        sessions[id] = session
        return candidate
    }

    func registerSubtitle(_ track: MediaTrack, storedID: String, url: URL,
                          context: RemoteSubtitleContext) throws -> MediaTrack {
        var (id, session) = try subtitleSession(context)
        if let existing = session.downloadedTracks[storedID] { return existing }
        guard session.resources.count < 512, case .authenticatedHTTP(let locator) = track.deliverySource else {
            throw AppError.invalidResponse
        }
        session.resources[locator.resource.path] = url
        session.downloadedTracks[storedID] = track
        sessions[id] = session
        return track
    }

    func report(id: String, itemID: String, stopping: Bool, libraryChannel: Bool = false) throws -> (String, Int64, String?) {
        guard var session = sessions[id], session.itemID == itemID else { throw AppError.notFound }
        guard session.isLibraryChannel == libraryChannel else { throw AppError.unauthorized }
        guard session.stopID == nil || stopping else { throw AppError.cancelled }
        guard session.sequence < Int64.max else { throw AppError.invalidResponse }
        session.sequence += 1
        if stopping, session.stopID == nil { session.stopID = UUID().uuidString.lowercased() }
        sessions[id] = session
        return (session.installationID, session.sequence, session.stopID)
    }

    func remove(_ id: String) {
        sessions[id] = nil
        libraryReleases[id] = nil
    }

    func pendingLibraryReleases() -> [(id: String, itemID: String)] {
        sessions.compactMap { id, session in
            session.isLibraryChannel && session.stopID != nil ? (id, session.itemID) : nil
        } + libraryReleases.map { ($0.key, $0.value.itemID) }
    }

    func releaseContext(id: String, itemID: String, libraryChannel: Bool = false) -> (installationID: String, stopID: String)? {
        if libraryChannel, let pending = libraryReleases[id], pending.itemID == itemID {
            return (pending.installationID, pending.stopID)
        }
        guard var session = sessions[id], session.itemID == itemID,
              session.isLibraryChannel == libraryChannel else { return nil }
        if session.stopID == nil { session.stopID = UUID().uuidString.lowercased() }
        sessions[id] = session
        guard let stopID = session.stopID else { return nil }
        return (session.installationID, stopID)
    }
}

extension SiloProvider: ProviderHTTPResourceResolving {
    public func playbackInfo(for itemID: String) async throws -> PlaybackRequest {
        try await playbackInfo(for: itemID, mediaSourceID: nil, forceTranscode: false)
    }

    public func playbackInfo(for itemID: String, forceTranscode: Bool) async throws -> PlaybackRequest {
        try await playbackInfo(for: itemID, mediaSourceID: nil, forceTranscode: forceTranscode)
    }

    public func playbackInfo(for itemID: String, mediaSourceID: String?, forceTranscode: Bool) async throws -> PlaybackRequest {
        try await resolvePlayback(for: itemID, mediaSourceID: mediaSourceID, forceTranscode: forceTranscode, streaming: nil)
    }

    func resolvePlayback(
        for itemID: String, mediaSourceID: String?, forceTranscode: Bool,
        streaming: StreamingPlaybackOptions?, libraryChannel: LibraryChannelItem? = nil,
        externalPlayer: Bool = false
    ) async throws -> PlaybackRequest {
        let dto: SiloItem = try await client.request(
            "/catalog/items/\(try SiloAPI.pathComponent(itemID))",
            query: libraryChannel.map { [.init(name: "library_id", value: $0.library.libraryID)] } ?? [])
        var item = map(dto)
        if externalPlayer {
            guard !item.opensExternalSource, [.movie, .episode, .video].contains(item.kind) else {
                throw ExternalPlayerError.unsupportedSource
            }
        }
        let files = dto.versions ?? []
        HandoffDiagnostics.emit("silo playback metadata versions=\(files.count) explicitVersion=\(mediaSourceID != nil)")
        let selected = mediaSourceID.flatMap { id in files.first { $0.file_id == id } } ?? files.first
        guard let selected, mediaSourceID == nil || selected.file_id == mediaSourceID else { throw AppError.notFound }
        if let libraryChannel { try validateLibraryChannel(libraryChannel, detail: dto, file: selected) }
        let streamingSelection = try streaming.map {
            try SiloStreamingSelection(options: $0, source: selected, forceTranscode: forceTranscode)
        }
        func technicalValue(_ value: String) -> String {
            guard value.count <= 32, value.utf8.allSatisfy({
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                    || [UInt8(43), 45, 46, 95].contains($0)
            }) else { return "unrecognized" }
            return value
        }
        HandoffDiagnostics.emit("silo playback source container=\(technicalValue(selected.container)) video=\(technicalValue(selected.codec_video)) audio=\(technicalValue(selected.codec_audio))")
        let capability: SiloPlaybackCapabilities = try await client.request("/playback/capabilities")
        let fixedSourceSupported = capability.features.contains("fixed_media_file_v1")
        HandoffDiagnostics.emit("silo playback capabilities available=\(capability.state == "available") allowed=\(capability.allowed) protocol3=\(capability.protocol_versions.contains(3)) fixedSource=\(fixedSourceSupported) installation=\(capability.installation_id != nil)")
        guard capability.allowed else { throw StreamingQualityError.permissionDenied }
        guard capability.state == "available" else {
            throw StreamingQualityError.serverRefusal("Playback is unavailable on this Silo server.", reason: .providerUnavailable)
        }
        guard capability.protocol_versions.contains(3) else {
            throw StreamingQualityError.serverRefusal("This Silo server does not support the playback protocol Plozz requires.", reason: .protocolUnsupported)
        }
        guard let installationID = capability.installation_id, !installationID.isEmpty else {
            throw StreamingQualityError.malformedResponse
        }
        if libraryChannel != nil, !capability.deliveries.contains("original_http") {
            throw LibraryChannelError.incompatiblePlaybackMode
        }
        if streamingSelection?.requiresEncoding == true,
           !capability.deliveries.contains("server_transcode_hls") {
            throw StreamingQualityError.serverRefusal("Silo does not offer transcoding on this server.", reason: .transcodingDisabled)
        }
        let credential = try SiloCredential.decode(session.accessToken)
        let body = SiloPlaybackStart(
            installation_id: installationID, file_id: selected.file_id, profile_id: credential.profileID,
            capabilities: capabilitiesSnapshot, forceTranscode: forceTranscode,
            fixedSourceSupported: fixedSourceSupported, streaming: streamingSelection,
            libraryChannel: libraryChannel != nil, externalPlayer: externalPlayer)
        HandoffDiagnostics.emit(
            "silo playback request quality=\(body.quality_preference) "
                + "encoding=\(streamingSelection?.requiresEncoding ?? forceTranscode) "
                + "hdr10plus=\(selected.video_tracks?.first?.hdr10_plus == true) "
                + "dvProfile=\(selected.video_tracks?.first?.dv_profile ?? 0)"
        )
        let encodedBody = try JSONEncoder().encode(body)
        // Finish an admitted negotiation even if the view disappears, so its
        // session ID can be released rather than lost to cancellation.
        let negotiation = Task { [client] () throws -> SiloPlaybackDecision in
            do {
                return try await client.request("/playback/start", method: .post, body: encodedBody)
            } catch {
                guard libraryChannel != nil,
                      error is URLError || (error as? AppError) == .serverUnreachable else { throw error }
                // Native v2 replays the same playback_attempt_id and request digest.
                // Recover its ownership after a lost response; do not create a new attempt.
                return try await client.request("/playback/start", method: .post, body: encodedBody)
            }
        }
        let decision: SiloPlaybackDecision
        do {
            decision = try await negotiation.value
        } catch {
            if libraryChannel != nil,
               error is URLError || (error as? AppError) == .serverUnreachable {
                await playback.retainLibraryStart(.init(
                    attemptID: body.playback_attempt_id, itemID: itemID,
                    installationID: installationID, body: encodedBody))
            }
            throw error
        }
        let terminalReason = decision.terminal?.reason
        let safeReason = terminalReason.flatMap { value -> String? in
            guard value.count <= 80, value.utf8.allSatisfy({ (97...122).contains($0) || $0 == 95 }) else { return nil }
            return value
        } ?? "none"
        HandoffDiagnostics.emit("silo playback decision protocol=\(decision.protocol_version) playable=\(decision.outcome == "playable") plan=\(decision.playback_plan != nil) terminal=\(safeReason)")
        let ownedSessionID = decision.session_id ?? decision.playback_plan?.session_id
        do {
            try Task.checkCancellation()
            guard decision.protocol_version == 3, decision.outcome == "playable",
                  let plan = decision.playback_plan, plan.protocol_version == 3,
                  let sessionID = ownedSessionID, !sessionID.isEmpty else {
                throw SiloStreamingSelection.refusal(terminalReason)
            }
            let negotiatedCodec = try streamingSelection?.validate(plan)
            HandoffDiagnostics.emit("silo playback plan sameFile=\(plan.effective_media_file_id == selected.file_id) headers=\(plan.stream.headers.count) refreshNone=\(plan.stream.header_refresh == "none") offset=\(plan.timeline.timeline_offset_seconds) seekable=\(plan.timeline.can_seek_anywhere) original=\(plan.delivery == "original_http") hls=\(plan.delivery == "server_remux_hls" || plan.delivery == "server_transcode_hls")")
            guard plan.effective_media_file_id == selected.file_id else {
                throw StreamingQualityError.serverRefusal("Silo returned a different file than the selected version. Plozz stopped playback to avoid playing the wrong file.", reason: .sourceMismatch)
            }
            if libraryChannel != nil {
                guard plan.delivery == "original_http",
                      plan.timeline.source_start_seconds == 0, plan.timeline.player_start_seconds == 0 else {
                    throw LibraryChannelError.incompatiblePlaybackMode
                }
            }
            guard plan.stream.headers.isEmpty, plan.stream.header_refresh == "none" else {
                throw StreamingQualityError.serverRefusal("Silo returned stream headers or header refresh requirements that Plozz does not support.", reason: .unsupportedHeaders)
            }
            guard plan.timeline.timeline_offset_seconds == 0 else {
                throw StreamingQualityError.serverRefusal("Silo returned a playback timeline offset that Plozz does not support.", reason: .unsupportedTimeline)
            }
            guard plan.timeline.can_seek_anywhere else {
                throw StreamingQualityError.serverRefusal("Silo returned a stream without seeking support. Plozz requires a seekable stream for this playback path.", reason: .nonSeekable)
            }
            let mode: PlaybackDiagnostics.PlaybackMode
            let delivery: AuthenticatedHTTPDeliveryMode
            switch plan.delivery {
            case "original_http": mode = .directPlay; delivery = .directFile
            case "server_remux_hls": mode = .remux; delivery = .hls
            case "server_transcode_hls": mode = .transcode; delivery = .hls
            default:
                throw StreamingQualityError.serverRefusal("Silo returned a stream delivery format that Plozz does not support.", reason: .unsupportedDelivery)
            }
            guard let streamURL = resourceURL(plan.stream.url) else { throw StreamingQualityError.malformedResponse }
            if externalPlayer {
                try await client.validateExternalMediaLifetime(streamURL, duration: selected.duration)
            }
            var resources: [String: URL] = [:]
            func locator(url: URL, key: String, purpose: AuthenticatedHTTPResourcePurpose) throws -> AuthenticatedHTTPPlaybackLocator {
                let path = "silo/\(UUID().uuidString)/\(key)"
                resources[path] = url
                return try AuthenticatedHTTPPlaybackLocator(
                    provider: .silo, accountID: accountID, credentialRevision: credentialRevision,
                    itemID: itemID, mediaSourceID: selected.file_id, deliveryMode: delivery,
                    formatHint: .init(container: delivery == .hls ? "hls" : selected.container), purpose: purpose,
                    resource: AuthenticatedHTTPResource(pathBase: .configuredBaseURL, path: path), playSessionID: sessionID)
            }
            let stream = try locator(url: streamURL, key: "stream", purpose: .mediaStream)
            var subtitles: [MediaTrack] = []
            var downloadedTracks: [String: MediaTrack] = [:]
            for entry in plan.subtitle.inventory {
                guard let url = resourceURL(entry.url), entry.delivery != "burn_in_only" else { continue }
                let source = try locator(url: url, key: "subtitle", purpose: .subtitle)
                subtitles.append(MediaTrack(
                    id: entry.combined_index, kind: .subtitle,
                    displayTitle: entry.label ?? entry.language ?? entry.codec ?? String(entry.combined_index),
                    language: entry.language, codec: entry.codec,
                    isDefault: plan.subtitle.track_id == entry.track_id && plan.subtitle.mode == "render",
                    isForced: entry.forced, isHearingImpaired: entry.hearing_impaired,
                    deliverySource: .authenticatedHTTP(source), isExternal: true))
                if let storedID = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                    .first(where: { $0.name == "downloaded_subtitle_id" })?.value,
                   let track = subtitles.last {
                    downloadedTracks[storedID] = track
                }
            }
            let expiry = plan.expires_at.flatMap(Self.date)
            guard plan.expires_at == nil || expiry != nil else { throw StreamingQualityError.malformedResponse }
            if externalPlayer, let expiry, expiry.timeIntervalSinceNow <= selected.duration + 5 * 60 {
                throw ExternalPlayerError.unsupportedSource
            }
            try await playback.insert(.init(itemID: itemID, sourceID: selected.file_id, installationID: installationID,
                                            expiry: expiry, streamURL: streamURL,
                                            isLibraryChannel: libraryChannel != nil, resources: resources,
                                            downloadedTracks: downloadedTracks), id: sessionID)
            item.selectedVersionID = selected.file_id
            item.mediaInfo = metadata(selected)
            if let libraryChannel {
                item.runtime = selected.duration
                item.resumePosition = nil
                item.libraryID = libraryChannel.library.libraryID
            }
            var request = PlaybackRequest(
                item: item, playbackSource: .authenticatedHTTP(stream), playSessionID: sessionID,
                audioTracks: selected.playbackAudioTracks,
                subtitleTracks: subtitles, startPosition: libraryChannel == nil ? streaming?.startPosition ?? item.resumePosition ?? 0 : 0,
                deliveryMode: mode, sourceMetadata: item.mediaInfo, sourceProvider: .silo,
                serverName: session.server.name, sourceFileName: selected.file_name)
            // Session-bound stream grants are not offline-download permission.
            request.originalFileSource = nil
            request.streamingOptions = streaming
            request.streamingSessionID = streaming == nil && !externalPlayer ? nil : sessionID
            request.negotiatedStreamingVideoCodec = negotiatedCodec
            request.suppressOrdinaryWatchReporting = libraryChannel != nil
            return request
        } catch {
            if libraryChannel != nil {
                if let sessionID = ownedSessionID, !sessionID.isEmpty {
                    await playback.retainLibraryRelease(
                        id: sessionID, itemID: itemID, installationID: installationID)
                    let release = Task { try await releaseLibrarySession(id: sessionID, itemID: itemID) }
                    do { try await release.value }
                    catch { PlozzLog.playback.error("Unable to release unsupported Silo channel plan") }
                }
                throw error
            }
            struct Stop: Encodable { let installation_id: String; let stop_id: String }
            if let sessionID = ownedSessionID, !sessionID.isEmpty {
                do {
                    let stopBody = try JSONEncoder().encode(Stop(installation_id: installationID, stop_id: UUID().uuidString.lowercased()))
                    let release = Task { [client] in
                        try await client.send("/playback/\(try SiloAPI.pathComponent(sessionID))", method: .delete, body: stopBody)
                    }
                    _ = try await release.value
                    await playback.remove(sessionID)
                } catch {
                    PlozzLog.playback.error("Unable to release unsupported Silo playback plan")
                }
            }
            throw error
        }
    }

    public func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {
        try await reportSession(progress, event: event, libraryChannel: false)
    }

    func reportSession(_ progress: PlaybackProgress, event: PlaybackEvent, libraryChannel: Bool) async throws {
        guard let id = progress.playSessionID, progress.positionSeconds.isFinite, progress.positionSeconds >= 0 else {
            throw AppError.invalidResponse
        }
        let stopping = event == .stop
        let (installation, sequence, stopID) = try await playback.report(
            id: id, itemID: progress.itemID, stopping: stopping, libraryChannel: libraryChannel)
        struct Body: Encodable {
            let installation_id: String
            let sequence: Int64
            let position: Double
            let is_paused: Bool
            let stop_id: String?
        }
        struct Receipt: Decodable, Sendable { let outcome: String }
        let path = "/playback/\(try SiloAPI.pathComponent(id))" + (stopping ? "" : "/progress")
        let receipt: Receipt = try await client.request(
            path, method: stopping ? .delete : .post,
            body: JSONEncoder().encode(Body(installation_id: installation, sequence: sequence,
                                           position: progress.positionSeconds, is_paused: progress.isPaused, stop_id: stopID)))
        guard ["applied", "replayed", "stale_sample", "stopped"].contains(receipt.outcome) else {
            throw AppError.invalidResponse
        }
        if stopping { await playback.remove(id) }
    }

    public func resolveHTTPResource(_ locator: AuthenticatedHTTPPlaybackLocator) async throws -> URL {
        guard locator.provider == .silo, locator.accountID == accountID,
              locator.credentialRevision == credentialRevision else { throw AppError.unauthorized }
        try await client.validateLogin()
        let url = try await playback.resource(locator)
        guard let sessionID = locator.playSessionID else { throw AppError.unauthorized }
        return try await client.authorizedMediaURL(url, sessionID: sessionID)
    }
}

struct SiloPlaybackStart: Encodable {
    struct HDR: Encodable {
        let hdr10: Bool
        let hdr10_plus = false
        let hlg: Bool
        let dolby_vision_profiles: [Int]
    }
    struct Codecs: Encodable {
        let video_evidence = "declared"
        let audio_evidence = "declared"
        let codecs_video: [String]
        let codecs_video_hardware: [String]
        let codecs_audio: [String]
        let containers: [String]
        let hdr: Bool
        let hdr_details: HDR
    }
    struct Subtitles: Encodable {
        let embedded_text = false
        let sidecar_text = true
        let ass_styling = false
        let embedded_bitmap = false
        let sidecar_bitmap = false
        let font_attachments = false
    }
    struct Delivery: Encodable {
        let enabled: Bool
        let supported_on_device = true
        let containers: [String]
        let video_codecs: [String]
        let audio_decode_codecs: [String]
        let audio_passthrough_codecs: [String] = []
        let subtitles = Subtitles()
        let features: [String] = []
        let auth_header_refresh = false
        var validated_claims: [String] = []
        let transformations: [String] = []
        var max_channels: Int? = nil
    }
    struct Context: Encodable {
        struct Device: Encodable { let manufacturer = "Apple"; let platform: String }
        struct Output: Encodable { let hdr_details: HDR }
        let protocol_version = 3
        let form_factor: String
        let app_version: String
        let device: Device
        let output: Output
        let deliveries: [String: Delivery]
    }
    let installation_id: String
    let protocol_version = 3
    let client_features: [String]
    let file_id: String
    let profile_id: String
    let playback_attempt_id = UUID().uuidString.lowercased()
    let quality_preference: String
    let subtitle_fidelity_preference = "compatible"
    let metered = false
    let allow_alternate_versions: Bool?
    let start_position: Double
    let progress_persistence: String?
    let bandwidth_cap_kbps: Int?
    let audio_track_index: Int?
    let subtitle_track_index: Int?
    let client_capabilities: Codecs
    let client_playback_context: Context

    init(installation_id: String, file_id: String, profile_id: String, capabilities: MediaCapabilities,
         forceTranscode: Bool, fixedSourceSupported: Bool = true,
         streaming: SiloStreamingSelection? = nil, libraryChannel: Bool = false,
         externalPlayer: Bool = false) {
        self.installation_id = installation_id
        self.file_id = file_id
        self.profile_id = profile_id
        allow_alternate_versions = fixedSourceSupported ? false : nil
        client_features = ["playback_plan_v3", "sequenced_progress_v1"]
            + (fixedSourceSupported ? ["fixed_media_file_v1"] : [])
        quality_preference = streaming?.qualityPreference ?? (forceTranscode ? "1080p" : "original")
        start_position = streaming?.options.startPosition ?? 0
        progress_persistence = libraryChannel || externalPlayer ? "client" : nil
        bandwidth_cap_kbps = streaming?.videoBudgetKbps
        audio_track_index = streaming.flatMap { $0.options.selectedAudio(in: $0.source.playbackAudioTracks)?.id }
        subtitle_track_index = streaming.flatMap {
            $0.options.selectedSubtitle(in: $0.source.playbackSubtitleTracks)?.id
        }
        let hardwareVideo = capabilities.allowedDirectPlayVideoCodecs.map(\.rawValue)
        let video = MediaCapabilities.plozzigenVideoCodecs
        let audio = ["aac", "ac3", "eac3", "mp3", "alac", "flac", "opus", "vorbis", "dts", "truehd", "pcm_s16le", "pcm_s24le"]
        let containers = ["mp4", "mkv", "mov", "m4v", "mpegts", "ts"]
        let hdr = HDR(hdr10: capabilities.supportsHDR10, hlg: capabilities.supportsHLG,
                      dolby_vision_profiles: capabilities.supportsDolbyVision ? [5, 8] : [])
        client_capabilities = Codecs(codecs_video: video, codecs_video_hardware: hardwareVideo, codecs_audio: audio,
                                     containers: containers, hdr: capabilities.supportsHDR10 || capabilities.supportsHLG,
                                     hdr_details: hdr)
        #if os(tvOS)
        let platform = "tvos"
        let form = "tv"
        #else
        let platform = "ios"
        let form = "mobile"
        #endif
        client_playback_context = Context(
            form_factor: form, app_version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0",
            device: .init(platform: platform), output: .init(hdr_details: hdr),
            deliveries: [
                "original_http": Delivery(
                    enabled: streaming.map { !$0.requiresEncoding } ?? !forceTranscode,
                    containers: containers, video_codecs: video, audio_decode_codecs: audio,
                    // The original-file player resolves HDR presentation and
                    // selects audio locally; neither requires server conversion.
                    validated_claims: ["client_managed_dynamic_range_v1", "client_selected_audio_track_v1"]),
                "hls": Delivery(enabled: !libraryChannel, containers: ["hls", "mp4", "mpegts"], video_codecs: hardwareVideo,
                                audio_decode_codecs: ["aac", "ac3", "eac3", "alac"],
                                max_channels: streaming.flatMap {
                                    $0.requiresEncoding || $0.options.quality != .original ? 2 : nil
                                })
            ])
    }
}
