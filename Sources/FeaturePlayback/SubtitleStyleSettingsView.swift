#if canImport(SwiftUI)
import CoreModels
import CoreUI
import SwiftUI

public struct SubtitleStyleSettingsView: View {
    @Binding private var style: SubtitleStyle
    private let isLiveTV: Bool
    @State private var controls = PlayerControlsModel()
    @State private var secondaryVisible = false
    @State private var prepared = false
    @State private var previewOptions = SubtitlePreviewOptions()
    #if os(tvOS)
    @Environment(\.dismiss) private var dismiss
    @State private var screen = PlayerControls.SubtitleScreen.style
    #endif

    public init(style: Binding<SubtitleStyle>, isLiveTV: Bool = false) {
        _style = style
        self.isLiveTV = isLiveTV
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            #if os(tvOS)
            SettingsPageHeader(pageTitle)
                .plozzForeground(.primary)
            #endif
            GeometryReader { geometry in
                let context = SubtitleStyleEditingContext(
                    controls: controls, style: $style, secondaryPreview: secondaryPreview
                )
                #if os(tvOS)
                HStack(alignment: .center, spacing: 44) {
                    TelevisionSubtitleStyleColumn(
                        context: context, screen: $screen, style: style,
                        secondaryVisible: secondaryVisible, previewOptions: previewOptions
                    )
                        .frame(width: SubtitleStylePanel.panelWidth)
                    SubtitleStylePreview(
                        style: style, secondaryVisible: secondaryVisible,
                        referenceSize: SubtitleStylePreviewMetrics.televisionCanvas,
                        options: previewOptions
                    )
                    .frame(maxWidth: .infinity)
                    .allowsHitTesting(false)
                }
                #else
                let width = max(geometry.size.width, geometry.size.height)
                let reference = CGSize(width: width, height: width * 9 / 16)
                let layout = geometry.size.width > geometry.size.height
                    ? AnyLayout(HStackLayout(alignment: .top, spacing: 24))
                    : AnyLayout(VStackLayout(alignment: .leading, spacing: 20))
                layout {
                    SubtitleStylePreview(
                        style: style, secondaryVisible: secondaryVisible,
                        referenceSize: reference, options: previewOptions
                    )
                        .frame(maxWidth: .infinity)
                    NavigationStack {
                        MobileSubtitleStyleEditor(viewModel: context)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                #endif
            }
        }
        .padding(.horizontal, pageInset)
        .padding(.vertical, 24)
        .background { SettingsPageBackground() }
        #if os(tvOS)
        .navigationTitle(Text(verbatim: ""))
        .onExitCommand {
            if screen == .style { dismiss() }
            else { screen = screen.parent }
        }
        #else
        .navigationTitle(Text(pageTitle))
        #endif
        .onChange(of: style, initial: true) { previous, value in
            controls.subtitleStyle = value
            controls.subtitlesRenderHDR = true
            previewOptions.styleDidChange(from: previous, to: value)
            if value.secondary == nil { secondaryVisible = false }
        }
        .onAppear {
            guard !prepared else { return }
            prepared = true
            secondaryVisible = style.secondary != nil
        }
    }

    private var pageTitle: LocalizedStringResource {
        isLiveTV ? "Customize Live TV subtitles" : "Customize subtitle style"
    }

    private var pageInset: CGFloat {
        #if os(tvOS)
        48
        #else
        16
        #endif
    }

    private var secondaryPreview: Binding<Bool> {
        Binding(
            get: { secondaryVisible },
            set: {
                if $0, style.secondary == nil {
                    style.secondary = .init()
                    controls.subtitleStyle = style
                }
                secondaryVisible = $0
            }
        )
    }
}

#if os(tvOS)
private struct TelevisionSubtitleStyleColumn: View {
    let context: SubtitleStyleEditingContext
    @Binding var screen: PlayerControls.SubtitleScreen
    let style: SubtitleStyle
    let secondaryVisible: Bool
    let previewOptions: SubtitlePreviewOptions
    @FocusState private var previewFocus: SubtitlePreviewControl?
    @State private var fullscreenPresented = false

    var body: some View {
        VStack(spacing: 20) {
            TelevisionSubtitleStyleEditor(context: context, screen: $screen)
            SubtitlePreviewControls(
                style: style, secondaryVisible: secondaryVisible, options: previewOptions,
                fullscreenPresented: $fullscreenPresented, focus: $previewFocus
            )
        }
    }
}

private struct TelevisionSubtitleStyleEditor: View {
    let context: SubtitleStyleEditingContext
    @Binding var screen: PlayerControls.SubtitleScreen
    @Environment(\.themePalette) private var palette
    @FocusState private var focus: PlayerControls.FocusSlot?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
                if screen != .style {
                    Button {
                        screen = screen.parent
                    } label: {
                        Label("Back", systemImage: "chevron.left")
                    }
                    .labelStyle(.iconOnly)
                    .focused($focus, equals: .subBack)
                }
                Text(title).font(.headline)
                Spacer()
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)
            Divider().padding(.horizontal, 28)
            ScrollView {
                SubtitleStylePanel(
                    screen: screen, model: context.controls, palette: palette,
                    actions: PlayerOptionsActions(setSubtitleStyle: context.applySubtitleStyle),
                    focus: $focus,
                    openScreen: { screen = $0 },
                    secondaryPreview: context.secondaryPreview
                )
            }
            .clipped()
            .padding(.bottom, 16)
        }
        .settingsGroupSurface(cornerRadius: 32)
        .task(id: screen) {
            focus = nil
            await Task.yield()
            let style = context.effectiveStyle
            switch screen {
            case .styleFont:
                focus = .row(style.systemFont == nil && style.fontDescriptor == nil
                    ? SubtitleFontFamily.allCases.firstIndex(of: style.fontFamily) ?? 0
                    : SubtitleFontFamily.allCases.count)
            case .styleSystemFont:
                focus = .row(SubtitleSystemFonts.all.firstIndex {
                    $0.id == style.systemFont
                } ?? 0)
            default: focus = .row(0)
            }
        }
    }

    private var title: LocalizedStringResource {
        switch screen {
        case .styleFont: "Font"
        case .styleSystemFont: "System"
        case .styleOutline: "Shadow & Outline"
        case .styleBackground: "Background"
        case .styleDual: "Dual Subtitles"
        default: "Appearance"
        }
    }
}
#endif
#endif
