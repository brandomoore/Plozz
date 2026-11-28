import CoreModels
import Foundation

extension ProfilesModel {
    /// Creates a profile from an editor draft and marks it as awaiting setup.
    ///
    /// Both shells start the new viewer with an explicit empty membership.
    /// The editor's account and photo candidates are not grants.
    ///
    /// The flag is written by `add` itself, in the SAME persist as the profile,
    /// rather than by a second `update` — a write that can fail, or be cut short
    /// by the app being killed, leaving a durable ungated profile behind.
    @discardableResult
    public func addAwaitingSetup(
        _ draft: ProfileDraft,
        isKids: Bool
    ) -> Profile {
        return add(
            name: draft.name.trimmingCharacters(in: .whitespacesAndNewlines),
            avatarSymbol: draft.avatarSymbol,
            colorIndex: draft.colorIndex,
            linkedAccountID: draft.linkedAccountID,
            activeAccountIDs: [],
            plexHomeUserID: draft.plexHomeUserID,
            plexHomeUserName: draft.plexHomeUserName,
            plexHomeUserAccountID: draft.plexHomeUserAccountID,
            plexHomeUserRequiresPIN: draft.plexHomeUserRequiresPIN,
            plexHomeUserAvatarURL: draft.plexHomeUserAvatarURL,
            plexHomeUserBindings: draft.plexHomeUserBindings,
            avatarImageURL: draft.avatarImageURL,
            avatarEmoji: draft.avatarEmoji,
            avatarEmojiColorIndex: draft.avatarEmojiColorIndex,
            isAwaitingSetup: true,
            isKidsProfile: isKids ? true : nil
        )
    }

    /// Clears the setup gate, returning `true` if it was actually set.
    ///
    /// `false` means someone else already completed setup for this profile (or it
    /// predates the gate), and the caller should NOT kick off a second import.
    @discardableResult
    public func finishSetup(for id: String) -> Bool {
        guard var profile = profiles.first(where: { $0.id == id }), profile.needsSetup else {
            return false
        }
        profile.needsSetup = false
        update(profile)
        return true
    }
}
