import Foundation

/// First-run cases use separate app/Keychain identities and cloud zones, never a reset of real data.
public enum AppInstallation: Equatable, Sendable {
    case standard
    case firstRun(UUID)

    public enum IdentityError: Error { case invalidFirstRunIdentifier }

    public static let firstRunBundlePrefix = "com.thatcube.Plozz.first-run."
    public static let current: Self = {
        do {
            let installation = try Self(bundleIdentifier: Bundle.main.bundleIdentifier)
            #if !DEBUG
            precondition(installation == .standard, "First-run installations require a Debug build.")
            #endif
            return installation
        } catch {
            preconditionFailure("Invalid first-run app identity; refusing to use normal Plozz storage.")
        }
    }()

    public init(bundleIdentifier: String?) throws {
        guard let bundleIdentifier,
              bundleIdentifier.hasPrefix("com.thatcube.Plozz.first-run") else {
            self = .standard
            return
        }
        guard bundleIdentifier.hasPrefix(Self.firstRunBundlePrefix),
              let id = UUID(uuidString: String(bundleIdentifier.dropFirst(Self.firstRunBundlePrefix.count))),
              bundleIdentifier == Self.firstRunBundlePrefix + id.uuidString.lowercased() else {
            throw IdentityError.invalidFirstRunIdentifier
        }
        self = .firstRun(id)
    }

    public var firstRunCaseID: UUID? {
        guard case .firstRun(let id) = self else { return nil }
        return id
    }

    public var cloudContainerIdentifier: String {
        firstRunCaseID == nil ? "iCloud.com.thatcube.Plozz" : "iCloud.com.thatcube.Plozz.FirstRun"
    }

    public var pairingServiceType: String {
        guard let id = firstRunCaseID else { return "_plozz-pair._tcp" }
        let tag = id.uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(12)
        return "_plz\(tag)._tcp"
    }

    public var pairingURLPrefix: String {
        guard let id = firstRunCaseID else { return "https://plozz.app/pair#" }
        return "plozz-first-run-\(id.uuidString.lowercased())://pair#"
    }

    public func cloudZoneName(_ name: String) -> String {
        guard let id = firstRunCaseID else { return name }
        return name + "." + id.uuidString.lowercased()
    }
}
