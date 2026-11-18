#if os(tvOS)
import CoreNetworking
import CoreUI
import SwiftUI
import UIKit

struct HomeEditorAutosavingNameInput: View {
    let title: LocalizedStringResource
    let prompt: Text
    let identifier: String
    let axis: Axis
    let save: (String) throws -> Void
    @State private var name: String
    @State private var savedName: String
    @State private var saved = false
    @State private var failed = false
    @FocusState private var isFocused: Bool

    init(
        _ title: LocalizedStringResource, name: String, prompt: Text,
        identifier: String, axis: Axis = .vertical, save: @escaping (String) throws -> Void
    ) {
        self.title = title
        self.prompt = prompt
        self.identifier = identifier
        self.axis = axis
        self.save = save
        _name = State(initialValue: name)
        _savedName = State(initialValue: name.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    var body: some View {
        SettingsInputRow(title, status: status, axis: axis) {
            TextField(text: $name, prompt: prompt) { Text(title) }
                .focused($isFocused)
                .submitLabel(.done)
                .accessibilityIdentifier(identifier)
                .onSubmit { isFocused = false }
                .background(NameEditingObserver(
                    began: { saved = false }, ended: commit
                ))
                .onChange(of: name) { _, value in
                    if value.trimmingCharacters(in: .whitespacesAndNewlines) != savedName {
                        saved = false
                    }
                }
        }
        if failed {
            Button("Retry") { commit(name) }
                .buttonStyle(SettingsFormButtonStyle())
                .accessibilityIdentifier("\(identifier)-retry")
        }
    }

    private var status: Text? {
        if failed { return Text("Couldn't save").foregroundStyle(.red) }
        if saved { return Text("\(Image(systemName: "checkmark")) Saved").foregroundStyle(.secondary) }
        return nil
    }

    private func commit(_ value: String) {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        name = normalized
        guard normalized != savedName else {
            failed = false
            return
        }
        do {
            try save(normalized)
            savedName = normalized
            failed = false
            saved = true
            AccessibilityNotification.Announcement(
                String(localized: "Saved") // l10n:content — resolved for an immediate announcement
            ).post()
        } catch {
            saved = false
            failed = true
            PlozzLog.app.error("Could not autosave settings name")
        }
    }
}

// Remote focus remains on the field when the TV keyboard closes. Observe
// native editing, not focus loss; Back does not send SwiftUI's onSubmit.
private struct NameEditingObserver: UIViewRepresentable {
    let began: () -> Void
    let ended: (String) -> Void

    func makeUIView(context: Context) -> ObserverView { ObserverView() }

    func updateUIView(_ view: ObserverView, context: Context) {
        view.began = began
        view.ended = ended
    }

    static func dismantleUIView(_ view: ObserverView, coordinator: ()) {
        view.began = nil
        view.ended = nil
        NotificationCenter.default.removeObserver(view)
    }

    final class ObserverView: UIView {
        var began: (() -> Void)?
        var ended: ((String) -> Void)?
        private weak var field: UITextField?

        init() {
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            isAccessibilityElement = false
            NotificationCenter.default.addObserver(
                self, selector: #selector(editingBegan),
                name: UITextField.textDidBeginEditingNotification, object: nil
            )
            NotificationCenter.default.addObserver(
                self, selector: #selector(editingEnded),
                name: UITextField.textDidEndEditingNotification, object: nil
            )
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        @objc private func editingBegan(_ event: Notification) {
            guard let input = event.object as? UITextField, let window,
                  input.window === window,
                  input.convert(input.bounds, to: self).contains(CGPoint(x: bounds.midX, y: bounds.midY))
            else { return }
            // SwiftUI's identifier belongs to its accessibility proxy, not
            // the backing UITextField. Match the field under this background.
            field = input
            began?()
        }

        @objc private func editingEnded(_ event: Notification) {
            guard let input = event.object as? UITextField, input === field else { return }
            field = nil
            ended?(input.text ?? "")
        }
    }
}
#endif
