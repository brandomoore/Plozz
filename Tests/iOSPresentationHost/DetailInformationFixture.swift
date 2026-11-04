import CoreModels
import CoreUI
import SwiftUI

struct DetailInformationFixture: View {
    @State private var selectedPerson = ""

    static let longTitle = String(repeating: "A very long original title ", count: 40)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    private var singleValue: Bool {
        ProcessInfo.processInfo.arguments.contains("--detail-single-long-value")
    }

    private var cast: [MediaPerson] {
        (1...40).map { MediaPerson(id: "actor-\($0)", name: "Person \($0)", kind: "Actor") }
    }

    private var item: MediaItem {
        if singleValue {
            return MediaItem(id: "long", title: "Title", originalTitle: Self.longTitle, kind: .movie)
        }
        return MediaItem(
            id: "series", title: "Series", kind: .series,
            people: (1...60).map { MediaPerson(id: "director-\($0)", name: "Director \($0)", kind: "Director") }
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if !singleValue {
                    Text(selectedPerson)
                        .accessibilityIdentifier("selected-cast-person")
                    CastRowView(people: cast, leadingInset: 24)
                        .environment(\.mediaPersonNavigator, { person in selectedPerson = person.name })
                }
                DetailInformationSections(item: item, horizontalInset: 24)
            }
        }
        .environment(\.themePalette, .dark)
        .preferredColorScheme(.dark)
    }
}
