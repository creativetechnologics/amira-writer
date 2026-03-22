import SwiftUI

// MARK: - Synopsis Section View

/// Displays the project synopsis in the inspector panel with clickable
/// scene navigation. Scene markers in the format {{{SCENE:Songs/filename.ows}}}
/// are parsed and hidden — the text below each marker links to that scene.

@available(macOS 26.0, *)
struct SynopsisSectionView: View {
    @Bindable var store: ScriptStore
    @State private var isEditing: Bool = false
    @State private var editText: String = ""

    var body: some View {
        VStack(spacing: 0) {
            synopsisHeader
            Divider().opacity(0.3)

            if isEditing {
                editView
            } else if store.synopsisText.isEmpty {
                emptyState
            } else {
                synopsisContent
            }
        }
        .frame(minHeight: 200)
    }

    // MARK: - Header

    private var synopsisHeader: some View {
        HStack(spacing: 6) {
            Spacer()

            if isEditing {
                Button {
                    store.synopsisText = editText
                    store.saveSynopsis()
                    isEditing = false
                } label: {
                    Text("Done")
                        .font(.system(size: 10, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            } else {
                Button {
                    editText = store.synopsisText
                    isEditing = true
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Edit Synopsis")
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
    }

    // MARK: - Edit View

    private var editView: some View {
        TextEditor(text: $editText)
            .font(.system(size: 13))
            .scrollContentBackground(.hidden)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.black.opacity(0.20))
            )
    }

    // MARK: - Synopsis Content (read-only with clickable scenes)

    private var synopsisContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(parsedSections.enumerated()), id: \.offset) { _, section in
                    sectionView(section)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func sectionView(_ section: SynopsisSection) -> some View {
        let text = section.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            if let scenePath = section.scenePath,
               let resolvedPath = SynopsisScenePathResolver.resolve(
                   scenePath,
                   availablePaths: store.librettoFiles.map(\.relativePath)
               ) {
                Button {
                    store.scrollTarget = resolvedPath
                } label: {
                    Text(text)
                        .font(.system(size: 13))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .overlay(alignment: .leading) {
                    // Subtle indicator that this section is linked
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.15))
                        .frame(width: 2)
                        .offset(x: -6)
                }
            } else {
                Text(text)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.plaintext")
                .font(.system(size: 24))
                .foregroundStyle(.tertiary)

            Text("No synopsis yet")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 20)
    }

    // MARK: - Parsing

    /// Parses synopsis text into sections, splitting on {{{SCENE:path}}} markers.
    private var parsedSections: [SynopsisSection] {
        SynopsisParser.parse(store.synopsisText)
    }
}

// MARK: - Synopsis Parser

struct SynopsisSection {
    let scenePath: String?
    let text: String
}

enum SynopsisScenePathResolver {
    static func resolve(_ rawScenePath: String, availablePaths: [String]) -> String? {
        let trimmed = rawScenePath
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        guard !trimmed.isEmpty else { return nil }

        let normalizedReference = normalize(trimmed)
        if let exact = availablePaths.first(where: {
            normalize($0).caseInsensitiveCompare(normalizedReference) == .orderedSame
        }) {
            return exact
        }

        let referenceName = URL(fileURLWithPath: normalizedReference).lastPathComponent.lowercased()
        if let byName = availablePaths.first(where: {
            URL(fileURLWithPath: normalize($0)).lastPathComponent.lowercased() == referenceName
        }) {
            return byName
        }

        if !normalizedReference.hasPrefix("Songs/"),
           let prefixed = availablePaths.first(where: {
               normalize($0).caseInsensitiveCompare("Songs/\(normalizedReference)") == .orderedSame
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

enum SynopsisParser {
    /// Triple-brace marker: {{{SCENE:Songs/filename.ows}}}
    private static let markerPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\{\{\{SCENE:(.+?)\}\}\}\s*\n?"#,
            options: []
        )
    }()

    /// Legacy double-brace marker for backwards compatibility.
    private static let legacyMarkerPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\{\{SCENE:(.+?)\}\}\s*\n?"#,
            options: []
        )
    }()

    /// Parse synopsis text into sections. Each section optionally has a scene
    /// path (from a {{{SCENE:path}}} marker) and the text that follows it.
    /// Falls back to legacy {{SCENE:path}} if no triple-brace markers found.
    static func parse(_ text: String) -> [SynopsisSection] {
        guard !text.isEmpty else { return [] }

        let nsString = text as NSString
        let fullRange = NSRange(location: 0, length: nsString.length)
        var matches = markerPattern.matches(in: text, range: fullRange)

        // Fall back to legacy double-brace if no triple-brace markers found
        if matches.isEmpty {
            matches = legacyMarkerPattern.matches(in: text, range: fullRange)
        }

        if matches.isEmpty {
            return [SynopsisSection(scenePath: nil, text: text)]
        }

        var sections: [SynopsisSection] = []

        // Text before the first marker (if any)
        if let first = matches.first, first.range.location > 0 {
            let preText = nsString.substring(with: NSRange(location: 0, length: first.range.location))
            if !preText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                sections.append(SynopsisSection(scenePath: nil, text: preText))
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
            sections.append(SynopsisSection(scenePath: scenePath, text: sectionText))
        }

        return sections
    }
}
