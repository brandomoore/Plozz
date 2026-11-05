import XCTest
@testable import CoreModels

final class MediaPersonCreditTests: XCTestCase {
    private var cast: [MediaPerson] {
        (1...40).map { MediaPerson(id: "actor-\($0)", name: "Actor \($0)", role: "Character \($0)", kind: "Actor") }
    }

    func testSevenBilledActorsThenFourCrewThenRemainingActorsAndCrew() {
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
        XCTAssertEqual(Array(credits.prefix(7)).map(\.person), Array(cast.prefix(7)))
        XCTAssertEqual(Array(credits[7..<11]).map(\.person.id), ["director", "writer", "producer", "music"])
        XCTAssertEqual(Array(credits[11..<44]).map(\.person), Array(cast.dropFirst(7)))
        XCTAssertEqual(credits.last?.person.id, "exec")
        XCTAssertEqual(item.cast, cast, "Hero and provider actor-only semantics must not change.")
        XCTAssertEqual(Set(credits.map(\.id)).count, credits.count)
        XCTAssertEqual(credits[7].caption, MediaCrewRole.director.title)
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
        XCTAssertEqual(credits[7].person, cast[20])
        XCTAssertEqual(credits.count, cast.count)
        XCTAssertEqual(credits[8].person, cast[7])
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

    func testMultipleRolesDoNotSpendAdditionalFeaturedCrewSlots() {
        let people = cast + [
            .init(id: "director", name: "Filmmaker", kind: "Director", creditIdentity: "tmdb:person:1"),
            .init(id: "tmdb:person:1", name: "Filmmaker", kind: "Writer"),
            .init(id: "tmdb:person:1", name: "Filmmaker", kind: "Producer"),
            .init(id: "other-writer", name: "Another writer", kind: "Writer"),
            .init(id: "other-producer", name: "Another producer", kind: "Producer"),
            .init(id: "composer", name: "Composer", kind: "Composer")
        ]
        let credits = MediaPersonCredit.ordered(people)
        XCTAssertEqual(credits[7].person.id, "director")
        XCTAssertEqual(credits[7].crewRoles, [.director, .writer, .producer])
        XCTAssertEqual(credits[8].person.id, "composer")
        XCTAssertEqual(credits[9].person, cast[7])
        XCTAssertEqual(Array(credits.suffix(2)).map(\.person.id), ["other-writer", "other-producer"])
        XCTAssertEqual(credits.count, 44)
    }

    func testLongCrewCannotDisplaceTheRestOfTheCast() {
        let directors = (1...30).map { MediaPerson(id: "director-\($0)", name: "Director \($0)", kind: "Director") }
        let writers = (1...20).map { MediaPerson(id: "writer-\($0)", name: "Writer \($0)", kind: "Writer") }
        let credits = MediaPersonCredit.ordered(cast + directors + writers)
        XCTAssertEqual(Array(credits[7..<10]).map(\.person.id), ["director-1", "writer-1", "actor-8"])
        XCTAssertEqual(credits.count, 90)
        XCTAssertEqual(credits.filter(\.isCast).map(\.person), cast)
    }

    func testLaterAliasJoinsEarlierCardsWithoutChangingTheirFirstRoute() {
        let director = MediaPerson(id: "native", name: "Person", kind: "Director")
        let producer = MediaPerson(id: "tmdb:person:1", name: "Person", kind: "Producer")
        let writer = MediaPerson(id: director.id, name: director.name, kind: "Writer",
                                 creditIdentity: producer.id)
        let credits = MediaPersonCredit.ordered([director, producer, writer])
        XCTAssertEqual(credits.count, 1)
        XCTAssertEqual(credits[0].person, director)
        XCTAssertEqual(credits[0].crewRoles, [.director, .writer, .producer])
    }
}
