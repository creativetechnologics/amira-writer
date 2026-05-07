import Foundation

/// Interacts with Apple Notes via NSAppleScript to export/import scene text.
/// Requires macOS automation permission for Notes (prompted on first use).
@available(macOS 26.0, *)
enum AppleNotesService {

    // MARK: - Public Types

    struct SceneNote: Sendable {
        let title: String
        let body: String
    }

    enum NotesError: LocalizedError {
        case scriptFailed(String)
        case folderNotFound
        case notesUnavailable

        var errorDescription: String? {
            switch self {
            case .scriptFailed(let detail):
                return "AppleScript error: \(detail)"
            case .folderNotFound:
                return "The \"Amira\" folder was not found in Apple Notes."
            case .notesUnavailable:
                return "Apple Notes is not available."
            }
        }
    }

    // MARK: - Folder Name

    static let folderName = "Amira"

    // MARK: - Export

    /// Exports scenes to Apple Notes in the "Amira" folder, one note per scene.
    /// Creates the folder if it doesn't exist. Updates existing notes by title match.
    /// Returns the number of scenes exported.
    static func exportScenes(_ scenes: [SceneNote]) async throws -> Int {
        guard !scenes.isEmpty else { return 0 }

        // Ensure the folder exists (1 AppleScript call)
        let ensureFolder = """
        tell application "Notes"
            if not (exists folder "\(folderName)") then
                make new folder with properties {name:"\(folderName)"}
            end if
        end tell
        """
        try runAppleScript(ensureFolder)

        // Batch all scenes into a SINGLE AppleScript call instead of N calls,
        // eliminating N-1 inter-process roundtrips.
        var scriptLines: [String] = [
            "tell application \"Notes\"",
            "    tell folder \"\(folderName)\""
        ]
        for scene in scenes {
            let escapedTitle = escapeForAppleScript(scene.title)
            let htmlBody = plainTextToNotesHTML(scene.body)
            let escapedBody = escapeForAppleScript(htmlBody)
            scriptLines.append("""
                if exists note "\(escapedTitle)" then
                    set body of note "\(escapedTitle)" to "\(escapedBody)"
                else
                    make new note with properties {name:"\(escapedTitle)", body:"\(escapedBody)"}
                end if
            """.replacingOccurrences(of: "\n", with: "\n    "))
        }
        scriptLines.append("    end tell")
        scriptLines.append("end tell")
        try runAppleScript(scriptLines.joined(separator: "\n"))

        return scenes.count
    }

    // MARK: - Import

    /// Reads all notes from the "Amira" folder in Apple Notes.
    /// Returns an array of (title, plainTextBody) pairs.
    static func importNotes() async throws -> [SceneNote] {
        // Batch all titles and bodies into just 2 AppleScript calls instead of 2N,
        // reducing inter-process roundtrips from ~80 to ~2 for 40 scenes.
        // Use the Unicode Record Separator (U+001E) as delimiter — guaranteed
        // not to appear in Apple Notes plain text content. AppleScript uses
        // `character id 30` to embed this control character.

        let separator = "\u{001E}"
        let separatorLit = "(character id 30)"

        let titleScript = """
        tell application "Notes"
            if not (exists folder "\(folderName)") then
                return ""
            end if
            set allTitles to ""
            set noteCount to count of notes of folder "\(folderName)"
            repeat with i from 1 to noteCount
                set noteTitle to name of note i of folder "\(folderName)"
                if i > 1 then set allTitles to allTitles & \(separatorLit)
                set allTitles to allTitles & noteTitle
            end repeat
            return allTitles
        end tell
        """

        let bodyScript = """
        tell application "Notes"
            if not (exists folder "\(folderName)") then
                return ""
            end if
            set allBodies to ""
            set noteCount to count of notes of folder "\(folderName)"
            repeat with i from 1 to noteCount
                set noteBody to plaintext of note i of folder "\(folderName)"
                if i > 1 then set allBodies to allBodies & \(separatorLit)
                set allBodies to allBodies & noteBody
            end repeat
            return allBodies
        end tell
        """

        guard let titlesStr = try runAppleScript(titleScript), !titlesStr.isEmpty else {
            return []
        }
        let bodiesStr = try runAppleScript(bodyScript) ?? ""

        let titleParts = titlesStr.components(separatedBy: separator)
        let bodyParts = bodiesStr.components(separatedBy: separator)

        var results: [SceneNote] = []
        for i in titleParts.indices {
            let title = titleParts[i]
            guard !title.isEmpty else { continue }
            let body = i < bodyParts.count ? bodyParts[i] : ""
            results.append(SceneNote(title: title, body: body))
        }
        return results
    }

    // MARK: - Folder Check

    /// Returns true if the "Amira" folder exists in Apple Notes.
    static func folderExists() async -> Bool {
        let script = """
        tell application "Notes"
            if exists folder "\(folderName)" then
                return "1"
            else
                return "0"
            end if
        end tell
        """
        return (try? runAppleScript(script)) == "1"
    }

    // MARK: - Delete All Notes in Folder

    /// Deletes all notes in the "Amira" folder before a fresh export.
    /// This avoids stale notes from renamed/deleted scenes.
    static func deleteAllNotesInFolder() throws {
        let script = """
        tell application "Notes"
            if exists folder "\(folderName)" then
                delete every note of folder "\(folderName)"
            end if
        end tell
        """
        try runAppleScript(script)
    }

    // MARK: - Private Helpers

    @discardableResult
    private static func runAppleScript(_ source: String) throws -> String? {
        var errorDict: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            throw NotesError.notesUnavailable
        }
        let result = script.executeAndReturnError(&errorDict)
        if let errorDict {
            let message = errorDict[NSAppleScript.errorMessage] as? String
                ?? errorDict.description
            throw NotesError.scriptFailed(message)
        }
        return result.stringValue
    }

    /// Escapes a string for safe embedding in an AppleScript double-quoted string.
    private static func escapeForAppleScript(_ string: String) -> String {
        string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Wraps plain text in minimal HTML for Apple Notes.
    /// Converts newlines to <br> tags so formatting is preserved.
    private static func plainTextToNotesHTML(_ text: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        let lines = escaped.components(separatedBy: "\n")
        let htmlLines = lines.joined(separator: "<br>")
        return "<html><body>\(htmlLines)</body></html>"
    }
}
