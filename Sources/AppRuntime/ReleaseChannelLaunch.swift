import CoreModels
import CoreNetworking
import Observation
import StoreKit

/// Both app roots wait for the same answer before constructing channel-dependent models.
@MainActor @Observable
public final class ReleaseChannelLaunch {
    public static let shared = ReleaseChannelLaunch()
    public private(set) var isReady: Bool
    @ObservationIgnored private var lookup: Task<Void, Never>?
    @ObservationIgnored private var deadline: Task<Void, Never>?

    private init() {
        isReady = AppReleaseChannel.installation.resolved != nil
        guard !isReady else { return }
        lookup = Task {
            let channel: AppReleaseChannel?
            do {
                switch try await AppTransaction.shared {
                case .verified(let transaction) where transaction.environment == .production:
                    channel = .production
                case .verified(let transaction) where transaction.environment == .sandbox:
                    channel = .testflight
                default: channel = nil
                }
            } catch {
                channel = nil
            }
            guard !Task.isCancelled else { return }
            finish(channel)
        }
        deadline = Task {
            // StoreKit can need the network. A late reply must not change the
            // channel underneath an already running app.
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            finish(nil)
        }
    }

    private func finish(_ channel: AppReleaseChannel?) {
        if channel == nil {
            PlozzLog.app.info("Install channel unavailable; using production for this launch")
        }
        AppReleaseChannel.installation.finish(verifiedChannel: channel)
        isReady = true
        lookup?.cancel()
        deadline?.cancel()
        lookup = nil
        deadline = nil
    }
}
