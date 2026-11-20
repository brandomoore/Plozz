#if canImport(AVFoundation)
import CoreModels
import Foundation
import Observation

/// Visible rails nominate a card; only the winning card borrows the shared hero player.
@MainActor
@Observable
public final class FeaturedTrailerCoordinator {
    private struct Candidate {
        let rowID: UUID
        let item: MediaItem
        let scope: ObjectIdentifier
        let priority: Int
        let muted: Bool
        let controller: HeroTrailerController
        let resolve: HeroTrailerResolving

        var key: Key { Key(rowID: rowID, itemID: item.stablePresentationID, scope: scope) }
    }

    private struct Key: Equatable {
        let rowID: UUID
        let itemID: String
        let scope: ObjectIdentifier
    }

    public private(set) var activeRowID: UUID?
    public private(set) var activeItemID: String?
    public private(set) var playerItemID: String?
    @ObservationIgnored private var candidates: [UUID: Candidate] = [:]
    @ObservationIgnored private var key: Key?
    @ObservationIgnored private var owner: UUID?
    @ObservationIgnored private var controller: HeroTrailerController?
    @ObservationIgnored private var task: Task<Void, Never>?
    private let settleDelay: Duration

    public init(settleDelay: Duration = .seconds(HeroTrailerTimeline.leadIn)) {
        self.settleDelay = settleDelay
    }

    deinit {
        task?.cancel()
        if let controller, let owner {
            Task { @MainActor in controller.releaseFeaturedSurface(owner: owner) }
        }
    }

    public func update(
        rowID: UUID, item: MediaItem, scope: ObjectIdentifier, priority: Int,
        muted: Bool, controller: HeroTrailerController, resolve: @escaping HeroTrailerResolving
    ) {
        candidates[rowID] = Candidate(
            rowID: rowID, item: item, scope: scope, priority: priority,
            muted: muted, controller: controller, resolve: resolve
        )
        selectCandidate()
    }

    public func withdraw(rowID: UUID) {
        candidates.removeValue(forKey: rowID)
        selectCandidate()
    }

    public func stop() {
        candidates.removeAll()
        release()
    }

    private func selectCandidate() {
        guard let candidate = candidates.values.min(by: {
            if $0.priority != $1.priority { return $0.priority < $1.priority }
            return $0.rowID.uuidString < $1.rowID.uuidString
        }) else {
            release()
            return
        }
        if key == candidate.key, controller === candidate.controller, let owner {
            controller?.setMuted(candidate.muted, featuredOwner: owner)
            return
        }
        release()
        let owner = UUID()
        guard candidate.controller.reserveFeaturedSurface(owner: owner) else { return }
        self.owner = owner
        controller = candidate.controller
        key = candidate.key
        activeRowID = candidate.rowID
        activeItemID = candidate.item.stablePresentationID
        let playerItemID = "featured:\(owner.uuidString):\(candidate.item.stablePresentationID)"
        self.playerItemID = playerItemID
        task = Task { [weak self, settleDelay] in
            do { try await Task.sleep(for: settleDelay) }
            catch { return }
            guard !Task.isCancelled,
                  candidate.controller.featuredOwnerID == owner,
                  !candidate.controller.isPlaybackSuppressed else { return }
            let source = await candidate.resolve(candidate.item)
            guard !Task.isCancelled, self?.owner == owner,
                  candidate.controller.featuredOwnerID == owner,
                  !candidate.controller.isPlaybackSuppressed,
                  let source else { return }
            candidate.controller.play(
                itemID: playerItemID, source: source,
                muted: candidate.controller.isMuted, featuredOwner: owner
            )
            candidate.controller.claimSurface(.featured, itemID: playerItemID)
        }
        candidate.controller.setMuted(candidate.muted, featuredOwner: owner)
    }

    private func release() {
        task?.cancel()
        task = nil
        if let owner { controller?.releaseFeaturedSurface(owner: owner) }
        owner = nil
        controller = nil
        key = nil
        activeRowID = nil
        activeItemID = nil
        playerItemID = nil
    }
}
#endif
