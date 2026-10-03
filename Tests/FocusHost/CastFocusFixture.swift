import CoreModels
import CoreUI
import SwiftUI
import UIKit
@testable import FeaturePlayback

struct PlayerCastFocusFixture: View {
    @State private var model = Self.makeModel()
    @State private var person: MediaPerson?
    @State private var closeRequest = 0
    @State private var realizedFaces = 0
    @FocusState private var focus: PlayerControls.FocusSlot?

    var body: some View {
        VStack(alignment: .leading, spacing: 32) {
            Button("Browse cast") {}
                .focused($focus, equals: .button(.cast))
                .accessibilityIdentifier("player-cast-browse")
            CastPanelView(
                model: model, focus: $focus, detailPerson: $person,
                closeRequest: $closeRequest, isCardOpen: true, revealClock: .smooth(duration: 0.5)
            )
            .frame(width: 1400)
            .onPreferenceChange(CastCardFrameKey.self) { realizedFaces = $0.count }
            Text(verbatim: String(realizedFaces))
                .accessibilityIdentifier("player-cast-realized")
            Text(verbatim: person?.id ?? "none")
                .accessibilityIdentifier("player-cast-opened")
            Text(verbatim: String(describing: focus))
                .accessibilityIdentifier("player-cast-focus")
        }
        .frame(width: 1400, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.colorScheme, .dark)
        .environment(\.layoutDirection, ProcessInfo.processInfo.arguments.contains("--rtl") ? .rightToLeft : .leftToRight)
        .environment(\.plozzReducePanelGlass, ProcessInfo.processInfo.arguments.contains("--flat"))
        .background(.black)
        .onAppear { focus = .button(.cast) }
        .onExitCommand { closeRequest += 1 }
    }

    private static func makeModel() -> PlayerControlsModel {
        let model = PlayerControlsModel()
        model.infoCard.cast = (0..<20).map {
            MediaPerson(
                id: String($0), name: "Actor \($0)", role: "Character \($0)",
                biography: "A local biography used to verify the actual player cast transition."
            )
        }
        return model
    }
}

struct CastFocusFixture: View {
    @State private var people: [MediaPerson] = []
    @State private var opened = ""

    var body: some View {
        VStack(spacing: 40) {
            if !people.isEmpty {
                Text("Cast fixture ready").accessibilityIdentifier("cast-fixture-ready")
                CastRowView(people: people, leadingInset: 80)
                    .mediaPersonNavigator { opened = $0.name }
                Text(opened).accessibilityIdentifier("cast-opened")
            }
        }
        .environment(\.plozzCardFocusStyle, .system)
        .environment(\.themePalette, .dark)
        .environment(\.colorScheme, .dark)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
        .task {
            guard people.isEmpty else { return }
            people = [
                MediaPerson(id: "first", name: "Casey Example", role: "Lead character", imageURL: seed(name: "red", color: .red)),
                MediaPerson(id: "second", name: "Morgan Example", role: "Second character", imageURL: seed(name: "blue", color: .blue))
            ]
        }
    }

    private func seed(name: String, color: UIColor) -> URL {
        let url = URL(string: "https://cast-focus.example.test/\(name).png")!
        let image = UIGraphicsImageRenderer(size: CGSize(width: 180, height: 320)).image {
            color.setFill()
            $0.fill(CGRect(x: 0, y: 0, width: 180, height: 320))
        }
        guard let bytes = image.pngData(), let cache = ArtworkSession.shared.configuration.urlCache else {
            preconditionFailure("The cast fixture requires a local artwork cache.")
        }
        let target = ArtworkImageVariant.personHeadshot.requestURL(for: url)
        let response = HTTPURLResponse(
            url: target, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "image/png", "Cache-Control": "max-age=86400"]
        )!
        cache.storeCachedResponse(CachedURLResponse(response: response, data: bytes), for: URLRequest(url: target))
        return url
    }
}
