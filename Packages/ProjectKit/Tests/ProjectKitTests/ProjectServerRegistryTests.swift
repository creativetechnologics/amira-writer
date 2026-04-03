import Foundation
import XCTest
@testable import ProjectKit

final class ProjectServerRegistryTests: XCTestCase {
    func testRegistryCopiesProjectIntoManagedProjectsFolderAndResolvesAliasSignature() throws {
        let sandboxRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProjectServerRegistryTests-\(UUID().uuidString)", isDirectory: true)
        let sourceProject = sandboxRoot
            .appendingPathComponent("Programming", isDirectory: true)
            .appendingPathComponent("Amira - A Modern Opera", isDirectory: true)
            .appendingPathComponent("Amira.owp", isDirectory: true)
        let songURL = sourceProject.appendingPathComponent("Songs/01 Opening.ows")

        try FileManager.default.createDirectory(at: songURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{\"title\":\"Opening\"}".utf8).write(to: songURL, options: .atomic)

        let registryRoot = sandboxRoot.appendingPathComponent("Documents/Project Server", isDirectory: true)
        let registry = ProjectServerRegistry(rootURL: registryRoot)
        try registry.ensureStorageDirectories()

        let registration = try registry.addProject(from: sourceProject)

        XCTAssertEqual(registration.displayName, "Amira")
        XCTAssertTrue(FileManager.default.fileExists(atPath: registration.managedProjectURL.path))
        XCTAssertTrue(registration.managedProjectURL.path.hasPrefix(registry.projectsRootURL.path))

        let resolved = try registry.managedProjectURL(forClientProjectPath: "/Volumes/Programming/Amira - A Modern Opera/Amira.owp")
        XCTAssertEqual(resolved?.standardizedFileURL.path, registration.managedProjectURL.standardizedFileURL.path)

        let copiedSong = registration.managedProjectURL.appendingPathComponent("Songs/01 Opening.ows")
        XCTAssertEqual(try Data(contentsOf: copiedSong), Data("{\"title\":\"Opening\"}".utf8))
    }

    func testRemoveProjectLeavesManagedCopyInPlaceByDefault() throws {
        let sandboxRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProjectServerRegistryTests-\(UUID().uuidString)", isDirectory: true)
        let sourceProject = sandboxRoot.appendingPathComponent("Programming/Test/Test.owp", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceProject, withIntermediateDirectories: true)

        let registryRoot = sandboxRoot.appendingPathComponent("Documents/Project Server", isDirectory: true)
        let registry = ProjectServerRegistry(rootURL: registryRoot)
        try registry.ensureStorageDirectories()

        let registration = try registry.addProject(from: sourceProject, displayName: "Test")
        try registry.removeProject(id: registration.id)

        XCTAssertTrue(FileManager.default.fileExists(atPath: registration.managedProjectURL.path))
        XCTAssertTrue(try registry.listProjects().isEmpty)
    }

    func testCreateAndRenameProjectKeepsManagedProjectOnServer() throws {
        let sandboxRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProjectServerRegistryTests-\(UUID().uuidString)", isDirectory: true)
        let registryRoot = sandboxRoot.appendingPathComponent("Documents/Project Server", isDirectory: true)
        let registry = ProjectServerRegistry(rootURL: registryRoot)
        try registry.ensureStorageDirectories()

        let created = try registry.createProject(named: "Atlas")
        XCTAssertEqual(created.displayName, "Atlas")
        XCTAssertTrue(FileManager.default.fileExists(atPath: created.managedProjectURL.path))

        let renamed = try registry.renameProject(id: created.id, to: "Atlas Revised")
        XCTAssertEqual(renamed.displayName, "Atlas Revised")
        XCTAssertTrue(FileManager.default.fileExists(atPath: renamed.managedProjectURL.path))
        XCTAssertTrue(renamed.pathAliases.contains(where: { $0.contains("Atlas") }))
    }
}
