#if canImport(UIKit) && canImport(SwiftUI)
import SwiftUI
import CoreModels

struct DiscVideoPicker: View {
    let model: PlayerViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var videos: [DiscVideo]?
    @State private var failure: String?
    @State private var reloadID = UUID()

    var body: some View {
        NavigationStack {
            List {
                if let failure {
                    Text(verbatim: failure)
                    Button("Retry") { reloadID = UUID() }
                } else if let videos {
                    Section {
                        ForEach(videos) { video in
                            Button {
                                do {
                                    try model.playDiscVideo(video)
                                    dismiss()
                                } catch {
                                    failure = error.localizedDescription
                                }
                            } label: {
                                VStack(alignment: .leading) {
                                    Text("Playlist \(String(format: "%05d", video.playlist))")
                                    HStack {
                                        Text(Duration.seconds(video.duration).formatted(.time(pattern: .hourMinuteSecond)))
                                        Text("\(video.chapterCount) chapters")
                                    }
                                    .font(.caption)
                                }
                            }
                        }
                    } footer: {
                        Text("These videos may include extras or alternate versions. Playing one does not update watched or resume progress.")
                    }
                } else {
                    ProgressView("Reading disc")
                }
            }
            .navigationTitle("Disc videos")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
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
        #if os(tvOS)
        .onExitCommand { dismiss() }
        #endif
    }
}
#endif
