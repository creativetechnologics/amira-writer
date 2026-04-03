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

        // Ensure the folder exists
        let ensureFolder = """
        tell application "Notes"
            if not (exists folder "\(folderName)") then
                make new folder with properties {name:"\(folderName)"}
            end if
        end tell
        """
        try runAppleScript(ensureFolder)

        // Export each scene
        for scene in scenes {
            let escapedTitle = escapeForAppleScript(scene.title)
            let htmlBody = plainTextToNotesHTML(scene.body)
            let escapedBody = escapeForAppleScript(htmlBody)

            let script = """
            tell application "Notes"
                tell folder "\(folderName)"
                    if exists note "\(escapedTitle)" then
                        set body of note "\(escapedTitle)" to "\(escapedBody)"
                    else
                        make new note with properties {name:"\(escapedTitle)", body:"\(escapedBody)"}
                    end if
                end tell
            end tell
            """
            try runAppleScript(script)
        }

        return scenes.count
    }

    // MARK: - Import

    /// Reads all notes from the "Amira" folder in Apple Notes.
    /// Returns an array of (title, plainTextBody) pairs.
    static func importNotes() async throws -> [SceneNote] {
        // Get note count first
        let countScript = """
        tell application "Notes"
            if not (exists folder "\(folderName)") then
                return "0"
            end if
            return (count of notes of folder "\(folderName)") as text
        end tell
        """
        guard let countStr = try runAppleScript(countScript),
              let count = Int(countStr), count > 0 else {
            return []
        }

        // Read each note individually to avoid AppleScript list serialization issues
        var results: [SceneNote] = []
        for i in 1...count {
            let titleScript = """
            tell application "Notes"
                tell folder "\(folderName)"
                    return name of note \(i)
                end tell
            end tell
            """
            let bodyScript = """
            tell application "Notes"
                tell folder "\(folderName)"
                    return plaintext of note \(i)
                end tell
            end tell
            """

            let title = (try? runAppleScript(titleScript)) ?? ""
            let body = (try? runAppleScript(bodyScript)) ?? ""

            guard !title.isEmpty else { continue }
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
