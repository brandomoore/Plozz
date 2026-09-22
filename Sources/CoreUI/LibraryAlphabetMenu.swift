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
    let onSelect: (String) -> Void
    let onRetry: () -> Void
    #if os(tvOS)
    @State private var pendingSelection: String?
    #endif

    public init(entries: [LibraryLetterIndexEntry], isLoading: Bool,
                onSelect: @escaping (String) -> Void, onRetry: @escaping () -> Void) {
        self.entries = entries
        self.isLoading = isLoading
        self.onSelect = onSelect
        self.onRetry = onRetry
    }

    public var body: some View {
        Menu {
            ForEach(entries, id: \.letter) { entry in
                Button(entry.letter) {
                    #if os(tvOS)
                    pendingSelection = entry.letter
                    #else
                    onSelect(entry.letter)
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
            LibraryAlphabetMenuCompletion(selection: pendingSelection) { letter in
                pendingSelection = nil
                onSelect(letter)
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
    let selection: String?
    let onCommit: (String) -> Void

    func makeUIViewController(context: Context) -> Controller { Controller() }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.update(selection: selection, onCommit: onCommit)
    }

    static func dismantleUIViewController(_ controller: Controller, coordinator: ()) {
        controller.update(selection: nil, onCommit: nil)
    }

    final class Controller: UIViewController {
        private var selection: String?
        private var onCommit: ((String) -> Void)?
        private var displayLink: CADisplayLink?
        private var crossedFrame = false

        override func loadView() {
            view = UIView()
            view.isUserInteractionEnabled = false
            view.isAccessibilityElement = false
        }

        func update(selection: String?, onCommit: ((String) -> Void)?) {
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

public struct LibraryAlphabetStatus: View {
    let letter: String?
    let message: LocalizedStringResource?
    let onCancel: () -> Void

    public init(letter: String?, message: LocalizedStringResource?, onCancel: @escaping () -> Void) {
        self.letter = letter
        self.message = message
        self.onCancel = onCancel
    }

    public var body: some View {
        if let letter {
            HStack(spacing: 18) {
                ProgressView("Finding \(letter)…")
                Button("Cancel", action: onCancel)
            }
            .padding()
        } else if let message {
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding()
        }
    }
}
#endif
