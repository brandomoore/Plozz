import CoreModels
import CoreUI
import FeatureAuthCore
import SwiftUI
import UniformTypeIdentifiers

public struct IPTVSignInView: View {
    @State private var model: IPTVAuthViewModel
    @Environment(\.themePalette) private var palette
    private let onCancel: () -> Void

    public init(
        deviceID: String, address: String = "", name: String = "", guideAddress: String = "",
        guideURLs: [URL] = [], reconnecting: UserSession? = nil, initialMode: IPTVCredential.Mode = .playlist,
        discoversPlaylistGuides: Bool = true,
        onAuthenticated: @escaping (UserSession) throws -> Void, onCancel: @escaping () -> Void
    ) {
        _model = State(initialValue: IPTVAuthViewModel(
            deviceID: deviceID, address: address, name: name, guideAddress: guideAddress,
            guideURLs: guideURLs, reconnecting: reconnecting, initialMode: initialMode,
            discoversPlaylistGuides: discoversPlaylistGuides,
            onAuthenticated: onAuthenticated
        ))
        self.onCancel = onCancel
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                OnboardingHeader(Text("Connect your IPTV provider"))
                IPTVConnectionFields(model: model)
                    .disabled(model.isConnecting)
                IPTVConnectionStatus(model: model)
                Button(role: .cancel) {
                    model.cancel()
                    onCancel()
                } label: {
                    Text("Cancel").frame(maxWidth: .infinity)
                }
                .plozzActionButton(role: .secondary)
            }
            .frame(maxWidth: 840)
            .padding(32)
            .frame(maxWidth: .infinity)
        }
        .foregroundStyle(palette.primaryText)
        .background { SettingsPageBackground() }
        .navigationTitle("IPTV")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        #else
        .onExitCommand { model.cancel(); onCancel() }
        #endif
        .onDisappear { model.cancel() }
    }
}

private struct IPTVConnectionFields: View {
    @Bindable var model: IPTVAuthViewModel
    @State private var showsAdvanced: Bool

    init(model: IPTVAuthViewModel) {
        self.model = model
        _showsAdvanced = State(initialValue: model.hasAdvancedConfiguration)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsSectionGroup {
                Picker("Connection type", selection: $model.mode) {
                    Text("Playlist URL").tag(IPTVCredential.Mode.playlist)
                    Text("Xtream account").tag(IPTVCredential.Mode.xtream)
                    #if os(iOS)
                    Text("Playlist file").tag(IPTVCredential.Mode.file)
                    #endif
                }
                .accessibilityIdentifier("iptv-connection-type")
                if model.mode == .file {
                    #if os(iOS)
                    IPTVPlaylistFileFields(model: model)
                    #else
                    Text("Import this playlist file on an iPhone or iPad.")
                    #endif
                } else {
                    IPTVAddressField(
                        title: model.mode == .playlist ? "Playlist URL" : "Server address",
                        value: $model.address
                    )
                }
                TextField("Name (optional)", text: $model.name)
                if model.mode == .xtream {
                    IPTVLoginFields(username: $model.username, password: $model.password)
                }
                Button {
                    showsAdvanced.toggle()
                } label: {
                    HStack {
                        Text("Advanced options")
                        Spacer()
                        Image(systemName: showsAdvanced ? "chevron.up" : "chevron.down")
                            .accessibilityHidden(true)
                    }
                }
                .buttonStyle(SettingsFocusButtonStyle(size: .contained))
                .accessibilityIdentifier("iptv-advanced-options")
                .accessibilityValue(showsAdvanced
                    ? Text("Expanded", comment: "Accessibility state of an expanded section of a form.")
                    : Text("Collapsed", comment: "Accessibility state of a collapsed section of a form."))
            }
            if showsAdvanced {
                if model.mode == .playlist {
                    IPTVPlaylistAuthenticationFields(model: model)
                }
                IPTVAdvancedFields(model: model)
            }
            if model.usesHTTP {
                Text("HTTP is unencrypted. Use HTTPS when available.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.body)
        .onChange(of: model.mode) { _, _ in
            if model.hasAdvancedConfiguration { showsAdvanced = true }
        }
    }
}

private struct IPTVPlaylistAuthenticationFields: View {
    @Bindable var model: IPTVAuthViewModel

    var body: some View {
        SettingsSectionGroup("Authentication") {
            Menu {
                Picker("Authentication", selection: $model.authentication) {
                    ForEach(IPTVAuthViewModel.Authentication.allCases) { method in
                        Text(method.title).tag(method)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                HStack {
                    Text(model.authentication.title)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption)
                        .accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(SettingsFocusButtonStyle(size: .contained))
            .accessibilityLabel("Authentication")
            .accessibilityValue(Text(model.authentication.title))
            .accessibilityIdentifier("iptv-authentication")
            if model.authentication == .basic {
                IPTVLoginFields(username: $model.username, password: $model.password)
            } else if model.authentication == .bearer {
                SecureField("Bearer token", text: $model.token)
                    .textContentType(.password)
            }
        }
    }
}

#if os(iOS)
private struct IPTVPlaylistFileFields: View {
    @Bindable var model: IPTVAuthViewModel
    @State private var showsFilePicker = false
    @State private var fileSelectionFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button("Choose playlist file", systemImage: "doc") { showsFilePicker = true }
            if let file = model.playlistFileURL {
                Text(verbatim: file.lastPathComponent).font(.caption)
            }
            Text("Imported files stay on this device. Import a replacement to update the catalogue.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .fileImporter(
            isPresented: $showsFilePicker,
            allowedContentTypes: [.data], allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls): model.playlistFileURL = urls.first
            case .failure: fileSelectionFailed = true
            }
        }
        .alert("The playlist file couldn't be opened", isPresented: $fileSelectionFailed) {
            Button("OK", role: .cancel) {}
        }
    }
}
#endif

private struct IPTVLoginFields: View {
    @Binding var username: String
    @Binding var password: String
    var body: some View {
        TextField("Username", text: $username)
            .textContentType(.username)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        SecureField("Password", text: $password)
            .textContentType(.password)
    }
}

private struct IPTVAddressField: View {
    let title: LocalizedStringResource
    @Binding var value: String
    var body: some View {
        TextField(text: $value, prompt: Text(title)) { Text(title) }
            .accessibilityLabel(Text(title))
            .textContentType(.URL)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            #if os(iOS)
            .keyboardType(.URL)
            #endif
    }
}

private struct IPTVAdvancedFields: View {
    @Bindable var model: IPTVAuthViewModel
    var body: some View {
        SettingsSectionGroup("Program guides") {
            if model.mode != .xtream {
                Toggle(isOn: $model.discoversPlaylistGuides) {
                    Text("Find guides in playlist").font(.body)
                }
            }
            IPTVAddressField(title: "Guide URL (optional)", value: $model.guideAddress)
            ForEach($model.additionalGuides) { $guide in
                IPTVAddressField(title: "Additional guide URL", value: $guide.address)
                Button(role: .destructive) { [id = guide.id] in
                    model.additionalGuides.removeAll { $0.id == id }
                } label: {
                    Text("Remove guide").frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(SettingsFocusButtonStyle(size: .contained))
            }
            Button(action: model.addGuide) {
                Label("Add guide", systemImage: "plus").frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(SettingsFocusButtonStyle(size: .contained))
            .disabled(model.additionalGuides.count >= 31)
        }
        if model.mode != .file {
            SettingsSectionGroup("Playlist and stream headers") {
                IPTVHeaderFields(headers: $model.headers, add: model.addHeader)
            }
        }
        SettingsSectionGroup("Guide request headers") {
            IPTVHeaderFields(headers: $model.guideHeaders, add: model.addGuideHeader)
        } footer: {
            Text("These headers apply only to the server in the first guide URL. Leave them empty when the guide uses your playlist credentials.")
        }
    }
}

private struct IPTVHeaderFields: View {
    @Binding var headers: [IPTVAuthViewModel.Header]
    let add: () -> Void
    var body: some View {
        ForEach($headers) { $header in
            VStack(alignment: .leading, spacing: 12) {
                TextField("Header name", text: $header.name)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Header value", text: $header.value)
                Button(role: .destructive) { [id = header.id] in
                    headers.removeAll { $0.id == id }
                } label: {
                    Text("Remove header").frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(SettingsFocusButtonStyle(size: .contained))
            }
        }
        Button(action: add) {
            Label("Add header", systemImage: "plus").frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(SettingsFocusButtonStyle(size: .contained))
        .disabled(headers.count >= 32)
    }
}

private struct IPTVConnectionStatus: View {
    let model: IPTVAuthViewModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.isConnecting {
                ProgressView(model.progressMessage)
            }
            if let issue = model.issue {
                Label(issue, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }
            Button(action: model.connect) {
                Text("Connect").frame(maxWidth: .infinity)
            }
            .plozzActionButton(role: .primary)
            .disabled(!model.canConnect)
            .accessibilityIdentifier("iptv-connect")
        }
    }
}
