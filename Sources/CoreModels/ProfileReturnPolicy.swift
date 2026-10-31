import Foundation

public enum ProfileReturnPolicy {
    public static func delay(for profiles: [Profile], automaticallySignIn: Bool) -> TimeInterval? {
        guard !automaticallySignIn else { return nil }
        if profiles.contains(where: { $0.isLocked || $0.playsAsPINProtectedPlexUser }) {
            return 0
        }
        return profiles.count > 1 ? 300 : nil
    }
}
