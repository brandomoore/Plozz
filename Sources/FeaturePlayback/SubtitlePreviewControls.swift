#if os(tvOS)
import CoreModels
import CoreUI
import SwiftUI

enum SubtitlePreviewControl: Hashable {
    case header, background, fileFormatting, hdrBrightness
}

struct SubtitlePreviewControls: View {
    let style: SubtitleStyle
    let secondaryVisible: Bool
    @Bindable var options: SubtitlePreviewOptions
    @Binding var fullscreenPresented: Bool
    @FocusState.Binding var focus: SubtitlePreviewControl?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.themePalette) private var palette
    @State private var expanded = false

    var body: some View {
        VStack(spacing: 2) {
            Button {
                options.beginFullscreenPresentation()
                fullscreenPresented = true
            } label: {
                HStack {
                    Text("Preview").font(.headline)
                    Spacer()
                    Label("Full screen", systemImage: "arrow.up.left.and.arrow.down.right")
                        .font(.callout)
                        .playerMenuRowSecondary()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(PlayerMenuRowButtonStyle())
            .focusEffectDisabled()
            .focused($focus, equals: .header)
            .accessibilityHint("Select for full-screen preview. Move down for preview options.")
            if expanded {
                PlozzDivider().padding(.horizontal, 16).padding(.vertical, 4)
                option("Animate background", selection: $options.animatesBackground, control: .background)
                option("Preview file formatting", selection: $options.showsFileFormatting, control: .fileFormatting)
                option("HDR preview", selection: $options.showsHDRBrightness, control: .hdrBrightness)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .settingsGroupSurface(cornerRadius: 28)
        .focusSection()
        .task(id: focus) {
            if focus == nil {
                await Task.yield()
                guard !Task.isCancelled, focus == nil, !fullscreenPresented else { return }
            }
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                expanded = focus != nil
            }
        }
        .fullScreenCover(isPresented: $fullscreenPresented, onDismiss: {
            options.finishFullscreenPresentation()
            focus = .header
        }) {
            FullscreenSubtitlePreview(
                style: style, secondaryVisible: secondaryVisible, options: options,
                close: { fullscreenPresented = false }
            )
        }
        .onChange(of: fullscreenPresented, initial: true) { _, presented in
            if presented { options.beginFullscreenPresentation() }
        }
    }

    private func option(
        _ title: LocalizedStringResource,
        selection: Binding<Bool>,
        control: SubtitlePreviewControl
    ) -> some View {
        Button {
            selection.wrappedValue.toggle()
        } label: {
            HStack {
                Text(title)
                Spacer(minLength: 12)
                Image(systemName: selection.wrappedValue ? "checkmark.circle.fill" : "circle")
                    .playerMenuRowMark(isSelected: selection.wrappedValue, accent: palette.accent)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlayerMenuRowButtonStyle())
        .focusEffectDisabled()
        .focused($focus, equals: control)
    }
}

private struct FullscreenSubtitlePreview: View {
    let style: SubtitleStyle
    let secondaryVisible: Bool
    let options: SubtitlePreviewOptions
    let close: () -> Void
    @FocusState private var closeFocused: Bool
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        GeometryReader { geometry in
            SubtitleStylePreviewCanvas(
                style: style, secondaryVisible: secondaryVisible,
                referenceSize: geometry.size,
                showsFileFormatting: options.showsFileFormatting,
                showsHDRBrightness: options.showsHDRBrightness && options.hdrPreview.state == .ready,
                animate: options.animatesBackground,
                backgroundOptions: options,
                hdrVideo: options.showsHDRBrightness ? options.hdrPreview : nil
            )
        }
        .ignoresSafeArea()
        .overlay(alignment: .topLeading) {
            Button(action: close) {
                Label("Back", systemImage: "chevron.left")
            }
            .buttonStyle(PlozzPanelHeaderButtonStyle())
            .background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 14))
            .environment(\.colorScheme, .dark)
            .focusEffectDisabled()
            .focused($closeFocused)
            .padding(48)
        }
        .onAppear {
            closeFocused = true
            options.setVisible(true, fullscreen: true, sceneActive: scenePhase == .active)
        }
        .onDisappear { options.setVisible(false, fullscreen: true, sceneActive: scenePhase == .active) }
        .onChange(of: scenePhase) { _, phase in options.setSceneActive(phase == .active) }
        .onExitCommand(perform: close)
    }
}
#endif
