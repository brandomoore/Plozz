#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI
import FeatureDiscoveryCore

/// tvOS server picker: nearby servers and manual entry, without saved identities.
///
/// Uses native focusable controls (`List`, `Button`, `TextField`) so the focus
/// engine and Siri Remote work without custom handling.
public struct ServerPickerView: View {
    @State private var viewModel: ServerPickerViewModel
    @FocusState private var focusedControl: FocusTarget?
    private let provider: ProviderKind
    private let isPageReady: Bool
    private let onSelect: (MediaServer) -> Void
    /// Invoked when the user backs out — the in-bounds Back button or the Siri
    /// Remote's Menu button. `nil` hides the Back button and lets Menu fall
    /// through. Onboarding passes a closure that returns to the provider
    /// chooser, so Menu no longer quits the app from this screen.
    private let onBack: (() -> Void)?

    private enum FocusTarget: Hashable {
        case back
        case rescan
        case server(String)
        case manualField
        case connect
    }

    @MainActor
    public init(
        viewModel: ServerPickerViewModel? = nil,
        provider: ProviderKind = .jellyfin,
        isPageReady: Bool = true,
        onBack: (() -> Void)? = nil,
        onSelect: @escaping (MediaServer) -> Void
    ) {
        let vm = viewModel ?? ServerPickerViewModel(provider: provider, store: DiscoveryOnlyServerStore())
        _viewModel = State(initialValue: vm)
        self.provider = provider
        self.isPageReady = isPageReady
        self.onBack = onBack
        self.onSelect = onSelect
    }


    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                if provider == .silo {
                    HStack(spacing: 18) {
                        ProviderBrandMark(provider: .silo, size: 60)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Choose your Silo server").font(.title2.bold())
                            Text("Select a server below. You'll approve Plozz in your browser, then choose a profile.")
                                .font(.callout).plozzForeground(.secondary)
                        }
                    }
                }

                PickerPanel(title: "Servers", titleAccessory: { scanIndicator }) {
                    let discovered = viewModel.discoveredServers
                    // Discovery starts after the parent transition; keep later
                    // result insertions instant so only navigation animates.
                    Group {
                        if discovered.isEmpty {
                            emptyServersPlaceholder
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 8)
                                .padding(.horizontal, 12)
                        } else {
                            // No flush dividers between rows: the focus highlight
                            // bleeds a few points outward, so a divider sitting
                            // directly against a row gets painted over on focus. A
                            // gap lets each row's focus lift breathe and act as its
                            // own separator (matches the Settings pages' row lists).
                            VStack(spacing: 16) {
                                ForEach(discovered, id: \.self) { server in
                                    serverRow(server)
                                }
                            }
                        }
                    }
                    .transaction { $0.animation = nil }
                }

                if viewModel.isOnTailscale {
                    // Headerless card: its own "Connected to Tailscale" title says
                    // what it is, so a section header would just be redundant.
                    PickerPanel {
                        tailscaleGuidance
                    }
                }

                PickerPanel(
                    title: "Enter address",
                    footer: manualEntryFooter
                ) {
                    VStack(alignment: .leading, spacing: 18) {
                        TextField("Server address", text: $viewModel.manualURLText)
                            .focused($focusedControl, equals: .manualField)
                            .textContentType(.URL)
                            .autocorrectionDisabled()
                            .disabled(viewModel.phase == .validating)
                            .onSubmit { Task { await connectManually() } }
                        Button {
                            Task { await connectManually() }
                        } label: {
                            if viewModel.phase == .validating {
                                ProgressView("Checking server…")
                            } else {
                                Text("Connect")
                            }
                        }
                            .disabled(!viewModel.canSubmitManualURL)
                            .focused($focusedControl, equals: .connect)
                    }
                }

                if case let .error(message) = viewModel.phase {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                }
            }
            // Match the Settings pages: cap the column at the shared content
            // width and center it, with screen-padding gutters on each side so
            // the outward focus lift/shadow has room to breathe.
            .frame(maxWidth: PlozzTheme.Metrics.settingsContentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, PlozzTheme.Metrics.screenPadding)
            .padding(.vertical, 32)
        }
        // Never clip the outward-growing focus highlight/shadow at the
        // width-capped column edges (same reason the Settings pages disable it).
        .scrollClipDisabled()
        .defaultFocus($focusedControl, preferredInitialFocus)
        // The Siri Remote's Menu/back button steps back to the provider chooser
        // instead of quitting the app.
        .onExitCommand { onBack?() }
        .onAppear {
            let initialFocus = preferredInitialFocus
            focusedControl = initialFocus
            if isPageReady { viewModel.startScan() }
        }
        .onChange(of: isPageReady) { _, ready in
            if ready {
                viewModel.startScan()
            } else {
                viewModel.stopScan()
            }
        }
        .onDisappear { viewModel.stopScan() }
    }

    // MARK: - Header (in-bounds Back + Rescan)

    private var manualEntryFooter: LocalizedStringResource {
        if provider == .silo {
            return "Use the address you open Silo with in a browser. An IP address alone uses port 8090; include a different port or path if your server needs it."
        }
        return "Enter an IP address or full URL, e.g. 192.168.1.10 or \(provider == .emby ? "emby.example.com" : "jelly.example.com")"
    }

    private var header: some View {
        HStack {
            if let onBack {
                Button(action: onBack) {
                    Label("Back", systemImage: "chevron.backward")
                }
                .buttonStyle(.bordered)
                .focused($focusedControl, equals: .back)
            }
            Spacer(minLength: 24)
            Button { viewModel.startScan() } label: {
                Label("Rescan", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .disabled(viewModel.phase == .validating)
            .focused($focusedControl, equals: .rescan)
        }
        .padding(.top, PlozzTheme.Spacing.large)
    }

    private var preferredInitialFocus: FocusTarget {
        onBack == nil ? .rescan : .back
    }

    /// Small trailing spinner shown beside the "Servers" card header while a
    /// scan is in flight.
    @ViewBuilder
    private var scanIndicator: some View {
        if case .scanning = viewModel.phase { ProgressView() }
    }

    private var emptyServersPlaceholder: some View {
        Group {
            if case .scanning = viewModel.phase {
                Label("Searching for servers…", systemImage: "antenna.radiowaves.left.and.right")
                    .plozzForeground(.secondary)
            } else {
                Label("No servers found yet. Make sure your server is on and that Plozz is allowed Local Network access (tvOS Settings ▸ General ▸ Privacy), then rescan — or enter an address below.", systemImage: "magnifyingglass")
                    .plozzForeground(.secondary)
            }
        }
    }

    /// Tailscale guidance, shown only when this Apple TV is on a tailnet. Its
    /// real purpose is to say Tailscale servers can't be auto-discovered and
    /// must be entered manually. The logo matches the server-row logo size.
    private var tailscaleGuidance: some View {
        HStack(alignment: .top, spacing: 20) {
            TailscaleLogo()
                .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 8) {
                Text("Connected to Tailscale")
                    .font(.headline)
                Text("Tailscale servers can't be found automatically. Manually type your Tailscale IP or MagicDNS name below.")
                    .font(.subheadline)
                    .plozzForeground(.secondary)
            }
        }
    }

    private func serverRow(_ server: MediaServer) -> some View {
        Button {
            viewModel.manualURLText = server.baseURL.absoluteString
            Task { await connectManually() }
        } label: {
            // Logo top-aligned with the server name so it lines up with the
            // first line when a name/address wraps to two lines.
            HStack(alignment: .top, spacing: 20) {
                ProviderBrandMark(
                    provider: server.provider,
                    size: 44,
                    mediaShareTransport: MediaShareTransportKind(mediaShareScheme: server.baseURL.scheme)
                )
                VStack(alignment: .leading, spacing: 6) {
                    Text(server.name).font(.headline)
                    if let host = server.baseURL.host {
                        Text(host).font(.subheadline).settingsRowSecondary()
                    }
                }
                Spacer(minLength: 12)
                statusText("On your network", systemImage: "wifi")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 16)
            .padding(.horizontal, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(SettingsFocusButtonStyle(size: .prominent))
        .disabled(viewModel.phase == .validating)
        .focused($focusedControl, equals: .server(ServerIdentity.key(for: server)))
    }

    private func statusText(_ title: LocalizedStringResource, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.footnote)
            .settingsRowSecondary()
            .layoutPriority(1)
            .fixedSize()
    }

    private func connectManually() async {
        if let server = await viewModel.submitManualURL() {
            onSelect(server)
        }
    }
}

/// A titled `.ultraThinMaterial` card matching the Settings pages' `SettingsPanel`
/// (uppercase secondary header, optional trailing accessory + footer). Kept local
/// to FeatureDiscovery so the picker reads as Settings without depending on it.
private struct PickerPanel<Content: View, Accessory: View>: View {
    var title: LocalizedStringResource? = nil
    var footer: LocalizedStringResource? = nil
    var titleAccessory: () -> Accessory
    var content: () -> Content

    init(
        title: LocalizedStringResource? = nil,
        footer: LocalizedStringResource? = nil,
        @ViewBuilder titleAccessory: @escaping () -> Accessory = { EmptyView() },
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.footer = footer
        self.titleAccessory = titleAccessory
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if title != nil {
                HStack {
                    if let title {
                        Text(title)
                            .font(.subheadline.weight(.semibold))
                            .textCase(.uppercase)
                            .tracking(1.0)
                            .plozzForeground(.secondary)
                    }
                    Spacer()
                    titleAccessory()
                }
            }
            content()
            if let footer {
                Text(footer)
                    .font(.footnote)
                    .plozzForeground(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(28)
        .background(
            RoundedRectangle(cornerRadius: PlozzTheme.Metrics.mediumCardCornerRadius, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: PlozzTheme.Metrics.mediumCardCornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}

#endif
