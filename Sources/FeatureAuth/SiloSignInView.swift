#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI
import FeatureAuthCore
import ProviderSilo

private enum SiloSignInFocus: Hashable {
    case profile(String), pin, confirm, retry, cancel
}

public struct SiloSignInView: View {
    @State private var model: SiloAuthViewModel
    @FocusState private var focused: SiloSignInFocus?
    private let onCancel: () -> Void

    public init(server: MediaServer, deviceID: String,
                onAuthenticated: @escaping (UserSession) -> Void, onCancel: @escaping () -> Void) {
        _model = State(initialValue: SiloAuthViewModel(server: server, deviceID: deviceID, onAuthenticated: onAuthenticated))
        self.onCancel = onCancel
    }

    public var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 32) {
                    Spacer(minLength: 24)
                    VStack(spacing: 18) {
                        HStack(spacing: 12) {
                            ProviderBrandMark(provider: .silo, size: 52)
                            Text(verbatim: "Silo").font(.headline).foregroundStyle(.secondary)
                        }
                        Text(title).font(.largeTitle.bold()).multilineTextAlignment(.center)
                        if case .profiles = model.phase {
                            Text("Your library access and watch history follow this profile.")
                                .font(.body).foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                    }
                    content
                    Button("Cancel", action: cancel)
                        .focused($focused, equals: .cancel)
                        .padding(.top, 12)
                    Spacer(minLength: 24)
                }
                .frame(maxWidth: 960)
                .padding(.horizontal, 32)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
            .scrollClipDisabled()
        }
        .defaultFocus($focused, preferredFocus)
        #if os(tvOS)
        .onExitCommand(perform: cancel)
        #endif
        .task { if model.phase == .idle { model.start() } }
        .onChange(of: model.phase) { _, _ in focused = preferredFocus }
        .onDisappear { model.cancel() }
    }

    private var title: LocalizedStringResource {
        switch model.phase {
        case .profiles: "Choose your Silo profile"
        case .pin: "Unlock your profile"
        default: "Connect to Silo"
        }
    }

    private var preferredFocus: SiloSignInFocus {
        switch model.phase {
        case let .profiles(profiles): profiles.first.map { .profile($0.id) } ?? .cancel
        case .pin: .pin
        case .error: .retry
        default: .cancel
        }
    }

    private func cancel() {
        model.cancel()
        onCancel()
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .idle, .loading:
            ProgressView("Connecting…")
        case let .pairing(code, match, url, expiresAt):
            VStack(spacing: 20) {
                Text("Scan this code and approve Plozz in your Silo account.")
                    .multilineTextAlignment(.center)
                BrandQRCodeView(payload: url.absoluteString, size: 240)
                Text(url.absoluteString).font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Text(code).font(.largeTitle.monospaced().bold())
                Text("Check that the confirmation code is \(match).")
                Text(expiresAt, style: .timer).monospacedDigit().foregroundStyle(.secondary)
            }
        case let .profiles(profiles):
            SiloProfileChoices(profiles: profiles, focused: $focused, select: model.select)
        case let .pin(profile):
            VStack(spacing: 20) {
                Text(profile.name).font(.title2.weight(.semibold))
                SecureField("Profile PIN", text: $model.pin)
                    .textContentType(.oneTimeCode)
                    .focused($focused, equals: .pin)
                    .frame(maxWidth: 400)
                    .onSubmit { model.submitPIN(profile) }
                if let error = model.pinError { Text(error).foregroundStyle(.red) }
                Button("Continue") { model.submitPIN(profile) }
                    .focused($focused, equals: .confirm)
                    .disabled(model.pin.isEmpty)
            }
        case let .error(message):
            VStack(spacing: 20) {
                Text(message).multilineTextAlignment(.center)
                Button("Try Again") { model.start() }
                    .focused($focused, equals: .retry)
            }
        }
    }
}

private struct SiloProfileChoices: View {
    let profiles: [SiloProfile]
    let focused: FocusState<SiloSignInFocus?>.Binding
    let select: (SiloProfile) -> Void
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    private var columnCount: Int {
        #if os(tvOS)
        min(3, max(1, profiles.count))
        #elseif os(iOS)
        min(horizontalSizeClass == .compact ? 1 : 2, max(1, profiles.count))
        #else
        min(3, max(1, profiles.count))
        #endif
    }

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 28), count: columnCount), spacing: 28) {
            ForEach(profiles) { profile in
                Button { select(profile) } label: {
                    SiloProfileCard(profile: profile)
                }
                .buttonStyle(SettingsFocusButtonStyle(size: .contained))
                .focused(focused, equals: .profile(profile.id))
                .accessibilityLabel(Text(profile.name))
                .accessibilityValue(profile.has_pin ? Text("PIN required") : Text(""))
            }
        }
        .frame(maxWidth: CGFloat(columnCount) * 220 + CGFloat(columnCount - 1) * 28)
        .padding(12)
    }
}

private struct SiloProfileCard: View {
    let profile: SiloProfile

    var body: some View {
        VStack(spacing: 18) {
            ZStack(alignment: .bottomTrailing) {
                Text(String(profile.name.prefix(1)).localizedUppercase)
                    .font(.system(size: 46, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color(red: 0.08, green: 0.22, blue: 0.50))
                    .frame(width: 108, height: 108)
                    .background(Color(red: 0xD6 / 255, green: 0xE5 / 255, blue: 1), in: Circle())
                if profile.has_pin {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(9)
                        .background(Color(red: 0.08, green: 0.22, blue: 0.50), in: Circle())
                }
            }
            Text(profile.name)
                .font(.headline)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity, minHeight: 202)
        .contentShape(RoundedRectangle(cornerRadius: 20))
    }
}
#endif
