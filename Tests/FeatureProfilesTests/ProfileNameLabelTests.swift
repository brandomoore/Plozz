import CoreModels
import FeatureProfiles
import SwiftUI
import Testing

@MainActor
struct ProfileNameLabelTests {
    @Test
    func profileAndPlexLocksRenderAnIndicator() throws {
        let profile = Profile(name: "Viewer", avatarSymbol: "person.fill", colorIndex: 0)
        let unlocked = try render(profile)
        var locked = profile
        locked.lock = try #require(ProfileLock.make(pin: "2468", iterations: 1))
        let protected = try render(locked)
        #expect(protected.width > unlocked.width)
        #expect(protected.height == unlocked.height)

        var kids = profile
        kids.isKids = true
        #expect(try render(kids).data == unlocked.data)

        let plex = profile.settingHomeUserBinding(
            .init(homeUserID: "protected", name: "Viewer", requiresPIN: true),
            forPlexAccount: "plex"
        )
        #expect(try render(plex).data == protected.data)
        #expect(try render(plex, showsLock: false).data == unlocked.data)

        let unprotectedPlex = profile.settingHomeUserBinding(
            .init(homeUserID: "unprotected", name: "Viewer", requiresPIN: false),
            forPlexAccount: "plex"
        )
        #expect(try render(unprotectedPlex).data == unlocked.data)

        locked.lock = nil
        #expect(try render(locked).data == unlocked.data)
    }

    private func render(
        _ profile: Profile, showsLock: Bool? = nil
    ) throws -> (width: CGFloat, height: CGFloat, data: Data) {
        let renderer = ImageRenderer(content:
            ProfileNameLabel(profile: profile, showsLock: showsLock)
                .font(.title3)
                .foregroundStyle(.white)
                .fixedSize()
        )
        let image = try #require(renderer.uiImage)
        return (image.size.width, image.size.height, try #require(image.pngData()))
    }
}
