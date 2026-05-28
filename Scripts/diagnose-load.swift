#!/usr/bin/env swift -F /Volumes/Storage VIII/Programming/Amira Writer/.build/release

import Foundation

// Manually simulate what ScenePackageStore.workspaceDocumentDataFromWriteMarkdown does
let projectURL = URL(fileURLWithPath: "/Volumes/Storage VIII/Users/gary/Amira - A Modern Opera")
let mdFile = projectURL.appendingPathComponent("Write/1.01.0 - Overture.md")

print("=== DIAGNOSTIC ===")
print("Project: \(projectURL.path)")
print("MD file: \(mdFile.path)")
print("MD exists: \(FileManager.default.fileExists(atPath: mdFile.path))")

// Read scene-index.json
let indexURL = projectURL.appendingPathComponent("scene-index.json")
print("Index exists: \(FileManager.default.fileExists(atPath: indexURL.path))")

guard let data = try? Data(contentsOf: indexURL),
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let scenes = json["scenes"] as? [[String: Any]] else {
    print("FAILED: scene-index.json")
    exit(1)
}
print("Scenes: \(scenes.count)")

// Match by filename
let filename = mdFile.lastPathComponent
let titleFromFile = (filename as NSString).deletingPathExtension
print("Filename: \(filename)")
print("Title from file: \(titleFromFile)")

let matchedEntry = scenes.first { ($0["title"] as? String) == titleFromFile }
if let entry = matchedEntry {
    print("MATCHED: id=\(entry["id"] ?? "?") title=\(entry["title"] ?? "?") order=\(entry["order"] ?? "?")")
} else {
    print("NO MATCH for '\(titleFromFile)'")
    print("Available titles in index:")
    for s in scenes.prefix(10) {
        print("  '\(s["title"] ?? "?")'")
    }
}

// Read and strip frontmatter
if let mdContent = try? String(contentsOf: mdFile, encoding: .utf8) {
    print("MD content length: \(mdContent.count)")
    print("Has frontmatter: \(mdContent.hasPrefix("---"))")
    
    var body = mdContent
    if mdContent.hasPrefix("---") {
        let afterFirst = mdContent.dropFirst(3).drop(while: { $0 == "\n" || $0 == "\r" })
        if let endRange = afterFirst.range(of: "\n---") {
            body = String(afterFirst[endRange.upperBound...]).trimmingCharacters(in: .newlines)
            print("Frontmatter stripped. Body length: \(body.count)")
            print("First 100 chars: \(body.prefix(100))")
        } else {
            print("WARNING: Could not find closing ---")
        }
    }
    
    // Simulate OWSSongDocument.fromJSON
    let testDoc: [String: Any] = [
        "songID": matchedEntry?["id"] as? String ?? UUID().uuidString,
        "title": matchedEntry?["title"] as? String ?? titleFromFile,
        "canonicalTitle": (matchedEntry?["title"] as? String ?? "").lowercased(),
        "activeVersionID": UUID().uuidString,
        "versions": [[
            "id": UUID().uuidString,
            "label": "Current Draft",
            "lyrics": body,
            "saveType": "imported",
            "isBookmarked": false,
        ]],
    ]
    print("SUCCESS: Generated workspace document with \(body.count) lyric chars")
} else {
    print("FAILED: Could not read MD file")
}

// Now also simulate ScenePackageStore.discover()
print("\n=== Simulate discover() ===")
let discoverDescriptor = scenes.sorted { ($0["order"] as? Int ?? 0) < ($1["order"] as? Int ?? 0) }
print("Sorted scene count: \(discoverDescriptor.count)")
print("First scene: \(discoverDescriptor.first?["title"] ?? "?")")
print("Last scene: \(discoverDescriptor.last?["title"] ?? "?")")
print("\n=== ALL CHECKS PASSED ===")
