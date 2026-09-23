#if canImport(UIKit)
import CoreModels
import CoreNetworking
import Observation

@MainActor
@Observable
public final class PlayerVersionMenuModel {
    public struct Option: Identifiable, Equatable, Sendable {
        public let version: MediaVersion
        public let isSelected: Bool
        public var id: String { version.id }

        public init(version: MediaVersion, isSelected: Bool) {
            self.version = version
            self.isSelected = isSelected
        }
    }

    public var options: [Option] = []
    @ObservationIgnored public var onSelect: ((String) -> Void)?

    public init() {}

    public var isAvailable: Bool { options.count > 1 }

    public func select(_ id: String) {
        guard let option = options.first(where: { $0.id == id }) else {
            PlozzLog.playback.error("The selected playback version is no longer available.")
            return
        }
        guard !option.isSelected else { return }
        guard let onSelect else {
            PlozzLog.playback.error("Playback version selection has no active presentation.")
            return
        }
        onSelect(id)
    }
}
#endif
