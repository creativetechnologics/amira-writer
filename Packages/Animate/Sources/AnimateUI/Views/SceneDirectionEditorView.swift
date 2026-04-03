import SwiftUI
import ProjectKit

/// Live editor for scene direction markup text.
///
/// Displays a `TextEditor` bound to the selected scene's `directionTemplate.notes`.
/// As the user types, the text is re-parsed using `SceneDirectionParser.parse()` and
/// the resulting directions are shown in a scrollable list below the editor.
/// A "Re-compile" button saves the updated template back to the store and triggers
/// a direction-template update (which drives scenario recompilation).
@available(macOS 26.0, *)
struct SceneDirectionEditorView: View {

    @Bindable var store: AnimateStore
    @State private var editingText: String = ""
    @State private var parseResult: SceneDirectionParser.ParseResult = .init(directions: [], scriptLines: [], errors: [])
    @State private var hasUnsavedChanges = false

    private var selectedScene: AnimationScene? {
        store.selectedScene
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBar

            Divider()

            editorArea

            Divider()

            parsedDirectionsList
        }
        .background(OperaChromeTheme.workspaceBackground)
        .onAppear {
            loadFromScene()
        }
        .onChange(of: store.selectedSceneID) { _, _ in
            loadFromScene()
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("DIRECTIONS")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(1.2)
                    .foregroundStyle(OperaChromeTheme.textTertiary)
                Text(selectedScene?.name ?? "No Scene Selected")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(OperaChromeTheme.textPrimary)
                    .lineLimit(1)
            }

            Spacer()

            if hasUnsavedChanges {
                Text("Unsaved")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.orange)
            }

            Button {
                saveAndRecompile()
            } label: {
                Label("Re-compile", systemImage: "bolt.fill")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(selectedScene == nil)
            .help("Save directions and recompile the scene production plan")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Editor

    private var editorArea: some View {
        TextEditor(text: $editingText)
            .font(.system(size: 12, design: .monospaced))
            .scrollContentBackground(.hidden)
            .background(OperaChromeTheme.workspaceBackground)
            .frame(minHeight: 180, maxHeight: 360)
            .padding(10)
            .onChange(of: editingText) { _, newValue in
                hasUnsavedChanges = newValue != (selectedScene?.directionTemplate?.notes ?? "")
                parseResult = SceneDirectionParser.parse(newValue)
            }
            .overlay(alignment: .topLeading) {
                if editingText.isEmpty {
                    Text("""
                        Enter scene directions here, e.g.:
                        [enter: \"Character\" | position=center | emotion=neutral]
                        [camera: wide | to=medium | bars=1-4]
                        """)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(OperaChromeTheme.textTertiary)
                    .padding(14)
                    .allowsHitTesting(false)
                }
            }
    }

    // MARK: - Parsed Directions List

    private var parsedDirectionsList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("PARSED DIRECTIONS")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(1.0)
                    .foregroundStyle(OperaChromeTheme.textTertiary)
                Spacer()
                HStack(spacing: 8) {
                    if !parseResult.errors.isEmpty {
                        Label("\(parseResult.errors.count) error(s)", systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.orange)
                    }
                    Text("\(parseResult.directions.count) direction(s)")
                        .font(.system(size: 10))
                        .foregroundStyle(OperaChromeTheme.textSecondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 6)

            Divider()

            if parseResult.directions.isEmpty && parseResult.errors.isEmpty {
                Text("No directions parsed. Enter bracketed direction syntax above.")
                    .font(.system(size: 11))
                    .foregroundStyle(OperaChromeTheme.textTertiary)
                    .padding(14)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(parseResult.errors, id: \.lineNumber) { err in
                            directionErrorRow(err)
                        }
                        ForEach(parseResult.directions) { direction in
                            directionRow(direction)
                        }
                    }
                    .padding(10)
                }
                .frame(maxHeight: 260)
            }
        }
    }

    private func directionRow(_ direction: SceneDirection) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(direction.tag.rawValue.uppercased())
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .tracking(0.5)
                .foregroundStyle(tagColor(direction.tag))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().fill(tagColor(direction.tag).opacity(0.15)))
                .fixedSize()

            VStack(alignment: .leading, spacing: 2) {
                if !direction.primaryValue.isEmpty {
                    Text(direction.primaryValue)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(OperaChromeTheme.textPrimary)
                }
                if !direction.parameters.isEmpty {
                    let paramText = direction.parameters
                        .sorted(by: { $0.key < $1.key })
                        .map { "\($0.key)=\($0.value)" }
                        .joined(separator: "  ")
                    Text(paramText)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(OperaChromeTheme.textSecondary)
                }
            }

            Spacer()

            Text("L\(direction.sourceLineNumber)")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(OperaChromeTheme.textTertiary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(OperaChromeTheme.raisedBackground.opacity(0.5))
        )
    }

    private func directionErrorRow(_ err: SceneDirectionParser.ParseError) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
            Text("Line \(err.lineNumber): \(err.message)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.orange)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.orange.opacity(0.10))
        )
    }

    // MARK: - Actions

    private func loadFromScene() {
        editingText = selectedScene?.directionTemplate?.notes ?? ""
        parseResult = SceneDirectionParser.parse(editingText)
        hasUnsavedChanges = false
    }

    private func saveAndRecompile() {
        guard selectedScene != nil else { return }
        store.updateSelectedSceneDirectionTemplate(
            defaultCameraShot: selectedScene?.directionTemplate?.defaultCameraShot,
            focusCharacterID: selectedScene?.directionTemplate?.focusCharacterID,
            notes: editingText
        )
        hasUnsavedChanges = false
    }

    // MARK: - Helpers

    private func tagColor(_ tag: DirectionTag) -> Color {
        switch tag {
        case .scene:        return .purple
        case .enter:        return .green
        case .exit:         return .red
        case .move:         return .blue
        case .emotion:      return .pink
        case .action:       return .orange
        case .gesture:      return .yellow
        case .camera:       return .cyan
        case .lipsync:      return .mint
        case .object:       return Color(red: 0.78, green: 0.62, blue: 0.38)
        case .objectMove:   return Color(red: 0.78, green: 0.62, blue: 0.38)
        case .objectState:  return Color(red: 0.78, green: 0.62, blue: 0.38)
        case .objectVisibility: return Color(red: 0.78, green: 0.62, blue: 0.38)
        case .pause:        return .gray
        case .sfx:          return .indigo
        case .transition:   return .teal
        }
    }
}
