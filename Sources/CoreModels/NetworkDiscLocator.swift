import Foundation

/// One decrypted disc folder whose files retain ordinary transport identity checks.
public struct NetworkDiscLocator: Hashable, Sendable {
    public struct File: Hashable, Sendable {
        public let path: String
        public let locator: NetworkFileLocator

        public init(path: String, locator: NetworkFileLocator) throws {
            self.path = try MediaPathPolicy.normalizedRelative(path)
            self.locator = locator
        }
    }

    public let anchor: NetworkFileLocator
    public let files: [File]

    public init(anchor: NetworkFileLocator, files: [File]) throws {
        guard !files.isEmpty, files.count <= 4_096,
              Set(files.map { $0.path.lowercased() }).count == files.count,
              let index = files.first(where: { $0.path.lowercased() == "bdmv/index.bdmv" }),
              index.locator == anchor else {
            throw MediaSourceModelError.invalidRelativePath
        }
        let parent = (anchor.relativePath as NSString).deletingLastPathComponent
        let root = parent.isEmpty ? "" : parent + "/"
        let discParent = (parent as NSString).deletingLastPathComponent
        let discRoot = discParent.isEmpty ? "" : discParent + "/"
        var totalSize: Int64 = 0
        for file in files {
            let components = file.path.split(separator: "/")
            let sum = totalSize.addingReportingOverflow(file.locator.representation.size)
            let isDiscID = ["certificate/id.bdmv", "certificate/backup/id.bdmv"].contains(file.path.lowercased())
            let expectedPath = isDiscID ? discRoot + file.path
                : root + components.dropFirst().joined(separator: "/")
            guard (file.path.lowercased().hasPrefix("bdmv/") || (isDiscID && !parent.isEmpty)),
                  file.locator.relativePath == expectedPath,
                  file.locator.accountID == anchor.accountID,
                  file.locator.sourceID == anchor.sourceID,
                  file.locator.credentialRevision == anchor.credentialRevision,
                  !sum.overflow else {
                throw MediaSourceModelError.invalidRelativePath
            }
            totalSize = sum.partialValue
        }
        self.anchor = anchor
        self.files = files
    }
}
