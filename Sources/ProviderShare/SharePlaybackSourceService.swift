import Foundation
import CoreModels
import CoreNetworking
import MediaTransportCore

/// Owns share file-access policy for playback: resolving a credential-free
/// `NetworkFileLocator` (with a stable representation identity), discovering text
/// sidecar subtitles next to a video, and the opt-in on-device stream-probe
/// measurement. It depends only on the live file-tree `ShareLibraryStore` and the
/// engine prober — never on the catalog — so it is a clean, independently testable
/// boundary. `ShareProvider` delegates here and keeps only playback orchestration.
struct SharePlaybackSourceService: Sendable {
    private let store: ShareLibraryStore
    private let streamProber: NetworkFileStreamProbing?
    private let accountID: String
    private let credentialRevision: CredentialRevision

    init(
        store: ShareLibraryStore,
        streamProber: NetworkFileStreamProbing?,
        accountID: String,
        credentialRevision: CredentialRevision
    ) {
        self.store = store
        self.streamProber = streamProber
        self.accountID = accountID
        self.credentialRevision = credentialRevision
    }

    func networkFileLocator(for relativePath: String) async throws -> NetworkFileLocator {
        HandoffDiagnostics.emit(
            "shareLocator file=\(HandoffDiagnostics.correlationID(relativePath)) stage=statForOpening"
        )
        let entry = try await store.statForOpening(relativePath: relativePath)
        return try networkFileLocator(for: relativePath, entry: entry)
    }

    func networkDiscLocator(for indexPath: String) async throws -> NetworkDiscLocator {
        let directory = (indexPath as NSString).deletingLastPathComponent
        let entries = try await store.rawEntries(inDirectory: directory)
        guard let disc = try await ShareBluRayFolder.discover(in: directory, entries: entries, list: {
            try await store.rawEntries(inDirectory: $0)
        }), disc.indexPath == indexPath else {
            throw MediaTransportError.sourceChanged(reason: "Blu-ray folder structure changed")
        }
        var inventory = [disc.index]
        inventory += disc.entries.filter {
            $0.kind == .file && $0.name.caseInsensitiveCompare("MovieObject.bdmv") == .orderedSame
        }
        let javaMenus = DiscMenuInspection.supportsJavaMenus
        let folders = ["playlist", "clipinf", "stream", "auxdata", "backup"] + (javaMenus ? ["bdjo", "jar"] : [])
        for folder in disc.entries where folder.kind == .directory
            && folders.contains(folder.name.lowercased()) {
            try Task.checkCancellation()
            let children = try await store.rawEntries(inDirectory: folder.relativePath)
            guard children.count <= 4_096 - inventory.count else {
                throw MediaTransportError.unsupportedCapability("Blu-ray folder file limit")
            }
            if folder.name.lowercased() == "backup" {
                inventory += children.filter {
                    $0.kind == .file && ["index.bdmv", "movieobject.bdmv"].contains($0.name.lowercased())
                }
                for backup in children where backup.kind == .directory &&
                    (["playlist", "clipinf"] + (javaMenus ? ["bdjo"] : [])).contains(backup.name.lowercased()) {
                    let files = try await store.rawEntries(inDirectory: backup.relativePath)
                    guard files.count <= 4_096 - inventory.count else {
                        throw MediaTransportError.unsupportedCapability("Blu-ray folder file limit")
                    }
                    let ext = ["playlist": "mpls", "clipinf": "clpi", "bdjo": "bdjo"][backup.name.lowercased()]
                    inventory += files.filter { $0.kind == .file && ($0.name as NSString).pathExtension.lowercased() == ext }
                }
                continue
            }
            if folder.name.lowercased() == "jar" {
                var pending = [(path: folder.relativePath, depth: 0)]
                var inspected = inventory.count
                while let level = pending.popLast() {
                    try Task.checkCancellation()
                    guard level.depth <= 8 else {
                        throw MediaTransportError.unsupportedCapability("Blu-ray Java resource limit")
                    }
                    let resources = level.depth == 0 ? children
                        : try await store.rawEntries(inDirectory: level.path)
                    guard resources.count <= 4_096 - inspected else {
                        throw MediaTransportError.unsupportedCapability("Blu-ray Java resource limit")
                    }
                    inspected += resources.count
                    for entry in resources {
                        guard (entry.relativePath as NSString).deletingLastPathComponent == level.path else {
                            throw MediaTransportError.protocolViolation(reason: "disc resource outside directory")
                        }
                        if entry.kind == .file {
                            inventory.append(entry)
                        } else if entry.kind == .directory {
                            pending.append((entry.relativePath, level.depth + 1))
                        }
                    }
                }
                continue
            }
            let extensions = [
                "playlist": ["mpls"], "clipinf": ["clpi"], "stream": ["m2ts"],
                "auxdata": ["bdmv", "otf", "ttf"], "bdjo": ["bdjo"]
            ][folder.name.lowercased()] ?? []
            inventory += children.filter {
                $0.kind == .file && extensions.contains(($0.name as NSString).pathExtension.lowercased())
            }
        }
        guard inventory.contains(where: { ($0.name as NSString).pathExtension.lowercased() == "mpls" }),
              inventory.contains(where: { ($0.name as NSString).pathExtension.lowercased() == "m2ts" }) else {
            throw MediaTransportError.unsupportedCapability("Blu-ray folder lacks playlists or clips")
        }
        let prefix = directory.isEmpty ? "" : directory + "/"
        var files: [NetworkDiscLocator.File] = []
        for entry in inventory {
            try Task.checkCancellation()
            guard entry.relativePath.hasPrefix(prefix) else {
                throw MediaTransportError.protocolViolation(reason: "disc entry outside directory")
            }
            let locator: NetworkFileLocator
            if entry.size != nil, entry.strongETag != nil || entry.modifiedAt != nil {
                locator = try networkFileLocator(for: entry.relativePath, entry: entry)
            } else {
                locator = try await networkFileLocator(for: entry.relativePath)
            }
            files.append(try .init(
                path: "BDMV/" + entry.relativePath.dropFirst(prefix.count),
                locator: locator
            ))
        }
        if javaMenus, !directory.isEmpty, disc.entries.contains(where: {
            $0.kind == .directory && $0.name.caseInsensitiveCompare("BDJO") == .orderedSame
        }) {
            let parent = (directory as NSString).deletingLastPathComponent
            let siblings = try await store.rawEntries(inDirectory: parent)
            for certificate in siblings where certificate.kind == .directory
                && certificate.name.caseInsensitiveCompare("CERTIFICATE") == .orderedSame {
                guard (certificate.relativePath as NSString).deletingLastPathComponent == parent else {
                    throw MediaTransportError.protocolViolation(reason: "disc identity outside directory")
                }
                let entries = try await store.rawEntries(inDirectory: certificate.relativePath)
                var identities = entries.filter {
                    $0.kind == .file && $0.name.caseInsensitiveCompare("id.bdmv") == .orderedSame
                }
                for backup in entries where backup.kind == .directory
                    && backup.name.caseInsensitiveCompare("BACKUP") == .orderedSame {
                    guard (backup.relativePath as NSString).deletingLastPathComponent == certificate.relativePath else {
                        throw MediaTransportError.protocolViolation(reason: "disc identity backup outside directory")
                    }
                    identities += try await store.rawEntries(inDirectory: backup.relativePath).filter {
                        $0.kind == .file && $0.name.caseInsensitiveCompare("id.bdmv") == .orderedSame
                    }
                }
                let prefix = parent.isEmpty ? "" : parent + "/"
                for entry in identities {
                    let path = String(entry.relativePath.dropFirst(prefix.count))
                    guard entry.relativePath.hasPrefix(prefix),
                          ["certificate/id.bdmv", "certificate/backup/id.bdmv"].contains(path.lowercased()) else {
                        throw MediaTransportError.protocolViolation(reason: "disc identity outside directory")
                    }
                    let locator: NetworkFileLocator
                    if entry.size != nil, entry.strongETag != nil || entry.modifiedAt != nil {
                        locator = try networkFileLocator(for: entry.relativePath, entry: entry)
                    } else {
                        locator = try await networkFileLocator(for: entry.relativePath)
                    }
                    files.append(try .init(path: path, locator: locator))
                }
            }
        }
        guard let anchor = files.first?.locator else {
            throw MediaTransportError.protocolViolation(reason: "disc index missing")
        }
        return try NetworkDiscLocator(anchor: anchor, files: files)
    }

    func playbackOpening(
        for relativePath: String, reuseDirectoryMetadata: Bool
    ) async throws -> (locator: NetworkFileLocator, directoryEntries: [RemoteFileEntry]?) {
        let statLocator = reuseDirectoryMetadata ? nil : try await networkFileLocator(for: relativePath)
        let directory = (relativePath as NSString).deletingLastPathComponent
        let entries = try await sidecarDirectoryEntries(directory)
        try Task.checkCancellation()
        let matchingEntries = entries?.filter { $0.relativePath == relativePath } ?? []
        let locator: NetworkFileLocator
        if let statLocator {
            locator = statLocator
        } else if matchingEntries.count == 1, let entry = matchingEntries.first,
           entry.kind == .file, entry.size != nil,
           entry.strongETag != nil || entry.modifiedAt != nil {
            // This listing is fresh for this Play request, not a browsing cache.
            // Opening/claiming the source still revalidates its identity and size.
            locator = try networkFileLocator(for: relativePath, entry: entry)
        } else {
            HandoffDiagnostics.emit(
                "shareLocator file=\(HandoffDiagnostics.correlationID(relativePath)) stage=listingFallback"
                    + " listed=\(entries != nil) matches=\(matchingEntries.count)"
            )
            locator = try await networkFileLocator(for: relativePath)
        }
        try Task.checkCancellation()
        return (locator, entries)
    }

    private func networkFileLocator(
        for relativePath: String, entry: RemoteFileEntry
    ) throws -> NetworkFileLocator {
        let diagnostic = Self.metadataDiagnostic(relativePath: relativePath, entry: entry)
        HandoffDiagnostics.emit(diagnostic)
        guard entry.kind == .file, let size = entry.size else {
            HandoffDiagnostics.emit("\(diagnostic) rejected=missingFileSize")
            throw MediaTransportError.protocolViolation(
                reason: "network file lacks a stable size"
            )
        }
        // Prefer a strong ETag as the representation identity when the transport
        // provides one (WebDAV): it lets the byte source revalidate every read
        // with If-Match. Fall back to modification time (SMB, which has no
        // ETag). A file with neither has no way to detect mid-playback change.
        let identity: RemoteFileIdentity
        if let strongETag = entry.strongETag {
            identity = try RemoteFileIdentity(kind: .strongETag, value: strongETag)
        } else if let modifiedAt = entry.modifiedAt {
            identity = try RemoteFileIdentity(kind: .modificationTime, modifiedAt: modifiedAt)
        } else {
            HandoffDiagnostics.emit("\(diagnostic) rejected=missingIdentity")
            throw MediaTransportError.protocolViolation(
                reason: "network file lacks a stable identity (no strong ETag or modification time)"
            )
        }

        let representation = try RemoteFileRepresentation(
            size: size,
            identity: identity,
            consistency: .changeDetecting
        )
        return try NetworkFileLocator(
            accountID: accountID,
            sourceID: accountID,
            credentialRevision: credentialRevision,
            relativePath: relativePath,
            representation: representation,
            formatHint: MediaFormatHint(
                container: (relativePath as NSString).pathExtension,
                mimeType: entry.mimeType
            )
        )
    }

    static func metadataDiagnostic(relativePath: String, entry: RemoteFileEntry) -> String {
        "shareLocator file=\(HandoffDiagnostics.correlationID(relativePath)) stage=metadata"
            + " isFile=\(entry.kind == .file) size=\(entry.size.map(String.init) ?? "missing")"
            + " strongETag=\(entry.strongETag != nil) modifiedAt=\(entry.modifiedAt != nil)"
    }

    static func diagnosticErrorCode(_ error: Error) -> String {
        if let error = error as? MediaTransportError { return "transport.\(error.description)" }
        if let error = error as? AppError { return "app.\(HandoffDiagnostics.errorCode(error))" }
        if error is CancellationError { return "cancelled" }
        if let error = error as? MediaSourceModelError {
            let code: String = switch error {
            case .emptyIdentifier: "emptyIdentifier"
            case .invalidHost: "invalidHost"
            case .invalidPort: "invalidPort"
            case .invalidRootPath: "invalidRootPath"
            case .invalidRelativePath: "invalidRelativePath"
            case .invalidFileSize: "invalidFileSize"
            case .invalidRepresentationIdentity: "invalidRepresentationIdentity"
            case .transportOptionsMismatch: "transportOptionsMismatch"
            case .unsupportedProvider: "unsupportedProvider"
            case .unsupportedScheme: "unsupportedScheme"
            case .invalidOrigin: "invalidOrigin"
            case .missingHost: "missingHost"
            case .credentialBearingURL: "credentialBearingURL"
            case .sensitiveQueryItem: "sensitiveQueryItem"
            case .urlFragmentNotAllowed: "urlFragmentNotAllowed"
            }
            return "model.\(code)"
        }
        let native = error as NSError
        switch native.domain {
        case NSURLErrorDomain: return "url.\(native.code)"
        case NSPOSIXErrorDomain: return "posix.\(native.code)"
        case NSCocoaErrorDomain: return "cocoa.\(native.code)"
        default: return "unknown"
        }
    }

    /// Finds text sidecar subtitles for a video by listing its directory (and a
    /// sibling `Subs`/`Subtitles` folder) and matching files by stem, then
    /// materialises each to a local `file://` temp so the player's overlay — which
    /// fetches over HTTP/`file://`, never `smb://` — can read them. Reads are
    /// serial (the SMB session is single-connection) and lazy-small (sidecars are
    /// tiny). Cleans up its temp dir on player teardown is handled by the OS temp
    /// reaper; files are namespaced per item so replays reuse them within a run.
    func discoverSidecarSubtitles(
        forVideoRelPath relPath: String,
        exactStemOnly: Bool = false
    ) async throws -> [MediaTrack] {
        let directory = (relPath as NSString).deletingLastPathComponent
        let entries = try await sidecarDirectoryEntries(directory)
        return try await discoverSidecarSubtitles(
            forVideoRelPath: relPath, exactStemOnly: exactStemOnly, directoryEntries: entries
        )
    }

    func discoverSidecarSubtitles(
        forVideoRelPath relPath: String,
        exactStemOnly: Bool,
        directoryEntries ownEntries: [RemoteFileEntry]?
    ) async throws -> [MediaTrack] {
        try Task.checkCancellation()
        let dir = (relPath as NSString).deletingLastPathComponent
        let videoStem = ShareMediaParser.videoStem((relPath as NSString).lastPathComponent)

        // Gather candidate (directory, entry, isDedicatedSubsFolder) triples from the
        // video's own folder and any sibling Subs/Subtitles folder. On a
        // case-insensitive share, casing aliases must not duplicate tracks.
        var candidates: [(dir: String, name: String, dedicated: Bool)] = []
        var seenCandidateKeys = Set<String>()
        // Use the real directory names rather than four speculative network
        // requests. Keep the legacy probes when the parent cannot be listed.
        let subFolderNames = ownEntries.map { entries in
            Set(entries.filter {
                $0.kind != .file && ["subs", "subtitles"].contains($0.name.lowercased())
            }.map(\.name)).sorted()
        } ?? ["Subs", "Subtitles", "subs", "subtitles"]
        let subDirs = subFolderNames.map { sub in dir.isEmpty ? sub : "\(dir)/\(sub)" }
        for (listDir, dedicated) in [(dir, false)] + subDirs.map({ ($0, true) }) {
            let entries = dedicated ? try await sidecarDirectoryEntries(listDir) : ownEntries
            guard let entries else { continue }
            for entry in entries where entry.kind != .directory && ShareMediaParser.isSubtitleFile(entry.name) {
                let key = "\(listDir.lowercased())/\(entry.name.lowercased())"
                guard seenCandidateKeys.insert(key).inserted else { continue }
                candidates.append((listDir, entry.name, dedicated))
            }
        }
        guard !candidates.isEmpty else { return [] }

        var tracks: [MediaTrack] = []
        var nextID = 5_000
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("plozz-sidecars", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        } catch {
            PlozzLog.playback.error("share.sidecars temporary directory unavailable")
            return []
        }

        for (candidateDir, name, dedicated) in candidates {
            try Task.checkCancellation()
            guard let sidecar = ShareMediaParser.parseSidecar(name) else { continue }
            let matches = exactStemOnly
                ? sidecar.stem.caseInsensitiveCompare(videoStem) == .orderedSame
                : Self.sidecarMatchesVideo(
                    sidecarStem: sidecar.stem,
                    videoStem: videoStem,
                    dedicatedFolder: dedicated
                )
            guard matches else { continue }

            let relSidecar = candidateDir.isEmpty ? name : "\(candidateDir)/\(name)"
            let data: Data
            do {
                data = try await store.readFile(relSidecar)
            } catch {
                if error is CancellationError || (error as? MediaTransportError) == .cancelled {
                    throw error
                }
                try Task.checkCancellation()
                PlozzLog.playback.error("share.sidecars read unavailable")
                continue
            }
            try Task.checkCancellation()
            guard !data.isEmpty else { continue }
            // `.magnitude` (not `abs`) so `Int.min` can't trap; hex keeps it short.
            let stableKey = String(relSidecar.hashValue.magnitude, radix: 16)
            let localURL = tempDir.appendingPathComponent("\(stableKey)-\(name)")
            do {
                try data.write(to: localURL, options: .atomic)
            } catch {
                PlozzLog.playback.error("share.sidecars temporary file write failed")
                continue
            }
            let language = sidecar.language
            let langName = language.flatMap { SubtitleLanguageCatalog.displayName(forCode: $0) }
            var title = langName ?? language ?? "Subtitle"
            if sidecar.isForced { title += " (Forced)" }
            if sidecar.isSDH { title += " (SDH)" }
            tracks.append(MediaTrack(
                id: nextID,
                kind: .subtitle,
                displayTitle: title,
                language: language,
                codec: sidecar.ext,
                isForced: sidecar.isForced,
                isHearingImpaired: sidecar.isSDH,
                deliverySource: .localFile(localURL),
                isImageBasedSubtitle: false,
                isExternal: true
            ))
            nextID += 1
        }
        return tracks
    }

    private func sidecarDirectoryEntries(_ directory: String) async throws -> [RemoteFileEntry]? {
        do {
            try Task.checkCancellation()
            return try await store.rawEntries(inDirectory: directory)
        } catch {
            if error is CancellationError || (error as? MediaTransportError) == .cancelled {
                throw error
            }
            try Task.checkCancellation()
            let code = Self.diagnosticErrorCode(error)
            HandoffDiagnostics.emit(
                "shareLocator directory=\(HandoffDiagnostics.correlationID(directory))"
                    + " stage=listing event=failed error=\(code)"
            )
            PlozzLog.playback.error("share.sidecars directory listing unavailable: \(code)")
            return nil
        }
    }

    /// Whether a sidecar's parsed stem belongs to the video with `videoStem`.
    ///
    /// In the video's **own** directory we require an *exact* stem match — a
    /// prefix relaxation there cross-attaches sibling episodes with non-zero-padded
    /// numbering (`Show.S01E1.srt` would prefix-match `Show.S01E10.mkv`) and movie
    /// siblings (`Batman` vs `Batman Begins`). In a **dedicated** `Subs/Subtitles`
    /// folder — conventionally holding a single title's subs — we allow a prefix
    /// match, but only at a separator boundary so `E1` still can't match `E10`.
    static func sidecarMatchesVideo(sidecarStem: String, videoStem: String, dedicatedFolder: Bool) -> Bool {
        if sidecarStem.caseInsensitiveCompare(videoStem) == .orderedSame { return true }
        guard dedicatedFolder else { return false }
        return isPrefixAtBoundary(sidecarStem, of: videoStem)
            || isPrefixAtBoundary(videoStem, of: sidecarStem)
    }

    /// Whether `prefix` is a prefix of `whole` ending at a separator boundary
    /// (the next character is `.`, space, `-`, `_`), so `E1` can't prefix `E10`.
    private static func isPrefixAtBoundary(_ prefix: String, of whole: String) -> Bool {
        guard prefix.count < whole.count, whole.hasPrefix(prefix) else { return false }
        let nextIndex = whole.index(whole.startIndex, offsetBy: prefix.count)
        let next = whole[nextIndex]
        return next == "." || next == " " || next == "-" || next == "_"
    }

    /// Opt-in on-device timing measurement (env `PLZXPROBE=1`): probe this item's
    /// file headers over SMB and log elapsed time + facts, so we can validate the
    /// probe is fast enough for the browse-time metadata feature before building the
    /// full pipeline. Fire-and-forget; never blocks item resolution.
    func measureStreamProbeIfEnabled(itemID: String) {
        guard ProcessInfo.processInfo.environment["PLZXPROBE"] == "1",
              let prober = streamProber else { return }
        Task.detached(priority: .utility) {
            // Record the browse, let the user settle, then probe ONLY if still idle —
            // so probing never competes with active navigation. One in-flight at a
            // time, spaced apart, capped per launch. (A naive fire-per-item version
            // stormed the NAS and, because the probe blocks a thread, froze the UI.)
            await ProbeMeasurementGate.shared.noteActivity()
            try? await Task.sleep(for: .seconds(4))
            guard await ProbeMeasurementGate.shared.tryStartIfIdle(idleFor: 4) else { return }
            defer { Task { await ProbeMeasurementGate.shared.finish() } }
            guard let relPath = await self.store.path(forItemID: itemID) else { return }
            let ext = (relPath as NSString).pathExtension.lowercased()
            let videoExts: Set<String> = ["mkv", "mp4", "m4v", "mov", "avi", "ts", "m2ts", "mts", "webm"]
            guard videoExts.contains(ext),
                  let locator = try? await self.networkFileLocator(for: relPath) else { return }
            let name = (relPath as NSString).lastPathComponent
            let start = Date()
            let facts = await prober.probe(locator: locator)
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            if let f = facts {
                HandoffDiagnostics.emit("PROBE ok file=\(name) container=\(ext) elapsed=\(ms)ms range=\(f.videoRangeType ?? "-") res=\(f.videoWidth ?? 0)x\(f.videoHeight ?? 0) vcodec=\(f.videoCodec ?? "-") acodec=\(f.audioCodec ?? "-") ch=\(f.audioChannels ?? 0) atmos=\(f.audioIsAtmos) dur=\(Int(f.durationSeconds ?? 0))s")
            } else {
                HandoffDiagnostics.emit("PROBE FAILED file=\(name) container=\(ext) elapsed=\(ms)ms")
            }
        }
    }
}

/// Serializes the opt-in stream-probe MEASUREMENT to ONE probe at a time and caps the
/// total per launch. A naive fire-per-item version stormed the NAS and — because the
/// probe blocks a thread — exhausted the Swift concurrency pool, stalling artwork and
/// enrichment. This gate makes the measurement safe: browsing a whole folder still
/// runs at most one probe at a time, and never more than `maxTotal` overall.
private actor ProbeMeasurementGate {
    static let shared = ProbeMeasurementGate()
    private var inFlight = false
    private var completed = 0
    private var lastStart = Date.distantPast
    private var lastActivity = Date.distantPast
    private let maxTotal = 12
    /// Minimum gap between probe STARTS.
    private let minInterval: TimeInterval = 6

    /// Record that the user just did something (opened/browsed an item), so probing
    /// can hold off until they've paused.
    func noteActivity() { lastActivity = Date() }

    /// Only start a probe when the user has been IDLE for `idleFor` seconds (no
    /// browsing), so probing never competes with active navigation.
    func tryStartIfIdle(idleFor: TimeInterval) -> Bool {
        let now = Date()
        guard !inFlight, completed < maxTotal,
              now.timeIntervalSince(lastActivity) >= idleFor,
              now.timeIntervalSince(lastStart) >= minInterval else { return false }
        inFlight = true
        lastStart = now
        return true
    }

    func finish() {
        inFlight = false
        completed += 1
    }
}
