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
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 28) {
                    SiloSignInHeader(title: title, address: server.baseURL.absoluteString,
                                     choosingProfile: isChoosingProfile)
                    content
                    Button("Back", action: cancel)
                        .buttonStyle(.bordered)
                        .focused($focused, equals: .cancel)
                        .padding(.top, 12)
                }
                .frame(maxWidth: 1040)
                .padding(.horizontal, 28)
                .padding(.vertical, 32)
                .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
            .scrollClipDisabled()
        }
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

    private var title: LocalizedStringResource {
        switch model.phase {
        case .profiles: "Choose your Silo profile"
        case .pin: "Unlock your profile"
        case .pairing: "Approve this device"
        case .expired: "Your code has expired"
        case .error: "Let's get you connected"
        default: "Connect to Silo"
        }
    }

    private var isChoosingProfile: Bool {
        if case .profiles = model.phase { return true }
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
                            verificationURL: model.verificationURL, expiresAt: expiresAt)
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
                    .focused($focused, equals: .retry)
            }
        case let .error(message):
            VStack(spacing: 20) {
                Text(message).multilineTextAlignment(.center)
                Button("Try Again") { model.retry() }
                    .buttonStyle(.borderedProminent)
                    .focused($focused, equals: .retry)
            }
        }
    }
}

private struct SiloSignInHeader: View {
    let title: LocalizedStringResource
    let address: String
    let choosingProfile: Bool

    var body: some View {
        VStack(spacing: 12) {
            ProviderBrandMark(provider: .silo, size: 60)
            OnboardingHeader(Text(title), subtitle: Text(verbatim: address))
            if choosingProfile {
                Label("Device approved", systemImage: "checkmark.circle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("Your library access and watch history follow this profile.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
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
    @Environment(\.openURL) private var openURL
    @State private var browserFailed = false

    var body: some View {
        VStack(spacing: 24) {
            #if os(tvOS)
            HStack(alignment: .center, spacing: 44) {
                SiloPairingQRCode(url: approvalURL, size: 300)
                SiloPairingInstructions(code: code, match: match, verificationURL: verificationURL)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            #else
            VStack(spacing: 16) {
                Text("Approve Plozz in your browser, then return here. We'll continue automatically.")
                    .multilineTextAlignment(.center)
                Button {
                    browserFailed = false
                    openURL(approvalURL) { accepted in browserFailed = !accepted }
                } label: {
                    Label("Open Silo to approve", systemImage: "arrow.up.forward.app")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                if browserFailed {
                    Text("The browser couldn't open. Use the address below or scan the code with another device.")
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }
                SiloPairingInstructions(code: code, match: match, verificationURL: verificationURL)
                DisclosureGroup("Use another device") {
                    SiloPairingQRCode(url: approvalURL, size: 220)
                        .padding(.vertical, 12)
                }
            }
            .frame(maxWidth: 520)
            #endif
            SiloPairingStatus(expiresAt: expiresAt)
        }
        .onChange(of: approvalURL) { _, _ in browserFailed = false }
    }
}

private struct SiloPairingQRCode: View {
    let url: URL
    let size: CGFloat

    var body: some View {
        VStack(spacing: 14) {
            BrandQRCodeView(payload: url.absoluteString,
                            moduleColor: Color(red: 0.08, green: 0.22, blue: 0.50), size: size)
                .padding(20)
                .background(Color(red: 0xD6 / 255, green: 0xE5 / 255, blue: 1),
                            in: RoundedRectangle(cornerRadius: 24))
                .accessibilityLabel("Scan to approve Plozz")
            Text("Scan with your phone").font(.headline)
        }
    }
}

private struct SiloPairingInstructions: View {
    let code: String
    let match: String
    let verificationURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let verificationURL {
                Text("Or open this address and enter the sign-in code:")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(verificationURL.absoluteString)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                    #if os(iOS)
                    .textSelection(.enabled)
                    #endif
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Sign-in code").font(.caption).foregroundStyle(.secondary)
                Text(code)
                    #if os(tvOS)
                    .font(.plozzCode(size: 72))
                    #else
                    .font(.largeTitle.monospaced().bold())
                    #endif
                    .lineLimit(1).minimumScaleFactor(0.6)
                    .accessibilityLabel("Sign-in code: \(code)")
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20))
            Label {
                Text("Before approving, check that Silo shows \(match).")
            } icon: {
                Image(systemName: "checkmark.shield")
            }
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct SiloPairingStatus: View {
    let expiresAt: Date

    var body: some View {
        let now = Date()
        VStack(spacing: 10) {
            ProgressView("Waiting for approval…")
            HStack(spacing: 6) {
                Text("Code expires in")
                Text(timerInterval: now...max(now, expiresAt), countsDown: true)
                    .monospacedDigit()
                    .fixedSize()
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
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
                .accessibilityValue(profile.has_pin ? Text("PIN required") : Text(verbatim: ""))
                .accessibilityIdentifier("silo-profile-\(profile.id)")
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
