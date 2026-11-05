import XCTest
@testable import CoreModels

final class MediaPersonCreditTests: XCTestCase {
    private var cast: [MediaPerson] {
        (1...40).map { MediaPerson(id: "actor-\($0)", name: "Actor \($0)", role: "Character \($0)", kind: "Actor") }
    }

    func testSixBilledActorsThenKeyCrewThenEveryRemainingActor() {
        let people = cast + [
            .init(id: "music", name: "Composer", kind: "Original Music Composer"),
            .init(id: "writer", name: "Writer", kind: "Screenplay"),
            .init(id: "director", name: "Director", kind: "Director"),
            .init(id: "producer", name: "Producer", kind: "Producer"),
            .init(id: "exec", name: "Executive", kind: "ExecutiveProducer"),
            .init(id: "art", name: "Art", kind: "Art Direction")
        ]
        let item = MediaItem(id: "movie", title: "Movie", kind: .movie, people: people)
        let credits = item.detailCredits
        XCTAssertEqual(Array(credits.prefix(6)).map(\.person), Array(cast.prefix(6)))
        XCTAssertEqual(Array(credits[6..<11]).map(\.person.id), ["director", "writer", "producer", "exec", "music"])
        XCTAssertEqual(Array(credits.dropFirst(11)).map(\.person), Array(cast.dropFirst(6)))
        XCTAssertEqual(item.cast, cast, "Hero and provider actor-only semantics must not change.")
        XCTAssertEqual(Set(credits.map(\.id)).count, credits.count)
        XCTAssertEqual(credits[6].caption, MediaCrewRole.director.title)
    }

    func testSparseAndCrewOnlyTitlesDoNotReserveActorSlots() {
        let director = MediaPerson(id: "director", name: "Director", kind: "Director")
        XCTAssertEqual(MediaPersonCredit.ordered(Array(cast.prefix(2)) + [director]).map(\.person),
                       Array(cast.prefix(2)) + [director])
        XCTAssertEqual(MediaPersonCredit.ordered([director]).map(\.person), [director])
        XCTAssertEqual(MediaPersonCredit.ordered(cast).map(\.person), cast)
        XCTAssertTrue(MediaPersonCredit.ordered([]).isEmpty)
    }

    func testActorDirectorWriterHasOneCardAndOriginalRoute() {
        var director = cast[0]
        director.kind = "Director"
        var writer = director
        writer.kind = "Writer"
        let credits = MediaPersonCredit.ordered(cast + [director, writer, director])
        XCTAssertEqual(credits.count, cast.count)
        XCTAssertEqual(credits[0].person, cast[0])
        XCTAssertEqual(credits[0].characters, ["Character 1"])
        XCTAssertEqual(credits[0].crewRoles, [.director, .writer])
        XCTAssertEqual(credits[0].caption,
                       "Character 1\n\(MediaCrewRole.director.title), \(MediaCrewRole.writer.title)")
    }

    func testLaterActorWhoDirectsIsPromotedWithoutLosingTheirRoute() {
        var director = cast[20]
        director.kind = "Director"
        let credits = MediaPersonCredit.ordered(cast + [director])
        XCTAssertEqual(credits[6].person, cast[20])
        XCTAssertEqual(credits.count, cast.count)
        XCTAssertEqual(credits[7].person, cast[6])
        XCTAssertEqual(credits.last?.person, cast.last)
    }

    func testPlexRoleSpecificIDsShareCardOnlyWithMatchingExternalIdentity() {
        let actor = MediaPerson(id: "actor:123", name: "Same Name", role: "Character", kind: "Actor",
                                externalID: "plex://person/123")
        let director = MediaPerson(id: "director:123", name: "Same Name", kind: "Director",
                                   externalID: "plex://person/123")
        let unrelated = MediaPerson(id: "writer:456", name: "Same Name", kind: "Writer")
        let credits = MediaPersonCredit.ordered([actor, director, unrelated])
        XCTAssertEqual(credits.count, 2)
        XCTAssertEqual(credits[0].person.id, actor.id)
        XCTAssertEqual(credits[0].person.externalID, actor.externalID)
        XCTAssertEqual(credits[0].crewRoles, [.director])
        XCTAssertEqual(credits[1].person, unrelated, "A shared name is not proof of identity.")
    }

    func testSamePriorityCrewAndUnknownBillingPreserveSourceOrder() {
        let people: [MediaPerson] = [
            .init(id: "one", name: "First", kind: "Director"),
            .init(id: "two", name: "Second", kind: "Director"),
            .init(id: "guest", name: "Guest", kind: "GuestStar"),
            .init(id: "implicit", name: "Actor")
        ]
        XCTAssertEqual(MediaPersonCredit.ordered(people).map(\.person.id), ["guest", "implicit", "one", "two"])
    }

    func testMatchingPersonIDMergesWhenOnlyOneCreditHasExternalIdentity() {
        let actor = MediaPerson(id: "123", name: "Person", kind: "Actor")
        let director = MediaPerson(id: "123", name: "Person", kind: "Director",
                                   externalID: "external:123")
        let writer = MediaPerson(id: "writer:123", name: "Person", kind: "Writer",
                                 externalID: "external:123")
        let credits = MediaPersonCredit.ordered([actor, director, writer])
        XCTAssertEqual(credits.count, 1)
        XCTAssertEqual(credits[0].person, actor)
        XCTAssertEqual(credits[0].crewRoles, [.director, .writer])
    }
}
