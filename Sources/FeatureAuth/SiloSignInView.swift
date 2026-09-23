#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI
import FeatureAuthCore
import ProviderSilo

private enum SiloSignInFocus: Hashable {
    case profile(String), pin, confirm, retry, profiles, cancel
}

public struct SiloSignInView: View {
    @State private var model: SiloAuthViewModel
    @FocusState private var focused: SiloSignInFocus?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.themePalette) private var palette
    private let server: MediaServer
    private let onCancel: () -> Void

    public init(server: MediaServer, deviceID: String,
                onAuthenticated: @escaping (UserSession) -> Void, onCancel: @escaping () -> Void) {
        self.init(viewModel: SiloAuthViewModel(server: server, deviceID: deviceID, onAuthenticated: onAuthenticated),
                  server: server, onCancel: onCancel)
    }

    public init(viewModel: SiloAuthViewModel, server: MediaServer, onCancel: @escaping () -> Void) {
        _model = State(initialValue: viewModel)
        self.server = server
        self.onCancel = onCancel
    }

    public var body: some View {
        layout
        .tint(palette.accent)
        .defaultFocus($focused, preferredFocus)
        #if os(tvOS)
        .onExitCommand {
            if case .pin = model.phase { model.chooseAnotherProfile() }
            else { cancel() }
        }
        #endif
        .task { if model.phase == .idle { model.start() } }
        .onChange(of: model.phase) { _, _ in focused = preferredFocus }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.checkPairingExpiry() }
        }
        .onDisappear { model.cancel() }
    }

    @ViewBuilder
    private var layout: some View {
        #if os(tvOS)
        VStack(spacing: 24) {
            header
            content
                .frame(maxWidth: isPairing ? 1500 : 900, maxHeight: .infinity)
            cancelButton
        }
        .padding(.horizontal, 60)
        .padding(.top, 60)
        .padding(.bottom, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #else
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 28) {
                    header
                    content
                    cancelButton
                }
                .frame(maxWidth: 1040)
                .padding(.horizontal, 28)
                .padding(.vertical, 32)
                .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
            .scrollClipDisabled()
        }
        #endif
    }

    private var header: some View {
        VStack(spacing: 14) {
            if !isChoosingProfile { ProviderBrandMark(provider: .silo, size: 80) }
            OnboardingHeader(
                Text(title),
                subtitle: isChoosingProfile ? Text("Choose your user on \(server.name).") : nil
            )
        }
    }

    private var cancelButton: some View {
        Button(role: .cancel, action: cancel) {
            Text("Cancel").frame(minWidth: 200)
        }
        .buttonStyle(.bordered)
        .focused($focused, equals: .cancel)
    }

    private var title: LocalizedStringResource {
        switch model.phase {
        case .profiles: "Choose your Silo profile"
        case .pin: "Unlock your profile"
        case .pairing: "Connect to Silo"
        case .expired: "Your code has expired"
        case .error: "Let's get you connected"
        default: "Connect to Silo"
        }
    }

    private var isChoosingProfile: Bool {
        if case .profiles = model.phase { return true }
        return false
    }

    private var isPairing: Bool {
        if case .pairing = model.phase { return true }
        return false
    }

    private var preferredFocus: SiloSignInFocus {
        switch model.phase {
        case let .profiles(profiles): profiles.first.map { .profile($0.id) } ?? .cancel
        case .pin: .pin
        case .error, .expired: .retry
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
            ProgressView(model.operation.message)
                .padding(.vertical, 44)
        case let .pairing(code, match, url, expiresAt):
            SiloPairingCard(code: code, match: match, approvalURL: url,
                            verificationURL: model.verificationURL, expiresAt: expiresAt,
                            lifetime: model.codeLifetime)
        case let .profiles(profiles):
            SiloProfileChoices(profiles: profiles, focused: $focused, select: model.select)
        case let .pin(profile):
            VStack(spacing: 20) {
                Label(profile.name, systemImage: "lock.fill")
                    .font(.title2.weight(.semibold))
                Text("Enter the PIN you use for this profile in Silo.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                SecureField("Profile PIN", text: $model.pin)
                    .textContentType(.password)
                    .focused($focused, equals: .pin)
                    .frame(maxWidth: 400)
                    .onSubmit { model.submitPIN(profile) }
                if let error = model.pinError { Text(error).foregroundStyle(.red) }
                Button("Continue") { model.submitPIN(profile) }
                    .buttonStyle(.borderedProminent)
                    .foregroundStyle(palette.onAccent)
                    .focused($focused, equals: .confirm)
                    .disabled(model.pin.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Choose another profile") { model.chooseAnotherProfile() }
                    .buttonStyle(.bordered)
                    .focused($focused, equals: .profiles)
            }
        case .expired:
            VStack(spacing: 20) {
                Image(systemName: "clock.arrow.circlepath").font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("Get a new code to continue. No server has been added.")
                    .multilineTextAlignment(.center)
                Button("Get a new code") { model.start() }
                    .buttonStyle(.borderedProminent)
                    .foregroundStyle(palette.onAccent)
                    .focused($focused, equals: .retry)
            }
        case let .error(message):
            VStack(spacing: 20) {
                Text(message).multilineTextAlignment(.center)
                Button("Try Again") { model.retry() }
                    .buttonStyle(.borderedProminent)
                    .foregroundStyle(palette.onAccent)
                    .focused($focused, equals: .retry)
            }
        }
    }
}

private struct SiloPairingCard: View {
    let code: String
    let match: String
    let approvalURL: URL
    let verificationURL: URL?
    let expiresAt: Date
    let lifetime: TimeInterval
    @Environment(\.openURL) private var openURL
    @Environment(\.themePalette) private var palette
    @State private var browserFailed = false

    var body: some View {
        VStack(spacing: 24) {
            #if os(tvOS)
            HStack(alignment: .top, spacing: 64) {
                SiloPairingQRCode(url: approvalURL, size: 400)
                    .frame(maxWidth: .infinity)
                SiloPairingInstructions(
                    code: code, verificationURL: verificationURL, expiresAt: expiresAt, lifetime: lifetime
                ) {
                    SiloMatchPhrase(match: match)
                }
                .padding(.horizontal, 36)
                .padding(.vertical, 32)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background {
                    RoundedRectangle(cornerRadius: PlozzTheme.Metrics.mediumCardCornerRadius)
                        .fill(palette.cardSurface)
                        .overlay {
                            RoundedRectangle(cornerRadius: PlozzTheme.Metrics.mediumCardCornerRadius)
                                .strokeBorder(palette.cardBorder.opacity(0.45), lineWidth: 1)
                        }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            #else
            VStack(spacing: 16) {
                Text("Approve Plozz in your browser, then return here. We'll continue automatically.")
                    .multilineTextAlignment(.center)
                Button {
                    browserFailed = false
                    openURL(approvalURL) { accepted in browserFailed = !accepted }
                } label: {
                    Label("Open Silo to approve", systemImage: "arrow.up.forward.app")
                        .foregroundStyle(palette.onAccent)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                if browserFailed {
                    Text("The browser couldn't open. Use the address below or scan the code with another device.")
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }
                SiloMatchPhrase(match: match)
                DisclosureGroup("Use another device") {
                    VStack(spacing: 24) {
                        SiloPairingQRCode(url: approvalURL, size: 220)
                        SiloPairingInstructions(
                            code: code, verificationURL: verificationURL,
                            expiresAt: expiresAt, lifetime: lifetime
                        ) { EmptyView() }
                    }
                    .padding(.vertical, 12)
                }
            }
            .frame(maxWidth: 520)
            #endif
        }
        .onChange(of: approvalURL) { _, _ in browserFailed = false }
    }
}

private struct SiloPairingQRCode: View {
    let url: URL
    let size: CGFloat

    var body: some View {
        VStack(spacing: 28) {
            Text("Scan with your phone").font(.title3.bold())
            BrandQRCodeView(payload: url.absoluteString, size: size)
                .accessibilityLabel("Scan to approve Plozz")
        }
    }
}

private struct SiloPairingInstructions<Footer: View>: View {
    let code: String
    let verificationURL: URL?
    let expiresAt: Date
    let lifetime: TimeInterval
    @ViewBuilder var footer: () -> Footer
    @Environment(\.themePalette) private var palette

    var body: some View {
        VStack(spacing: 24) {
            if let verificationURL {
                Text("Or enter a code at")
                    .font(.title3.bold())
                    .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: Self.displayAddress(verificationURL))
                    #if os(tvOS)
                    .font(.system(size: 40, weight: .semibold))
                    #else
                    .font(.headline)
                    #endif
                    .fixedSize(horizontal: false, vertical: true)
                    #if os(iOS)
                    .textSelection(.enabled)
                    #endif
            }
            HStack(spacing: 24) {
                Text(code)
                    #if os(tvOS)
                    .font(.plozzCode(size: 64))
                    #else
                    .font(.largeTitle.monospaced().bold())
                    #endif
                    .lineLimit(1).minimumScaleFactor(0.6)
                    .accessibilityLabel("Sign-in code: \(code)")
                    .padding(.horizontal, 24)
                    .padding(.vertical, 20)
                    .background {
                        RoundedRectangle(cornerRadius: PlozzTheme.Metrics.Radius.panel)
                            .fill(Color.black.opacity(palette.isLight ? 0.06 : 0.26))
                    }
                LinkCodeExpiryCountdown(expiresAt: expiresAt, lifetime: lifetime, size: 88, showsMinutes: true)
            }
            .fixedSize(horizontal: false, vertical: true)
            footer()
        }
    }

    private static func displayAddress(_ url: URL) -> String {
        let address = url.absoluteString
        guard let scheme = url.scheme, ["http", "https"].contains(scheme.lowercased()) else { return address }
        return String(address.dropFirst(scheme.count + 3))
    }
}

private struct SiloMatchPhrase: View {
    let match: String
    var body: some View {
        Label {
            Text("Before approving, check that Silo shows \(Text(verbatim: match).bold()).")
        } icon: {
            Image(systemName: "checkmark.shield")
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct SiloProfileChoices: View {
    let profiles: [SiloProfile]
    let focused: FocusState<SiloSignInFocus?>.Binding
    let select: (SiloProfile) -> Void
    var body: some View {
        PlozzScrollCard {
            #if os(tvOS)
            ScrollView { rows.padding(.horizontal, 40).padding(.vertical, 28) }
            #else
            rows.padding(12)
            #endif
        }
        .frame(maxWidth: 900)
    }

    private var rows: some View {
        VStack(spacing: 14) {
            ForEach(profiles) { profile in
                Button { select(profile) } label: {
                    ServerUserRow(provider: .silo, name: profile.name, requiresPIN: profile.has_pin)
                }
                .buttonStyle(SettingsFocusButtonStyle())
                .focused(focused, equals: .profile(profile.id))
                .accessibilityLabel(Text(profile.name))
                .accessibilityValue(profile.has_pin ? Text("PIN required") : Text(verbatim: ""))
                .accessibilityIdentifier("silo-profile-\(profile.id)")
            }
        }
    }
}
#endif
