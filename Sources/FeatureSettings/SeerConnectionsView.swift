#if canImport(SwiftUI)
import CoreModels
import CoreUI
import SeerService
import SwiftUI
import UIKit

struct SeerSettingsPage<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        #if os(iOS)
        SettingsPageScroll {
            content
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity)
        }
        #else
        ScrollView {
            content
                .frame(maxWidth: PlozzTheme.Metrics.settingsContentMaxWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(PlozzTheme.Metrics.screenPadding)
        }
        .scrollClipDisabled()
        #endif
    }
}

public struct SeerConnectionsView: View {
    let seer: SeerService
    public init(seer: SeerService) { self.seer = seer }

    public var body: some View {
        #if os(iOS)
        List { SeerConnectionsContent(seer: seer) }
            .settingsPageSurface()
            .navigationTitle(Text(verbatim: "Seerr"))
        #else
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                SettingsPageHeader(verbatim: "Seerr")
                SeerConnectionsContent(seer: seer)
            }
            .frame(maxWidth: PlozzTheme.Metrics.settingsContentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(PlozzTheme.Metrics.screenPadding)
        }
        .scrollClipDisabled()
        #endif
    }
}

struct SeerConnectionsContent: View {
    let seer: SeerService
    @Environment(\.locale) private var locale
    @State private var adding = false
    @State private var reconnectID: UUID?
    @State private var editing: SeerAccountConnection?
    @State private var error: LocalizedStringResource?
    @State private var statusRetryID = UUID()

    var body: some View {
        if let message = seer.storageFailure {
            Text(message).foregroundStyle(.red)
        }
        if seer.profileConnections.connections.isEmpty {
            SeerSignInForm(seer: seer)
                #if os(iOS)
                .listRowInsets(EdgeInsets(top: 16, leading: 0, bottom: 16, trailing: 0))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                #endif
        } else {
            SettingsSectionGroup("Accounts") {
                ForEach(seer.profileConnections.connections) { connection in
                    Button {
                        editing = connection
                    } label: {
                        HStack {
                            SeerConnectionLabel(connection: connection)
                            Spacer()
                            if seer.profileConnections.selected?.id == connection.id {
                                Image(systemName: "checkmark").accessibilityLabel(Text("Selected"))
                            }
                            Image(systemName: "chevron.right").accessibilityHidden(true)
                        }
                    }
                    .settingsActionRow()
                }
                if case let .failed(message) = seer.phase {
                    Text(message).foregroundStyle(.red)
                    Button("Try again") { statusRetryID = UUID() }
                        .settingsActionRow()
                    Button("Edit connection") { reconnectID = seer.profileConnections.selected?.id; adding = true }
                        .settingsActionRow()
                }
                Button("Add account") { reconnectID = nil; adding = true }.settingsActionRow()
            }
            .sheet(isPresented: $adding) {
                SeerAccountEditor(seer: seer, replacing: reconnectID)
            }
            .sheet(item: $editing) { connection in
                SeerConnectionDetail(seer: seer, connectionID: connection.id)
            }
            .onChange(of: seer.activeProfileID) { adding = false; editing = nil }
            .task(id: [seer.connectionRevision, statusRetryID]) { await seer.refreshStatus() }
            SettingsSectionGroup("Requests") {
                if seer.profileConnections.connections.count > 1 {
                    SettingsMenuRow(title: "Default account", value: Text(
                        seer.profileConnections.connections.first { $0.id == seer.profileConnections.defaultID }?.accountName ?? ""
                    )) {
                        Picker("Default account", selection: Binding(
                            get: { seer.profileConnections.defaultID },
                            set: { value in update(defaultID: value) }
                        )) {
                            ForEach(seer.profileConnections.connections) { connection in
                                Text(verbatim: connection.choiceLabel(in: seer.profileConnections.connections, locale: locale))
                                    .tag(Optional(connection.id))
                            }
                        }
                    }
                    Toggle("Use last account", isOn: Binding(
                        get: { seer.profileConnections.rememberLastUsed },
                        set: { update(rememberLastUsed: $0) }
                    ))
                    Text("You’ll choose an account when requesting.")
                        .font(.footnote).plozzForeground(.secondary)
                } else {
                    Toggle("Ask each time", isOn: Binding(
                        get: { seer.profileConnections.askEachTime },
                        set: { update(askEachTime: $0) }
                    ))
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
        }
    }

    private func update(defaultID: UUID? = nil, rememberLastUsed: Bool? = nil, askEachTime: Bool? = nil) {
        do {
            try seer.updateSelection(
                defaultID: defaultID ?? seer.profileConnections.defaultID,
                rememberLastUsed: rememberLastUsed ?? seer.profileConnections.rememberLastUsed,
                askEachTime: askEachTime ?? seer.profileConnections.askEachTime
            )
            error = nil
        } catch { self.error = "Couldn’t save the Seerr preferences." }
    }
}

struct SeerConnectionDetail: View {
    let seer: SeerService
    let connectionID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var users: [SeerUser] = []
    @State private var error: LocalizedStringResource?
    @State private var reconnect = false

    var body: some View {
        SeerAccountPage {
            if let connection = seer.profileConnections.connections.first(where: { $0.id == connectionID }) {
                SettingsSectionGroup("Connection") {
                    SeerConnectionLabel(connection: connection)
                    if connection.requiresRelink {
                        Text("Choose the request account again.").foregroundStyle(.red)
                    }
                    if case .apiKey = connection.credential {
                        SettingsMenuRow(title: "Request as", value: Text(connection.accountName)) {
                            Picker("Request as", selection: Binding(
                                get: { connection.configuredUserID },
                                set: { value in
                                    do {
                                        if let value, !users.contains(where: { $0.id == value }) { throw AppError.notFound }
                                        try seer.setRequestUser(users.first { $0.id == value }, connectionID: connectionID)
                                    } catch { self.error = "Couldn’t change the request account." }
                                }
                            )) {
                                if !seer.refusesAdminRequests() { Text("Admin").tag(Optional<Int>.none) }
                                ForEach(users) { Text($0.name).tag(Optional($0.id)) }
                            }
                        }
                        .disabled(users.isEmpty)
                    }
                    Button("Sign in again") { reconnect = true }.settingsActionRow()
                    Button("Remove connection", role: .destructive) {
                        do { try seer.removeConnection(connectionID); dismiss() }
                        catch { self.error = "Couldn’t remove the Seerr connection." }
                    }
                    .settingsActionRow()
                    if let error { Text(error).foregroundStyle(.red) }
                }
            }
        }
        .sheet(isPresented: $reconnect) {
            SeerAccountEditor(seer: seer, replacing: connectionID)
        }
        .task(id: connectionID) {
            guard let connection = seer.profileConnections.connections.first(where: { $0.id == connectionID }),
                  case .apiKey = connection.credential else { return }
            do { users = try await seer.users(for: connectionID) }
            catch is CancellationError { return }
            catch { self.error = "Couldn’t load Seerr users." }
        }
    }
}

private extension SeerAccountConnection {
    func choiceLabel(in connections: [SeerAccountConnection], locale: Locale) -> String { // l10n:content - Native menu boundary, recomputed with the current environment locale.
        let sameUser = connections.filter { $0.accountName == accountName && $0.baseURL == baseURL }
        var label = accountName
        if sameUser.count > 1 {
            switch credential {
            case .apiKey: label = String(localized: LocalizedStringResource("\(accountName) (API key)", locale: locale)) // l10n:content - Current-language menu title; the account name is content.
            case .session: label = String(localized: LocalizedStringResource("\(accountName) (Account)", locale: locale)) // l10n:content - Current-language menu title; the account name is content.
            }
        }
        if Set(connections.map(\.baseURL)).count > 1 {
            label += "\n\(name.isEmpty ? baseURL.absoluteString : name)"
        }
        return label
    }

    var configuredUserID: Int? {
        if case let .apiKey(_, id, _) = credential { return id }
        return nil
    }
}

private struct SeerAccountEditor: View {
    let seer: SeerService
    var replacing: UUID?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        SeerAccountPage(dismissTitle: "Cancel") {
            SeerSignInForm(seer: seer, replacing: replacing) { dismiss() }
        }
    }
}

private struct SeerConnectionLabel: View {
    let connection: SeerAccountConnection
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(connection.accountName)
            Text(connection.name.isEmpty ? connection.baseURL.absoluteString : connection.name)
                .font(.footnote).plozzForeground(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct SeerAccountPage<Content: View>: View {
    @Environment(\.dismiss) private var dismiss
    var title: Text = Text(verbatim: "Seerr")
    var dismissTitle: LocalizedStringResource = "Done"
    @ViewBuilder var content: Content

    var body: some View {
        NavigationStack {
            SeerSettingsPage {
                VStack(alignment: .leading, spacing: 24) {
                    #if os(tvOS)
                    SettingsPageHeader(title)
                        .environment(\.settingsPageBackButton, AnyView(SettingsBackButton { dismiss() }))
                    #endif
                    content
                }
            }
            #if os(iOS)
            .navigationTitle(title)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button { dismiss() } label: { Text(dismissTitle) } } }
            #else
            .onExitCommand { dismiss() }
            #endif
            .background { SettingsPageBackground() }
        }
    }
}

public extension View {
    func seerRequestDestination(_ seer: SeerService) -> some View {
        background {
            SeerDestinationPresenter(seer: seer, requestID: seer.pendingDestination)
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
        }
    }
}

private struct SeerDestinationPresenter: UIViewControllerRepresentable {
    let seer: SeerService
    let requestID: UUID?

    func makeUIViewController(context: Context) -> SeerDestinationController {
        SeerDestinationController(seer: seer, locale: context.environment.locale)
    }

    func updateUIViewController(_ controller: SeerDestinationController, context: Context) {
        controller.locale = context.environment.locale
        controller.update()
    }

    static func dismantleUIViewController(_ controller: SeerDestinationController, coordinator: ()) {
        controller.cancel()
    }
}

/// The request may originate inside a sheet; present from this scene's visible
/// controller instead of asking the already-covered root to open another modal.
private final class SeerDestinationController: UIViewController {
    let seer: SeerService
    var locale: Locale
    private var presentedRequestID: UUID?
    private weak var choice: UIAlertController?

    init(seer: SeerService, locale: Locale) {
        self.seer = seer
        self.locale = locale
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        update()
    }

    func update() {
        guard let requestID = seer.pendingDestination else {
            choice?.dismiss(animated: false)
            choice = nil
            presentedRequestID = nil
            return
        }
        guard presentedRequestID != requestID else { return }
        Task { @MainActor [weak self] in self?.presentChoice(requestID) }
    }

    private func presentChoice(_ requestID: UUID) {
        guard seer.pendingDestination == requestID, presentedRequestID != requestID,
              var presenter = view.window?.rootViewController else { return }
        while let presented = presenter.presentedViewController { presenter = presented }
        if let transition = presenter.transitionCoordinator {
            transition.animate(alongsideTransition: nil) { [weak self] _ in self?.update() }
            return
        }
        #if os(tvOS)
        let style: UIAlertController.Style = .alert
        #else
        let style: UIAlertController.Style = .actionSheet
        #endif
        let connections = seer.profileConnections.connections
        let servers = Set(connections.map(\.baseURL))
        let alert = UIAlertController(
            title: String(localized: LocalizedStringResource("Request as", locale: locale)), // l10n:content - UIKit alert title resolved for the current profile language on presentation.
            message: servers.count == 1 ? servers.first?.absoluteString : nil, preferredStyle: style
        )
        let selected = seer.profileConnections.selected
        let ordered = selected.map { [$0] } ?? []
        for connection in ordered + seer.profileConnections.connections.filter({ $0.id != selected?.id }) {
            alert.addAction(UIAlertAction(title: connection.choiceLabel(in: connections, locale: locale), style: .default) { [weak self] _ in
                guard let self, seer.pendingDestination == requestID else { return }
                seer.chooseDestination(connection.id)
            })
        }
        alert.addAction(UIAlertAction(title: String(localized: LocalizedStringResource("Cancel", locale: locale)), style: .cancel) { [weak self] _ in // l10n:content - UIKit action resolved for the current profile language on presentation.
            guard let self, seer.pendingDestination == requestID else { return }
            seer.chooseDestination(nil)
        })
        #if os(iOS)
        if let popover = alert.popoverPresentationController {
            popover.sourceView = presenter.view
            popover.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 1, height: 1)
            popover.permittedArrowDirections = []
        }
        #endif
        presentedRequestID = requestID
        choice = alert
        presenter.present(alert, animated: true)
    }

    func cancel() {
        choice?.dismiss(animated: false)
        if let presentedRequestID, seer.pendingDestination == presentedRequestID { seer.chooseDestination(nil) }
    }
}

#endif
