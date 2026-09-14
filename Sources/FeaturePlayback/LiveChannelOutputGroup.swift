#if canImport(AVFoundation)
import Foundation

/// Coordinates process-wide output policy without transferring or rebuilding players.
@MainActor
public final class LiveChannelOutputGroup {
    private var engines: [UUID: any LiveChannelEngine] = [:]
    private var audibleID: UUID?
    private var displayOwnerID: UUID?
    private var displayRequests: Set<UUID> = []

    public init() {}

    public func register(
        _ engine: any LiveChannelEngine, id: UUID, audible: Bool, allowsDisplayMatching: Bool = true
    ) {
        if let previous = engines[id], previous !== engine {
            previous.configureLiveOutput(.init(
                isAudible: false, sharesAudioSession: true, suppressesDisplayMatching: true
            ))
        }
        engine.configureLiveOutput(.init(
            isAudible: false, sharesAudioSession: true,
            suppressesDisplayMatching: true
        ))
        engines[id] = engine
        if allowsDisplayMatching { displayRequests.insert(id) }
        else { displayRequests.remove(id) }
        reconcileDisplayOwner(preferred: id)
        if audible { selectAudio(id) } else { applyPolicies() }
    }

    public func setDisplayMatchingAllowed(
        _ allowed: Bool, id: UUID, engine expectedEngine: (any LiveChannelEngine)? = nil
    ) {
        guard let engine = engines[id],
              expectedEngine == nil || expectedEngine === engine else { return }
        if allowed { displayRequests.insert(id) }
        else { displayRequests.remove(id) }
        reconcileDisplayOwner(preferred: id)
        applyPolicies()
    }

    public func setAudible(
        _ audible: Bool, id: UUID, engine expectedEngine: (any LiveChannelEngine)? = nil
    ) {
        guard let engine = engines[id],
              expectedEngine == nil || expectedEngine === engine else { return }
        if audible {
            selectAudio(id)
        } else if audibleID == id {
            audibleID = nil
            applyPolicies()
        }
    }

    /// Call before the departing engine stops. Only the last stop may reset shared output.
    public func unregister(_ id: UUID, engine expectedEngine: (any LiveChannelEngine)? = nil) {
        guard let engine = engines[id],
              expectedEngine == nil || expectedEngine === engine else { return }
        engines.removeValue(forKey: id)
        displayRequests.remove(id)
        if audibleID == id { audibleID = nil }
        reconcileDisplayOwner()
        engine.configureLiveOutput(.init(
            isAudible: false,
            sharesAudioSession: !engines.isEmpty,
            suppressesDisplayMatching: !engines.isEmpty
        ))
        applyPolicies()
    }

    private func reconcileDisplayOwner(preferred: UUID? = nil) {
        if let displayOwnerID, displayRequests.contains(displayOwnerID) { return }
        if let preferred, displayRequests.contains(preferred) {
            displayOwnerID = preferred
        } else {
            displayOwnerID = displayRequests.sorted { $0.uuidString < $1.uuidString }.first
        }
    }

    private func selectAudio(_ id: UUID) {
        // Mute the former owner synchronously before making another stream audible.
        audibleID = nil
        applyPolicies()
        audibleID = id
        applyPolicies()
    }

    private func applyPolicies() {
        for (id, engine) in engines {
            engine.configureLiveOutput(.init(
                isAudible: id == audibleID,
                sharesAudioSession: true,
                suppressesDisplayMatching: id != displayOwnerID
            ))
        }
    }
}
#endif
