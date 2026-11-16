import CoreModels
import MetadataKit
import XCTest
@testable import FeatureHomeCore

@MainActor
final class PersonBiographyLanguageTests: XCTestCase {
    func testLanguageRefreshDoesNotReloadCreditsOrRetainPreviousProse() async {
        let provider = BiographyFixture()
        let model = makeModel(provider)
        await model.updateMetadataLanguage("de")
        await model.load()
        XCTAssertEqual(model.biography, "Biography de")
        XCTAssertTrue(model.creditsAreFinal)
        await model.updateMetadataLanguage("ja")
        XCTAssertEqual(model.biography, "Biography ja")
        XCTAssertTrue(model.creditsAreFinal)
    }

    func testLatePreviousLanguageCannotReplaceNewSelection() async {
        let provider = BiographyFixture()
        let model = makeModel(provider)
        await model.load()
        let french = Task { await model.updateMetadataLanguage("fr") }
        await provider.waitForFrench()
        XCTAssertNil(model.biography)
        await model.updateMetadataLanguage("de")
        XCTAssertEqual(model.biography, "Biography de")
        await provider.finishFrench()
        await french.value
        XCTAssertEqual(model.biography, "Biography de")
    }

    private func makeModel(_ provider: BiographyFixture) -> PersonDetailViewModel {
        PersonDetailViewModel(
            person: MediaPerson(id: "person", name: "Person", kind: "Actor"),
            provider: nil, biographyProviders: [provider]
        )
    }
}

private actor BiographyFixture: PersonBiographyProvider {
    nonisolated let id: MetadataSource = .wikipedia
    private var pendingFrench: CheckedContinuation<String?, Never>?
    private var startedFrench: CheckedContinuation<Void, Never>?

    func biography(for name: String, role: String?) async -> String? { "Biography en" }

    func biography(for name: String, role: String?, language: String) async -> String? {
        guard language == "fr" else { return "Biography \(language)" }
        return await withCheckedContinuation { continuation in
            pendingFrench = continuation
            startedFrench?.resume()
            startedFrench = nil
        }
    }

    func waitForFrench() async {
        if pendingFrench != nil { return }
        await withCheckedContinuation { startedFrench = $0 }
    }

    func finishFrench() {
        pendingFrench?.resume(returning: "Biography fr")
        pendingFrench = nil
    }
}
