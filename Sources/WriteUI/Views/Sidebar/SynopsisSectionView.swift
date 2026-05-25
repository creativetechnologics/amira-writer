import SwiftUI
import ProjectKit

// MARK: - Synopsis Embedding Utility

/// Extracts and updates {{{SYNOPSIS}}}...{{{/SYNOPSIS}}} blocks embedded
/// at the start of libretto file content. The block is invisible in the
/// normal editor but stores the per-scene summary paragraph.
enum SynopsisEmbedding {
    private static let openTag = "{{{SYNOPSIS}}}"
    private static let closeTag = "{{{/SYNOPSIS}}}"

    private static let pattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\{\{\{SYNOPSIS\}\}\}([\s\S]*?)\{\{\{/SYNOPSIS\}\}\}\s*\n?"#,
            options: []
        )
    }()

    /// Extract the synopsis text from a libretto file's content.
    static func extract(from content: String) -> String {
        let nsString = content as NSString
        let fullRange = NSRange(location: 0, length: nsString.length)
        guard let match = pattern.firstMatch(in: content, range: fullRange) else {
            return ""
        }
        return nsString.substring(with: match.range(at: 1))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Return the libretto content with the synopsis block removed.
    /// This is what the editor should display.
    static func stripForDisplay(content: String) -> String {
        let nsString = content as NSString
        let fullRange = NSRange(location: 0, length: nsString.length)
        return pattern.stringByReplacingMatches(
            in: content,
            range: fullRange,
            withTemplate: ""
        )
    }

    /// Update (or insert) the synopsis block in the libretto content.
    /// The block is placed at the very beginning of the file.
    static func update(content: String, synopsis: String) -> String {
        let trimmed = synopsis.trimmingCharacters(in: .whitespacesAndNewlines)
        let stripped = stripForDisplay(content: content)

        if trimmed.isEmpty {
            return stripped
        }

        return "\(openTag)\n\(trimmed)\n\(closeTag)\n\(stripped)"
    }
}

// MARK: - Synopsis Section View

/// Displays per-scene synopsis summaries in the inspector panel.
/// Each scene's synopsis is embedded within its libretto file as a hidden
/// {{{SYNOPSIS}}}...{{{/SYNOPSIS}}} block.
/// The view auto-follows the active scene.

@available(macOS 26.0, *)
struct SynopsisSectionView: View {
    @Bindable var store: ScriptStore
    @State private var editingPath: String?
    @State private var editText: String = ""

    private var activeScenePath: String? {
        store.activeSongPath
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(store.librettoFiles, id: \.relativePath) { file in
                        let isActive = file.relativePath == activeScenePath
                        let synopsis = SynopsisEmbedding.extract(from: file.content)
                        let isEditing = editingPath == file.relativePath

                        sceneSection(
                            file: file,
                            synopsis: synopsis,
                            isActive: isActive,
                            isEditing: isEditing
                        )
                        .id(file.relativePath)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: activeScenePath) { _, newPath in
                guard let path = newPath else { return }
                withAnimation(.easeInOut(duration: 0.25)) {
                    proxy.scrollTo(path, anchor: .top)
                }
            }
            .onAppear {
                if let path = activeScenePath {
                    proxy.scrollTo(path, anchor: .top)
                }
            }
        }
    }

    // MARK: - Scene Section

    @ViewBuilder
    private func sceneSection(
        file: ProjectTextFile,
        synopsis: String,
        isActive: Bool,
        isEditing: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            // Scene title - clickable to navigate
            HStack(spacing: 6) {
                Button {
                    store.requestScrollTarget(file.relativePath)
                } label: {
                    Text(file.displayName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(isActive ? Color.accentColor : OperaChromeTheme.textSecondary)
                        .lineLimit(1)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Spacer(minLength: 0)

                if isEditing {
                    Button {
                        commitEdit(for: file.relativePath)
                    } label: {
                        Text("Done")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                } else {
                    Button {
                        editText = synopsis
                        editingPath = file.relativePath
                    } label: {
                        Image(systemName: "pencil")
                            .font(.system(size: 9))
                            .foregroundStyle(OperaChromeTheme.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .opacity(isActive ? 1 : 0.5)
                }
            }

            // Synopsis content or edit field
            if isEditing {
                TextEditor(text: $editText)
                    .font(.system(size: 12))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 60, maxHeight: 150)
                    .padding(6)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.black.opacity(0.20))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.accentColor.opacity(0.3), lineWidth: 1)
                    )
            } else if synopsis.isEmpty {
                Text("No synopsis")
                    .font(.system(size: 12))
                    .foregroundStyle(OperaChromeTheme.textTertiary)
                    .italic()
                    .padding(.vertical, 2)
            } else {
                Text(synopsis)
                    .font(.system(size: 12))
                    .foregroundStyle(isActive ? OperaChromeTheme.textPrimary : OperaChromeTheme.textSecondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 2)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isActive ? Color.accentColor.opacity(0.08) : Color.clear)
        )
        .overlay(alignment: .leading) {
            if isActive {
                Rectangle()
                    .fill(Color.accentColor.opacity(0.4))
                    .frame(width: 2)
            }
        }
    }

    // MARK: - Actions

    private func commitEdit(for path: String) {
        store.updateSynopsis(forScenePath: path, text: editText)
        editingPath = nil
        editText = ""
    }
}

// MARK: - Legacy Synopsis Parser (retained only for legacy/manual import helpers)

struct LegacySynopsisSection {
    let scenePath: String?
    let text: String
}

enum LegacySynopsisParser {
    private static let markerPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\{\{\{SCENE:(.+?)\}\}\}\s*\n?"#,
            options: []
        )
    }()

    private static let legacyMarkerPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\{\{SCENE:(.+?)\}\}\s*\n?"#,
            options: []
        )
    }()

    static func parse(_ text: String) -> [LegacySynopsisSection] {
        guard !text.isEmpty else { return [] }

        let nsString = text as NSString
        let fullRange = NSRange(location: 0, length: nsString.length)
        var matches = markerPattern.matches(in: text, range: fullRange)

        if matches.isEmpty {
            matches = legacyMarkerPattern.matches(in: text, range: fullRange)
        }

        if matches.isEmpty {
            return [LegacySynopsisSection(scenePath: nil, text: text)]
        }

        var sections: [LegacySynopsisSection] = []

        if let first = matches.first, first.range.location > 0 {
            let preText = nsString.substring(with: NSRange(location: 0, length: first.range.location))
            if !preText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                sections.append(LegacySynopsisSection(scenePath: nil, text: preText))
            }
        }

        for (i, match) in matches.enumerated() {
            let scenePath = nsString.substring(with: match.range(at: 1))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let textStart = match.range.location + match.range.length
            let textEnd: Int
            if i + 1 < matches.count {
                textEnd = matches[i + 1].range.location
            } else {
                textEnd = nsString.length
            }
            let sectionText = nsString.substring(with: NSRange(location: textStart, length: textEnd - textStart))
            sections.append(LegacySynopsisSection(scenePath: scenePath, text: sectionText))
        }

        return sections
    }

    static func resolvePath(_ rawScenePath: String, availablePaths: [String]) -> String? {
        let trimmed = rawScenePath
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        guard !trimmed.isEmpty else { return nil }

        let normalized = normalize(trimmed)
        if let exact = availablePaths.first(where: {
            normalize($0).caseInsensitiveCompare(normalized) == .orderedSame
        }) {
            return exact
        }

        let referenceName = URL(fileURLWithPath: normalized).lastPathComponent.lowercased()
        if let byName = availablePaths.first(where: {
            URL(fileURLWithPath: normalize($0)).lastPathComponent.lowercased() == referenceName
        }) {
            return byName
        }

        if !normalized.hasPrefix("Songs/"),
           let prefixed = availablePaths.first(where: {
               normalize($0).caseInsensitiveCompare("Songs/\(normalized)") == .orderedSame
           }) {
            return prefixed
        }

        return nil
    }

    private static func normalize(_ rawPath: String) -> String {
        rawPath
            .replacingOccurrences(of: "\\", with: "/")
            .replacingOccurrences(of: "./", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
