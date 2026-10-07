import XCTest
@testable import CoreModels

@MainActor
final class ReleaseNotesTests: XCTestCase {
    private func revisedRelease(
        _ build: Int, version: String, marketingVersion: String? = "2026.9.25",
        releasedAt: String = "2026-09-29"
    ) -> ReleaseNotesRelease {
        ReleaseNotesRelease(
            id: String(format: "release/%03d", build), version: version,
            build: ReleaseBuildNumber(integerLiteral: build), releasedAt: releasedAt,
            sections: [ReleaseNotesSection(category: .new, items: ["Release \(build)"])],
            marketingVersion: marketingVersion
        )
    }

    func testIndependentReleasesGroupAndAnnounceWithUnchangedAppleVersion() throws {
        let catalog = try ReleaseNotesCatalog(releases: [
            revisedRelease(46, version: "2026.9.29"),
            revisedRelease(45, version: "2026.9.29")
        ])
        let decoded = try ReleaseNotesCatalog(data: JSONEncoder().encode(catalog))
        XCTAssertEqual(decoded, catalog)
        XCTAssertEqual(catalog.releases.map(\.appleVersion), ["2026.9.25", "2026.9.25"])
        XCTAssertEqual(catalog.allGroups.map(\.version), ["2026.9.29"])
        XCTAssertEqual(
            catalog.allGroups[0].sections[0].items.map(\.text), ["Release 46", "Release 45"]
        )
        let store = TestReleaseNotesStore(lastSeenReleaseID: "release/045")
        let model = ReleaseNotesModel(
            catalog: catalog, currentReleaseID: "release/046", store: store
        )
        model.prepareForStartup()
        XCTAssertEqual(model.pendingVersionGroups.map(\.version), ["2026.9.29"])
        XCTAssertEqual(model.pendingReleases.map(\.build), [46])
        XCTAssertEqual(model.pendingVersionGroups[0].sections[0].items.map(\.text), ["Release 46"])
        model.dismissStartupNotes()
        XCTAssertEqual(store.lastSeenReleaseID, "release/046")
    }

    func testDottedBuildsRoundTripAndAnnounceInNumericOrder() throws {
        let values = ["52", "51.10", "51.2", "51.1", "51"]
        let releases = try values.map { value in
            let build = try XCTUnwrap(ReleaseBuildNumber(value))
            return ReleaseNotesRelease(
                id: build.releaseID, version: "2026.10.7", build: build, releasedAt: "2026-10-07",
                sections: [.init(category: .fixed, items: ["Build \(value)"])],
                marketingVersion: "2026.9.25")
        }
        let catalog = try ReleaseNotesCatalog(releases: releases)
        let data = try JSONEncoder().encode(catalog)
        XCTAssertEqual(try ReleaseNotesCatalog(data: data), catalog)
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let entries = try XCTUnwrap(encoded["releases"] as? [[String: Any]])
        XCTAssertEqual(entries[0]["build"] as? Int, 52)
        XCTAssertEqual(entries[1]["build"] as? String, "51.10")
        XCTAssertEqual(catalog.releases(after: "release/051", through: "release/051.10").map(\.id),
                       ["release/051.10", "release/051.2", "release/051.1"])

        let store = TestReleaseNotesStore(lastSeenReleaseID: "release/051")
        let model = ReleaseNotesModel(catalog: catalog, currentReleaseID: "release/051.1", store: store)
        model.prepareForStartup()
        XCTAssertEqual(model.pendingReleases.map(\.id), ["release/051.1"])
        model.dismissStartupNotes()
        XCTAssertEqual(store.lastSeenReleaseID, "release/051.1")
        let older = ReleaseNotesModel(catalog: catalog, currentReleaseID: "release/051", store: store)
        older.prepareForStartup()
        older.dismissStartupNotes()
        XCTAssertEqual(store.lastSeenReleaseID, "release/051.1")
        XCTAssertThrowsError(try ReleaseNotesCatalog(releases: releases.reversed()))
    }

    func testBuildNumberValidationAndEquivalentVersions() throws {
        for invalid in ["", "0", "-1", "051", "51.01", "51.", ".1", "51..1", "51.1.1.1",
                        "10000", "51.100", "51.1.100", "51.1b1", " 51.1", "51.١"] {
            XCTAssertNil(ReleaseBuildNumber(invalid), invalid)
        }
        let short = try XCTUnwrap(ReleaseBuildNumber("51.1"))
        let full = try XCTUnwrap(ReleaseBuildNumber("51.1.0"))
        XCTAssertEqual(short, full)
        XCTAssertEqual(Set([short, full]).count, 1)
        XCTAssertEqual(short.releaseID, "release/051.1")
        XCTAssertEqual(full.releaseID, "release/051.1.0")
        let releases = [short, full].map { build in
            ReleaseNotesRelease(
                id: build.releaseID, version: "2026.10.7", build: build, releasedAt: "2026-10-07",
                sections: [.init(category: .fixed, items: ["Hotfix"])], marketingVersion: "2026.9.25")
        }
        XCTAssertThrowsError(try ReleaseNotesCatalog(releases: releases)) {
            XCTAssertEqual($0 as? ReleaseNotesCatalogError, .duplicateBuild(full))
        }
        for invalidJSON in ["true", "51.2", "\"0\"", "\"51.100\""] {
            XCTAssertThrowsError(try JSONDecoder().decode(ReleaseBuildNumber.self, from: Data(invalidJSON.utf8)))
        }
    }

    func testReleaseDateAndAppleVersionValidation() {
        for version in ["2026.9.29.1", "2026.09.29", "2026.9.30", "2026.2.31", "0.9.29"] {
            XCTAssertThrowsError(try ReleaseNotesCatalog(releases: [
                revisedRelease(45, version: version)
            ]), version)
        }
        for marketing in ["", "2026.9.29.1"] {
            XCTAssertThrowsError(try ReleaseNotesCatalog(releases: [
                revisedRelease(45, version: "2026.9.29", marketingVersion: marketing)
            ]))
        }
        XCTAssertThrowsError(try ReleaseNotesCatalog(releases: [
            revisedRelease(45, version: "2026.9.29"),
            revisedRelease(45, version: "2026.9.29")
        ]))
        XCTAssertThrowsError(try ReleaseNotesCatalog(releases: [
            revisedRelease(46, version: "2026.9.28", releasedAt: "2026-09-28"),
            revisedRelease(45, version: "2026.9.29")
        ]))
        XCTAssertThrowsError(try ReleaseNotesCatalog(releases: [
            revisedRelease(46, version: "2026.9.29", marketingVersion: "2026.9.24"),
            revisedRelease(45, version: "2026.9.29")
        ]))
    }

    func testPublicDateOrderingAcrossMonthsAndLegacyReleaseDate() throws {
        let catalog = try ReleaseNotesCatalog(releases: [
            revisedRelease(46, version: "2026.10.1", releasedAt: "2026-10-01"),
            revisedRelease(45, version: "2026.9.29"),
            revisedRelease(44, version: "2026.9.25", marketingVersion: nil, releasedAt: "2026-09-27")
        ])
        XCTAssertEqual(catalog.allGroups.map(\.version), ["2026.10.1", "2026.9.29", "2026.9.25"])
    }

    func testCatalogDecodesAndGroupsSameVersionBuilds() throws {
        let catalog = try makeCatalog()

        XCTAssertEqual(catalog.releases.map(\.id), ["release/003", "release/002", "release/001"])
        XCTAssertEqual(catalog.allGroups.map(\.version), ["2026.8.2", "2026.8.1"])
        XCTAssertEqual(
            catalog.allGroups[0].sections,
            [
                ReleaseNotesSection(category: .new, items: ["New three"]),
                ReleaseNotesSection(category: .updated, items: ["Updated three", "Updated two"]),
                ReleaseNotesSection(category: .fixed, items: ["Fixed two"])
            ]
        )
    }

    func testFeaturedContentIsOptionalAndRoundTrips() throws {
        let legacy = try makeCatalog()
        XCTAssertTrue(legacy.releases.allSatisfy { $0.featuredContent == nil })
        let catalog = try featuredCatalog()
        XCTAssertEqual(try ReleaseNotesCatalog(data: JSONEncoder().encode(catalog)), catalog)
        XCTAssertEqual(catalog.release(id: "release/049")?.featuredContent, .discord)
        XCTAssertNil(catalog.release(id: "release/048")?.featuredContent)
    }

    func testUnknownFeaturedContentIsRejected() {
        let data = Data("""
        {"schemaVersion":1,"releases":[{
            "id":"release/049","version":"2026.10.5","build":49,"releasedAt":"2026-10-05",
            "featuredContent":"unsupported",
            "sections":[{"category":"New","items":["Community"]}]
        }]}
        """.utf8)
        XCTAssertThrowsError(try ReleaseNotesCatalog(data: data))
    }

    func testFeaturedContentAppearsOnlyForTheCurrentUnseenRelease() throws {
        for platform in ReleaseNotesPlatform.allCases {
            let store = TestReleaseNotesStore(lastSeenReleaseID: "release/048")
            let model = ReleaseNotesModel(
                catalog: try featuredCatalog(), currentReleaseID: "release/049",
                store: store, platform: platform
            )
            XCTAssertNil(model.pendingFeaturedContent)
            model.prepareForStartup()
            XCTAssertEqual(model.pendingFeaturedContent, .discord)
            model.dismissStartupNotes()
            XCTAssertNil(model.pendingFeaturedContent)

            let reopened = ReleaseNotesModel(
                catalog: try featuredCatalog(), currentReleaseID: "release/049",
                store: store, platform: platform
            )
            reopened.prepareForStartup()
            XCTAssertFalse(reopened.hasPendingStartupNotes)
            XCTAssertNil(reopened.pendingFeaturedContent)
        }
    }

    func testLaterReleaseDoesNotReplayOlderFeaturedContentEvenWhenSkipped() throws {
        for lastSeen in ["release/048", "release/049"] {
            let model = ReleaseNotesModel(
                catalog: try featuredCatalog(), currentReleaseID: "release/050",
                store: TestReleaseNotesStore(lastSeenReleaseID: lastSeen)
            )
            model.prepareForStartup()
            XCTAssertTrue(model.hasPendingStartupNotes)
            XCTAssertNil(model.pendingFeaturedContent)
        }
    }

    func testFeaturedContentRespectsFirstInstallAndStartupPreference() throws {
        for store in [
            TestReleaseNotesStore(),
            TestReleaseNotesStore(showsOnStartup: false, lastSeenReleaseID: "release/048")
        ] {
            let model = ReleaseNotesModel(
                catalog: try featuredCatalog(), currentReleaseID: "release/049", store: store
            )
            model.prepareForStartup()
            XCTAssertFalse(model.hasPendingStartupNotes)
            XCTAssertNil(model.pendingFeaturedContent)
        }
        let model = ReleaseNotesModel(
            catalog: try featuredCatalog(), currentReleaseID: "release/049",
            store: TestReleaseNotesStore(lastSeenReleaseID: "release/048")
        )
        model.prepareForStartup()
        XCTAssertEqual(model.pendingFeaturedContent, .discord)
        model.setShowsOnStartup(false)
        XCTAssertNil(model.pendingFeaturedContent)
    }

    func testFeaturedContentDoesNotPromoteAnUnrelatedPlatformRelease() throws {
        let catalog = try featuredCatalog(platforms: [.tvOS])
        let model = ReleaseNotesModel(
            catalog: catalog, currentReleaseID: "release/049",
            store: TestReleaseNotesStore(lastSeenReleaseID: "release/048"), platform: .iOS
        )
        model.prepareForStartup()
        XCTAssertFalse(model.hasPendingStartupNotes)
        XCTAssertNil(model.pendingFeaturedContent)
    }

    func testLegacyStringItemsAreSharedAcrossPlatforms() throws {
        let catalog = try ReleaseNotesCatalog(data: Data("""
        {
          "schemaVersion": 1,
          "releases": [{
            "id": "release/001",
            "version": "2026.8.1",
            "build": 1,
            "releasedAt": "2026-08-01",
            "sections": [{ "category": "New", "items": ["Shared"] }]
          }]
        }
        """.utf8))

        XCTAssertEqual(
            catalog.versionGroups(platform: .tvOS)[0].sections[0].items,
            [ReleaseNotesItem(text: "Shared")]
        )
        XCTAssertEqual(
            catalog.versionGroups(platform: .iOS)[0].sections[0].items,
            [ReleaseNotesItem(text: "Shared")]
        )
    }

    func testLegacySharedItemEncodesBackToAString() throws {
        let item = ReleaseNotesItem(text: "Shared")

        let encoded = try JSONEncoder().encode(item)

        XCTAssertEqual(String(decoding: encoded, as: UTF8.self), "\"Shared\"")
    }

    func testPlatformItemsFilterAndKeepCategoryOrder() throws {
        let catalog = try platformCatalog()
        let tvGroup = try XCTUnwrap(
            catalog.versionGroups(platform: .tvOS).first {
                $0.version == "2026.8.1"
            }
        )
        let phoneGroup = try XCTUnwrap(
            catalog.versionGroups(platform: .iOS).first {
                $0.version == "2026.8.1"
            }
        )

        XCTAssertEqual(
            tvGroup.sections,
            [
                ReleaseNotesSection(
                    category: .new,
                    items: [
                        ReleaseNotesItem(text: "Shared"),
                        ReleaseNotesItem(text: "TV only", platforms: [.tvOS])
                    ]
                )
            ]
        )
        XCTAssertEqual(
            phoneGroup.sections,
            [
                ReleaseNotesSection(
                    category: .new,
                    items: [
                        ReleaseNotesItem(text: "Shared"),
                        ReleaseNotesItem(text: "Phone only", platforms: [.iOS])
                    ]
                ),
                ReleaseNotesSection(
                    category: .fixed,
                    items: [
                        ReleaseNotesItem(text: "Phone fix", platforms: [.iOS])
                    ]
                )
            ]
        )
    }

    func testFirstReleasedBuildEstablishesBaselineWithoutPresenting() throws {
        let store = TestReleaseNotesStore()
        let model = ReleaseNotesModel(
            catalog: try makeCatalog(),
            currentReleaseID: "release/002",
            store: store
        )

        model.prepareForStartup()

        XCTAssertFalse(model.hasPendingStartupNotes)
        XCTAssertEqual(store.lastSeenReleaseID, "release/002")
    }

    func testUpdatePresentsEveryUnseenReleaseNewestFirst() throws {
        let store = TestReleaseNotesStore(lastSeenReleaseID: "release/001")
        let model = ReleaseNotesModel(
            catalog: try makeCatalog(),
            currentReleaseID: "release/003",
            store: store
        )

        model.prepareForStartup()

        XCTAssertEqual(model.pendingReleases.map(\.id), ["release/003", "release/002"])
        XCTAssertEqual(model.pendingVersionGroups.map(\.version), ["2026.8.2"])
        XCTAssertEqual(store.lastSeenReleaseID, "release/001")

        model.dismissStartupNotes()
        XCTAssertFalse(model.hasPendingStartupNotes)
        XCTAssertEqual(store.lastSeenReleaseID, "release/003")
    }

    func testDisabledAnnouncementsAdvanceSeenReleaseWithoutPresenting() throws {
        let store = TestReleaseNotesStore(
            showsOnStartup: false,
            lastSeenReleaseID: "release/001"
        )
        let model = ReleaseNotesModel(
            catalog: try makeCatalog(),
            currentReleaseID: "release/002",
            store: store
        )

        model.prepareForStartup()

        XCTAssertFalse(model.hasPendingStartupNotes)
        XCTAssertEqual(store.lastSeenReleaseID, "release/002")
    }

    func testReenablingDoesNotPresentBacklog() throws {
        let store = TestReleaseNotesStore(lastSeenReleaseID: "release/001")
        let model = ReleaseNotesModel(
            catalog: try makeCatalog(),
            currentReleaseID: "release/002",
            store: store
        )

        model.setShowsOnStartup(false)
        XCTAssertEqual(store.lastSeenReleaseID, "release/002")

        model.setShowsOnStartup(true)
        model.prepareForStartup()

        XCTAssertTrue(model.showsOnStartup)
        XCTAssertFalse(model.hasPendingStartupNotes)
    }

    func testDowngradeDoesNotMoveSeenReleaseBackward() throws {
        let store = TestReleaseNotesStore(lastSeenReleaseID: "release/003")
        let model = ReleaseNotesModel(
            catalog: try makeCatalog(),
            currentReleaseID: "release/002",
            store: store
        )

        model.prepareForStartup()
        model.dismissStartupNotes()

        XCTAssertEqual(store.lastSeenReleaseID, "release/003")
    }

    func testMissingLastSeenReleaseReestablishesBaseline() throws {
        let store = TestReleaseNotesStore(lastSeenReleaseID: "release/999")
        let model = ReleaseNotesModel(
            catalog: try makeCatalog(),
            currentReleaseID: "release/003",
            store: store
        )

        model.prepareForStartup()

        XCTAssertFalse(model.hasPendingStartupNotes)
        XCTAssertEqual(store.lastSeenReleaseID, "release/003")
    }

    func testPlatformWithNoRelevantNotesAdvancesWithoutPresenting() throws {
        let store = TestReleaseNotesStore(lastSeenReleaseID: "release/001")
        let model = ReleaseNotesModel(
            catalog: try platformCatalog(),
            currentReleaseID: "release/002",
            store: store,
            platform: .iOS
        )

        model.prepareForStartup()

        XCTAssertFalse(model.hasPendingStartupNotes)
        XCTAssertEqual(store.lastSeenReleaseID, "release/002")
    }

    func testSkippedUpdatePresentsOnlyRelevantPlatformReleases() throws {
        let store = TestReleaseNotesStore(lastSeenReleaseID: "release/001")
        let model = ReleaseNotesModel(
            catalog: try platformCatalog(),
            currentReleaseID: "release/003",
            store: store,
            platform: .tvOS
        )

        model.prepareForStartup()

        XCTAssertEqual(model.pendingReleases.map(\.id), ["release/002"])
        XCTAssertEqual(
            model.pendingVersionGroups[0].sections[0].items.map(\.text),
            ["TV update"]
        )
    }

    func testBundledCatalogPassesRuntimeValidation() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let catalogURL = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("App/Resources/ReleaseNotes.json")

        let catalog = try ReleaseNotesCatalog(data: Data(contentsOf: catalogURL))
        XCTAssertEqual(catalog.release(id: "release/049")?.featuredContent, .discord)
        XCTAssertTrue(catalog.releases.filter { $0.build < 49 }.allSatisfy { $0.featuredContent == nil })
    }

    func testCatalogRejectsDuplicateBuild() {
        let duplicateBuild = """
        {
          "schemaVersion": 1,
          "releases": [
            {
              "id": "release/002",
              "version": "2026.8.2",
              "build": 2,
              "releasedAt": "2026-08-02",
              "sections": [{ "category": "New", "items": ["One"] }]
            },
            {
              "id": "release/003",
              "version": "2026.8.1",
              "build": 2,
              "releasedAt": "2026-08-01",
              "sections": [{ "category": "Fixed", "items": ["Two"] }]
            }
          ]
        }
        """

        XCTAssertThrowsError(try ReleaseNotesCatalog(data: Data(duplicateBuild.utf8))) { error in
            XCTAssertEqual(error as? ReleaseNotesCatalogError, .duplicateBuild(2))
        }
    }

    func testCatalogRejectsEmptyPlatformTarget() {
        let emptyPlatforms = """
        {
          "schemaVersion": 1,
          "releases": [{
            "id": "release/001",
            "version": "2026.8.1",
            "build": 1,
            "releasedAt": "2026-08-01",
            "sections": [{
              "category": "New",
              "items": [{ "text": "Nothing", "platforms": [] }]
            }]
          }]
        }
        """

        XCTAssertThrowsError(
            try ReleaseNotesCatalog(data: Data(emptyPlatforms.utf8))
        ) { error in
            XCTAssertEqual(
                error as? ReleaseNotesCatalogError,
                .emptyPlatforms("release/001", .new)
            )
        }
    }

    private func featuredCatalog(
        platforms: [ReleaseNotesPlatform]? = nil
    ) throws -> ReleaseNotesCatalog {
        try ReleaseNotesCatalog(releases: [
            revisedRelease(50, version: "2026.10.5", releasedAt: "2026-10-05"),
            ReleaseNotesRelease(
                id: "release/049", version: "2026.10.5", build: 49, releasedAt: "2026-10-05",
                sections: [ReleaseNotesSection(
                    category: .new, items: [ReleaseNotesItem(text: "Community", platforms: platforms)]
                )],
                marketingVersion: "2026.9.25", featuredContent: .discord
            ),
            revisedRelease(48, version: "2026.10.4", releasedAt: "2026-10-04")
        ])
    }

    private func makeCatalog() throws -> ReleaseNotesCatalog {
        try ReleaseNotesCatalog(
            releases: [
                ReleaseNotesRelease(
                    id: "release/003",
                    version: "2026.8.2",
                    build: 3,
                    releasedAt: "2026-08-02",
                    sections: [
                        ReleaseNotesSection(category: .new, items: ["New three"]),
                        ReleaseNotesSection(category: .updated, items: ["Updated three"])
                    ]
                ),
                ReleaseNotesRelease(
                    id: "release/002",
                    version: "2026.8.2",
                    build: 2,
                    releasedAt: "2026-08-02",
                    sections: [
                        ReleaseNotesSection(category: .updated, items: ["Updated two"]),
                        ReleaseNotesSection(category: .fixed, items: ["Fixed two"])
                    ]
                ),
                ReleaseNotesRelease(
                    id: "release/001",
                    version: "2026.8.1",
                    build: 1,
                    releasedAt: "2026-08-01",
                    sections: [
                        ReleaseNotesSection(category: .new, items: ["New one"])
                    ]
                )
            ]
        )
    }

    private func platformCatalog() throws -> ReleaseNotesCatalog {
        try ReleaseNotesCatalog(
            releases: [
                ReleaseNotesRelease(
                    id: "release/003",
                    version: "2026.8.3",
                    build: 3,
                    releasedAt: "2026-08-03",
                    sections: [
                        ReleaseNotesSection(
                            category: .updated,
                            items: [
                                ReleaseNotesItem(
                                    text: "Phone update",
                                    platforms: [.iOS]
                                )
                            ]
                        )
                    ]
                ),
                ReleaseNotesRelease(
                    id: "release/002",
                    version: "2026.8.2",
                    build: 2,
                    releasedAt: "2026-08-02",
                    sections: [
                        ReleaseNotesSection(
                            category: .updated,
                            items: [
                                ReleaseNotesItem(
                                    text: "TV update",
                                    platforms: [.tvOS]
                                )
                            ]
                        )
                    ]
                ),
                ReleaseNotesRelease(
                    id: "release/001",
                    version: "2026.8.1",
                    build: 1,
                    releasedAt: "2026-08-01",
                    sections: [
                        ReleaseNotesSection(
                            category: .new,
                            items: [
                                ReleaseNotesItem(text: "Shared"),
                                ReleaseNotesItem(
                                    text: "TV only",
                                    platforms: [.tvOS]
                                ),
                                ReleaseNotesItem(
                                    text: "Phone only",
                                    platforms: [.iOS]
                                )
                            ]
                        ),
                        ReleaseNotesSection(
                            category: .fixed,
                            items: [
                                ReleaseNotesItem(
                                    text: "Phone fix",
                                    platforms: [.iOS]
                                )
                            ]
                        )
                    ]
                )
            ]
        )
    }
}

private extension ReleaseNotesCatalog {
    var allGroups: [ReleaseNotesVersionGroup] {
        versionGroups()
    }
}

private final class TestReleaseNotesStore: ReleaseNotesStoring, @unchecked Sendable {
    var showsOnStartup: Bool
    var lastSeenReleaseID: String?

    init(showsOnStartup: Bool = true, lastSeenReleaseID: String? = nil) {
        self.showsOnStartup = showsOnStartup
        self.lastSeenReleaseID = lastSeenReleaseID
    }

    func loadShowsOnStartup() -> Bool {
        showsOnStartup
    }

    func saveShowsOnStartup(_ showsOnStartup: Bool) {
        self.showsOnStartup = showsOnStartup
    }

    func loadLastSeenReleaseID() -> String? {
        lastSeenReleaseID
    }

    func saveLastSeenReleaseID(_ releaseID: String) {
        lastSeenReleaseID = releaseID
    }
}
