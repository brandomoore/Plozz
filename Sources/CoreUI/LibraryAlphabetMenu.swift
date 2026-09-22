#if canImport(SwiftUI)
import CoreModels
import SwiftUI
#if os(tvOS)
import UIKit
#endif

/// Shared entry point; platforms retain their own grid and scrolling machinery.
public struct LibraryAlphabetMenu: View {
    let entries: [LibraryLetterIndexEntry]
    let isLoading: Bool
    let isJumping: Bool
    let onSelect: (String, UUID?) -> Void
    let onDismiss: (UUID) -> Void
    let onCancel: () -> Void
    let onRetry: () -> Void
    #if os(tvOS)
    @State private var pendingSelection: UUID?
    #endif

    public init(entries: [LibraryLetterIndexEntry], isLoading: Bool, isJumping: Bool,
                onSelect: @escaping (String, UUID?) -> Void, onDismiss: @escaping (UUID) -> Void,
                onCancel: @escaping () -> Void, onRetry: @escaping () -> Void) {
        self.entries = entries
        self.isLoading = isLoading
        self.isJumping = isJumping
        self.onSelect = onSelect
        self.onDismiss = onDismiss
        self.onCancel = onCancel
        self.onRetry = onRetry
    }

    public var body: some View {
        Menu {
            if isJumping {
                Button("Cancel jump", action: onCancel)
                Divider()
            }
            ForEach(entries, id: \.letter) { entry in
                Button(entry.letter) {
                    #if os(tvOS)
                    let id = UUID()
                    pendingSelection = id
                    onSelect(entry.letter, id)
                    #else
                    onSelect(entry.letter, nil)
                    #endif
                }
                .accessibilityLabel("Jump to \(entry.letter)")
            }
            if entries.isEmpty {
                Button("Retry alphabet index", action: onRetry)
            }
        } label: {
            Label("Jump to letter", systemImage: "textformat.abc")
        }
        .disabled(isLoading)
        .accessibilityIdentifier("library-alphabet-menu")
        #if os(tvOS)
        .background {
            LibraryAlphabetMenuCompletion(selection: pendingSelection) { id in
                pendingSelection = nil
                onDismiss(id)
            }
            .allowsHitTesting(false)
        }
        .onDisappear { pendingSelection = nil }
        #endif
    }
}

#if os(tvOS)
/// A Menu action runs before UIKit dismisses its presentation. Let its real
/// focus restoration finish before scrolling and handing focus to library content.
struct LibraryAlphabetMenuCompletion: UIViewControllerRepresentable {
    let selection: UUID?
    let onCommit: (UUID) -> Void

    func makeUIViewController(context: Context) -> Controller { Controller() }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.update(selection: selection, onCommit: onCommit)
    }

    static func dismantleUIViewController(_ controller: Controller, coordinator: ()) {
        controller.update(selection: nil, onCommit: nil)
    }

    final class Controller: UIViewController {
        private var selection: UUID?
        private var onCommit: ((UUID) -> Void)?
        private var displayLink: CADisplayLink?
        private var crossedFrame = false

        override func loadView() {
            view = UIView()
            view.isUserInteractionEnabled = false
            view.isAccessibilityElement = false
        }

        func update(selection: UUID?, onCommit: ((UUID) -> Void)?) {
            if self.selection != selection {
                stop()
                self.selection = selection
            }
            self.onCommit = onCommit
            schedule()
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            schedule()
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            stop()
        }

        private func schedule() {
            guard selection != nil, displayLink == nil, viewIfLoaded?.window != nil else { return }
            let link = CADisplayLink(target: self, selector: #selector(framePresented))
            displayLink = link
            link.add(to: .main, forMode: .common)
        }

        @objc private func framePresented() {
            guard let selection, let window = viewIfLoaded?.window else {
                stop()
                return
            }
            guard TVNavigationExitProtectionFocus.isFocusedInUnpresentedRoot(of: window) else {
                crossedFrame = false
                return
            }
            guard crossedFrame else {
                crossedFrame = true
                return
            }
            stop()
            self.selection = nil
            onCommit?(selection)
        }

        private func stop() {
            displayLink?.invalidate()
            displayLink = nil
            crossedFrame = false
        }
    }
}
#endif

/// Uses the root's existing watchlist/status toast, without adding another host
/// or focus target. A completed jump can only dismiss its own status generation.
public struct LibraryAlphabetFeedback: View {
    @Environment(\.transientStatusPresenter) private var presenter
    @State private var presentedGeneration: UInt64?
    let letter: String?
    let message: LocalizedStringResource?

    public init(letter: String?, message: LocalizedStringResource?) {
        self.letter = letter
        self.message = message
    }

    public var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onChange(of: feedback, initial: true) { _, _ in update() }
            .onDisappear { dismissOwnedStatus() }
    }

    private var feedback: TransientStatusMessage? {
        if let message {
            return .init(icon: "exclamationmark.circle", text: message)
        }
        guard let letter else { return nil }
        return .init(icon: "magnifyingglass", text: "Finding \(letter)…", isProgress: true)
    }

    private func update() {
        dismissOwnedStatus()
        guard let feedback else { return }
        let generation = presenter?.present(
            icon: feedback.icon, text: feedback.text, isProgress: feedback.isProgress)
        if feedback.isProgress { presentedGeneration = generation }
    }

    private func dismissOwnedStatus() {
        if let presentedGeneration {
            presenter?.dismiss(expectedGeneration: presentedGeneration)
            self.presentedGeneration = nil
        }
    }
}
#endif
