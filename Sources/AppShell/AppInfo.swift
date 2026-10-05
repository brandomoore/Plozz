import Foundation
import CoreModels

/// App metadata helpers.
public enum AppInfo {
    /// Plozz release label, falling back to Apple's version for local/older builds.
    public static var version: String {
        AppVersionIdentity.current.displayVersion
    }

    public static var marketingVersion: String { AppVersionIdentity.current.marketingVersion }

    /// Build number from the app bundle (CFBundleVersion). Baked into the
    /// generated project at project-generation time (see tools/generate-project.sh)
    /// from the git commit count, so it auto-increments on every commit; the
    /// fastlane `build` lane overrides it with (latest TestFlight build + 1) for
    /// App Store / TestFlight uploads.
    public static var build: String {
        AppVersionIdentity.current.build
    }

    /// Public source repository, encoded into the Settings "About" QR code so a
    /// phone can open it (tvOS has no browser).
    public static let repoURLString = AppLinks.repository.absoluteString
}
