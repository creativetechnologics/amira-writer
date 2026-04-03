import XCTest
@testable import ProjectKit

final class ProjectServiceConfigurationTests: XCTestCase {
    func testNormalizedAllowedProjectRootsKeepsRequiredManagedRootEvenWhenMissing() throws {
        let fileManager = FileManager.default
        let tempRoot = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let existingRoot = tempRoot.appendingPathComponent("Existing", isDirectory: true)
        let missingRoot = tempRoot.appendingPathComponent("Missing", isDirectory: true)
        let requiredMissingRoot = tempRoot.appendingPathComponent("ManagedProjects", isDirectory: true)

        try fileManager.createDirectory(at: existingRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempRoot) }

        let roots = ProjectServiceConfiguration.normalizedAllowedProjectRoots(
            candidates: [existingRoot, missingRoot],
            requiredRoots: [requiredMissingRoot],
            fileManager: fileManager
        )

        XCTAssertEqual(roots, [
            existingRoot.resolvingSymlinksInPath().standardizedFileURL,
            requiredMissingRoot.resolvingSymlinksInPath().standardizedFileURL,
        ])
    }
}
