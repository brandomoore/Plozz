import CoreModels
import CoreUI
import SwiftUI
import UIKit

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
