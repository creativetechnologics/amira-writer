import Foundation
import ProjectKit

// Manually test the discover + load path

let projectURL = URL(fileURLWithPath: "/Volumes/Storage VIII/Users/gary/Amira - A Modern Opera")
print("= Loading from: \(projectURL.path)")

// Step 1: Discover
let descriptors = ScenePackageStore.discover(in: projectURL)
print("= discover() returned \(descriptors.count) scenes")
for d in descriptors.prefix(3) {
    print("  \(d.id.uuidString.prefix(8))  \(d.title)  \(d.order)  \(d.projectRelativePath)")
}

// Step 2: Load one scene
if let first = descriptors.first {
    let markdownURL = first.sceneJSONURL
    print("\n= Loading: \(markdownURL.path)")
    print("  File exists: \(FileManager.default.fileExists(atPath: markdownURL.path))")

    do {
        let data = try ScenePackageStore.workspaceDocumentDataFromWriteMarkdown(
            markdownURL: markdownURL,
            projectURL: projectURL
        )
        print("  workspaceDocumentData: \(data.count) bytes")

        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            print("  FAIL: Could not parse workspace document JSON")
            exit(1)
        }
        print("  title: \(root["title"] ?? "?")")
        print("  songID: \(root["songID"] ?? "?")")

        if let versions = root["versions"] as? [[String: Any]],
           let firstVer = versions.first,
           let lyrics = firstVer["lyrics"] as? String {
            print("  lyrics: \(lyrics.count) chars")
            print("  lyrics preview: \(lyrics.prefix(100))")
            if lyrics.isEmpty {
                print("  FAIL: lyrics are empty!")
                exit(1)
            }
        } else {
            print("  FAIL: no versions or lyrics in workspace document")
            exit(1)
        }

    } catch {
        print("  FAIL: \(error.localizedDescription)")
        exit(1)
    }
}

print("\n= ALL CHECKS PASSED")
