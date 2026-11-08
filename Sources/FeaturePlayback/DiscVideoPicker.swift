#if canImport(UIKit) && canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI

struct DiscVideoPicker: View {
    let model: PlayerViewModel
    let close: () -> Void
    @State private var videos: [DiscVideo]?
    @State private var failure: String?
    @State private var reloadID = UUID()
    @FocusState private var focusedPlaylist: Int?

    var body: some View {
        DiscPlaybackDialog(title: "Disc videos", close: close) {
            if let failure {
                Text(verbatim: failure)
                    .foregroundStyle(.secondary)
                Button("Retry") { reloadID = UUID() }
                    .discPlaybackActionButton()
            } else if let videos {
                ForEach(videos) { video in
                    Button {
                        do {
                            try model.playDiscVideo(video)
                            close()
                        } catch {
                            failure = error.localizedDescription
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Playlist \(String(format: "%05d", video.playlist))")
                            Text("\(Duration.seconds(video.duration).formatted(.time(pattern: .hourMinuteSecond))) \u{00B7} \(video.chapterCount) chapters")
                                .font(.caption)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                    }
                    .discPlaybackActionButton()
                    .buttonBorderShape(.roundedRectangle(radius: 16))
                    .focused($focusedPlaylist, equals: video.playlist)
                }
            } else {
                ProgressView("Reading disc")
            }
        }
        #if os(tvOS)
        .onChange(of: videos?.first?.playlist) { _, playlist in
            focusedPlaylist = playlist
        }
        #endif
        .task(id: reloadID) {
            videos = nil
            failure = nil
            do {
                videos = try await model.loadDiscVideos()
            } catch is CancellationError {
                return
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}

struct DiscPlaybackDialog<Content: View>: View {
    let title: LocalizedStringResource
    let close: () -> Void
    @ViewBuilder let content: () -> Content
    @Environment(\.themePalette) private var palette

    var body: some View {
        #if os(tvOS)
        VStack(alignment: .leading, spacing: 24) {
            Text(title)
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)
            ViewThatFits(in: .vertical) {
                VStack(alignment: .leading, spacing: 16, content: content)
                    .padding(16)
                    .fixedSize(horizontal: false, vertical: true)
                ScrollView {
                    VStack(alignment: .leading, spacing: 16, content: content)
                        .padding(16)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            Button("Close", action: close)
                .discPlaybackActionButton()
        }
        .padding(32)
        .onExitCommand(perform: close)
        #else
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16, content: content)
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle(Text(title))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark", action: close)
                        .labelStyle(.iconOnly)
                }
            }
        }
        .tint(palette.primaryText)
        #endif
    }
}

extension View {
    @ViewBuilder
    func discPlaybackActionButton() -> some View {
        #if os(tvOS)
        self.buttonStyle(.bordered)
        #else
        self.plozzActionButton(role: .secondary)
        #endif
    }

    /// Keep the TV playback owner mounted, as with the shared version-choice dialog.
    func discPlaybackSheet<Content: View>(
        isPresented: Binding<Bool>, onDismiss: @escaping () -> Void = {},
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        #if os(tvOS)
        self
            .disabled(isPresented.wrappedValue)
            .accessibilityHidden(isPresented.wrappedValue)
            .overlay {
                if isPresented.wrappedValue {
                    GeometryReader { geometry in
                        ZStack {
                            PlozzDialogBackdrop()
                            content()
                                .frame(width: min(1_100, max(0, geometry.size.width - 64)))
                                .plozzSurface(.overlay, cornerRadius: 32)
                                .accessibilityElement(children: .contain)
                                .frame(maxHeight: min(860, max(0, geometry.size.height - 64)))
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            .onChange(of: isPresented.wrappedValue) { old, new in
                if old && !new { onDismiss() }
            }
        #else
        self.plozzSheet(isPresented: isPresented, onDismiss: onDismiss, content: content)
        #endif
    }
}
#endif
