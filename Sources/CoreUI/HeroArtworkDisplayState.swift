#if canImport(SwiftUI) && canImport(UIKit)
import CoreModels
import SwiftUI
import UIKit

public struct DisplayedHeroArtwork: Sendable {
    public let itemID: String
    public let artwork: FirstPaintArtwork

    var key: AmbientArtworkKey {
        AmbientArtworkKey(id: itemID, reference: artwork.reference, variant: artwork.variant)
    }
}

/// One presentation's actual bitmap. Consumers never resolve another backdrop.
@MainActor @Observable
public final class HeroArtworkDisplayState {
    public private(set) var displayed: DisplayedHeroArtwork?
    public private(set) var backgroundSample: HeroBackgroundSample?
    @ObservationIgnored private var owner: UUID?
    @ObservationIgnored private var activeItemID: String?
    @ObservationIgnored private var pendingReports: [UUID: UUID] = [:]
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var sampleTask: Task<Void, Never>?

    public init() {}

    deinit { sampleTask?.cancel() }

    public func sample(for itemID: String) -> HeroBackgroundSample? {
        displayed?.itemID == itemID ? backgroundSample : nil
    }

    func activate(owner: UUID, itemID: String?) {
        self.owner = owner
        activeItemID = itemID
    }

    func enqueue(_ artwork: FirstPaintArtwork?, itemID: String, owner: UUID) {
        let ticket = UUID()
        pendingReports[owner] = ticket
        // Arrival can precede source activation. Only the latest arrival from
        // the still-active source may publish after this render pass.
        Task { @MainActor [weak self] in
            guard let self, self.pendingReports[owner] == ticket else { return }
            self.pendingReports[owner] = nil
            self.publish(artwork, itemID: itemID, owner: owner)
        }
    }

    func publish(_ artwork: FirstPaintArtwork?, itemID: String, owner: UUID) {
        guard self.owner == owner, activeItemID == itemID else { return }
        if self.owner == owner, let artwork, let displayed,
           displayed.itemID == itemID,
           displayed.artwork.reference == artwork.reference,
           displayed.artwork.variant == artwork.variant,
           displayed.artwork.image === artwork.image { return }
        generation &+= 1
        let ticket = generation
        sampleTask?.cancel()
        sampleTask = nil
        self.owner = owner
        displayed = artwork.map { DisplayedHeroArtwork(itemID: itemID, artwork: $0) }
        backgroundSample = nil
        guard let artwork else { return }
        sampleTask = Task { [weak self] in
            let sample = await HeroBackgroundSampler.sample(artwork: artwork)
            guard !Task.isCancelled, let self, self.generation == ticket else { return }
            self.backgroundSample = sample
            self.sampleTask = nil
        }
    }

    func release(owner: UUID) {
        pendingReports[owner] = nil
        guard self.owner == owner else { return }
        generation &+= 1
        sampleTask?.cancel()
        sampleTask = nil
        self.owner = nil
        activeItemID = nil
        displayed = nil
        backgroundSample = nil
    }
}

@MainActor
public struct HeroArtworkDisplayReporter {
    let state: HeroArtworkDisplayState?
    let owner: UUID
    let itemID: String?
    let isActive: Bool

    public struct Identity: Equatable {
        let state: ObjectIdentifier?
        let owner: UUID
        let itemID: String?
        let isActive: Bool
    }

    public var identity: Identity {
        Identity(state: state.map(ObjectIdentifier.init), owner: owner, itemID: itemID, isActive: isActive)
    }

    public func publish(_ artwork: FirstPaintArtwork?, itemID: String) {
        guard isActive, self.itemID == itemID else { return }
        state?.enqueue(artwork, itemID: itemID, owner: owner)
    }
}

private struct HeroArtworkDisplayStateKey: EnvironmentKey {
    static let defaultValue: HeroArtworkDisplayState? = nil
}

private struct HeroArtworkDisplayReporterKey: EnvironmentKey {
    static let defaultValue: HeroArtworkDisplayReporter? = nil
}

public extension EnvironmentValues {
    var heroArtworkDisplayState: HeroArtworkDisplayState? {
        get { self[HeroArtworkDisplayStateKey.self] }
        set { self[HeroArtworkDisplayStateKey.self] = newValue }
    }

    var heroArtworkDisplayReporter: HeroArtworkDisplayReporter? {
        get { self[HeroArtworkDisplayReporterKey.self] }
        set { self[HeroArtworkDisplayReporterKey.self] = newValue }
    }
}

public extension View {
    func heroArtworkScope() -> some View { modifier(HeroArtworkScope()) }

    func heroArtworkSource(id: String?, isActive: Bool = true) -> some View {
        modifier(HeroArtworkSource(id: id, isActive: isActive))
    }
}

private struct HeroArtworkScope: ViewModifier {
    @State private var state = HeroArtworkDisplayState()

    func body(content: Content) -> some View {
        content.environment(\.heroArtworkDisplayState, state)
    }
}

private struct HeroArtworkSource: ViewModifier {
    let id: String?
    let isActive: Bool
    @State private var owner = UUID()
    @Environment(\.heroArtworkDisplayState) private var state

    func body(content: Content) -> some View {
        let reporter = HeroArtworkDisplayReporter(state: state, owner: owner, itemID: id, isActive: isActive)
        content
            .environment(\.heroArtworkDisplayReporter, reporter)
            .onChange(of: reporter.identity, initial: true) { _, _ in
                if isActive {
                    state?.activate(owner: owner, itemID: id)
                } else {
                    state?.release(owner: owner)
                }
            }
            .onDisappear { state?.release(owner: owner) }
    }
}
#endif
