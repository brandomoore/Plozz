import CoreModels
import Foundation
import Observation

@MainActor
@Observable
final class LibraryQueryPresentation {
    var filters: LibraryFilters = .all
    var facets = LibraryQueryFacets()
    var facetsLoading = false
    var facetsError: AppError?
    var progress: Double?
    var message: LocalizedStringResource?
    var capabilitiesRevision = 0
}
