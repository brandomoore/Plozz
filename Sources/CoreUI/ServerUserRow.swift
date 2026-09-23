#if canImport(SwiftUI)
import CoreModels
import SwiftUI

public struct ServerUserAvatar: View {
    private let provider: ProviderKind
    private let name: String
    private let avatarURL: URL?
    private let size: CGFloat

    public init(provider: ProviderKind, name: String, avatarURL: URL? = nil, size: CGFloat = 52) {
        self.provider = provider
        self.name = name
        self.avatarURL = avatarURL
        self.size = size
    }

    public var body: some View {
        ZStack {
            Circle().fill(ProviderBrandMark.brandTint(provider).opacity(0.18))
            if let avatarURL {
                AsyncImage(url: avatarURL) { phase in
                    switch phase {
                    case let .success(image): image.resizable().scaledToFill()
                    default: initial
                    }
                }
            } else {
                initial
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(ProviderBrandMark.brandTint(provider).opacity(0.45), lineWidth: 1.5))
    }

    @ViewBuilder
    private var initial: some View {
        let text = Text(String(name.prefix(1)).uppercased())
            .font(.system(size: size * 0.34, weight: .semibold))
        if provider == .plex {
            text.foregroundStyle(ProviderBrandMark.brandTint(.plex))
        } else {
            text
        }
    }
}

public struct ServerUserRow: View {
    public enum Accessory: Equatable, Sendable { case none, selected }

    private let provider: ProviderKind
    private let name: String
    private let avatarURL: URL?
    private let showsOwnerBadge: Bool
    private let requiresPIN: Bool
    private let accessory: Accessory

    public init(
        provider: ProviderKind, name: String, avatarURL: URL? = nil,
        showsOwnerBadge: Bool = false, requiresPIN: Bool = false, accessory: Accessory = .none
    ) {
        self.provider = provider
        self.name = name
        self.avatarURL = avatarURL
        self.showsOwnerBadge = showsOwnerBadge
        self.requiresPIN = requiresPIN
        self.accessory = accessory
    }

    public var body: some View {
        HStack(spacing: 16) {
            ServerUserAvatar(provider: provider, name: name, avatarURL: avatarURL)
            HStack(spacing: 6) {
                Text(name).font(.headline)
                if showsOwnerBadge {
                    Text("Account owner")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(ProviderBrandMark.brandTint(provider).opacity(0.18)))
                        .foregroundStyle(ProviderBrandMark.brandTint(provider))
                }
                if requiresPIN {
                    HStack(spacing: 3) {
                        Image(systemName: "lock.fill")
                        Text("PIN")
                    }
                    .font(.caption2.weight(.semibold))
                    .settingsRowSecondary()
                    .accessibilityLabel("PIN required")
                }
            }
            Spacer()
            if accessory == .selected { SettingsSelectionIndicator() }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .contentShape(Rectangle())
    }
}
#endif
