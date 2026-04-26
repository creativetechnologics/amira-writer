import SwiftUI
import ProjectKit

// MARK: - Script Card Lane (read-only)
//
// A calm right-lane projection of the structured script cards for a
// single song. Slice 1 is read-only: cards reflect whatever the importer
// produced (or, eventually, what the Director Pass review queue
// accepted). Editing comes in slice 2.

@available(macOS 26.0, *)
struct ScriptCardLaneView: View {
    let displayName: String
    let path: String
    @Bindable var store: ScriptStore

    private var songCards: SongScriptCards? {
        store.scriptCards.songs[path]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if let cards = songCards, !cards.scenes.isEmpty {
                ForEach(cards.scenes) { scene in
                    ScriptCardSceneView(scene: scene)
                }
            } else {
                emptyState
            }
        }
        .padding(.top, 4)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("CARDS")
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.4)
                .foregroundStyle(Color.white.opacity(0.55))
            Spacer()
            if let count = songCards?.scenes.first.map({ $0.shots.count + $0.actions.count + $0.directions.count }),
               count > 0 {
                Text("\(count)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.4))
            }
        }
    }

    private var emptyState: some View {
        Text("No structured cards yet for \(displayName).")
            .font(.system(size: 12))
            .foregroundStyle(Color.white.opacity(0.35))
            .padding(.vertical, 6)
    }
}

@available(macOS 26.0, *)
private struct ScriptCardSceneView: View {
    let scene: ScriptScene

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let label = scene.label, !label.isEmpty {
                Text(label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.7))
            }

            ForEach(scene.directions) { direction in
                LegacyDirectionRow(card: direction)
            }
            ForEach(scene.actions) { action in
                ActionRow(card: action)
            }
            ForEach(scene.shots) { shot in
                ShotRow(card: shot)
            }
        }
    }
}

@available(macOS 26.0, *)
private struct LegacyDirectionRow: View {
    let card: LegacyDirectionCard
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(card.address)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.45))
                if let excerpt = card.lyricAnchor?.excerpt, !excerpt.isEmpty {
                    Text(excerpt)
                        .font(.system(size: 10))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(Color.white.opacity(0.3))
                }
            }
            Text(card.descriptionText)
                .font(.system(size: 12))
                .foregroundStyle(Color.white.opacity(0.78))
        }
        .padding(.vertical, 4)
    }
}

@available(macOS 26.0, *)
private struct ActionRow: View {
    let card: ActionCard
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Rectangle()
                .fill(Color.white.opacity(0.18))
                .frame(width: 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(card.text)
                    .font(.system(size: 12).italic())
                    .foregroundStyle(Color.white.opacity(0.7))
                if let excerpt = card.lyricAnchor?.excerpt, !excerpt.isEmpty {
                    Text(excerpt)
                        .font(.system(size: 10))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(Color.white.opacity(0.3))
                }
            }
        }
        .padding(.vertical, 2)
    }
}

@available(macOS 26.0, *)
private struct ShotRow: View {
    let card: ScriptShotCard

    private var headline: String {
        if let label = card.label, !label.isEmpty { return label }
        if let movement = card.camera.movement, !movement.isEmpty {
            return movement.replacingOccurrences(of: "_", with: " ")
        }
        return "Shot"
    }

    private var subline: String {
        var parts: [String] = []
        if let size = card.camera.shotSize, !size.isEmpty {
            parts.append(size.replacingOccurrences(of: "_", with: " "))
        }
        if let focus = card.camera.focus, !focus.isEmpty {
            parts.append("on \(focus)")
        }
        if let intent = card.camera.intent, !intent.isEmpty {
            parts.append(intent)
        }
        if let bars = formattedBars { parts.append(bars) }
        return parts.joined(separator: " · ")
    }

    private var formattedBars: String? {
        if let start = card.timing.startBar, let end = card.timing.endBar {
            return "bars \(start)–\(end)"
        }
        if let start = card.timing.startBar {
            return "bar \(start)"
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(headline.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(Color.white.opacity(0.78))
                Spacer()
                StatusDot(status: card.status)
            }
            if !subline.isEmpty {
                Text(subline)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white.opacity(0.5))
            }
            if !card.direction.isEmpty {
                Text(card.direction)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.white.opacity(0.7))
            }
            if !card.tags.isEmpty {
                TagPills(tags: card.tags)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
        )
    }
}

@available(macOS 26.0, *)
private struct StatusDot: View {
    let status: CardStatus
    private var color: Color {
        switch status {
        case .manual:         return Color.white.opacity(0.45)
        case .importedLegacy: return Color.white.opacity(0.25)
        case .llmProposed:    return Color(red: 0.92, green: 0.78, blue: 0.40)
        case .llmAccepted:    return Color(red: 0.50, green: 0.78, blue: 0.55)
        }
    }
    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 5, height: 5)
            .help(status.rawValue)
    }
}

@available(macOS 26.0, *)
private struct TagPills: View {
    let tags: TagSet

    private var labelled: [(String, [String])] {
        var out: [(String, [String])] = []
        if !tags.characters.isEmpty { out.append(("char", tags.characters)) }
        if !tags.places.isEmpty { out.append(("place", tags.places)) }
        if !tags.props.isEmpty { out.append(("prop", tags.props)) }
        if !tags.mood.isEmpty { out.append(("mood", tags.mood)) }
        if !tags.lighting.isEmpty { out.append(("light", tags.lighting)) }
        if !tags.landmarks.isEmpty { out.append(("mark", tags.landmarks)) }
        if !tags.automation.isEmpty { out.append(("auto", tags.automation)) }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(labelled.enumerated()), id: \.offset) { _, pair in
                HStack(spacing: 4) {
                    Text(pair.0)
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.4))
                    Text(pair.1.joined(separator: ", "))
                        .font(.system(size: 10))
                        .foregroundStyle(Color.white.opacity(0.55))
                }
            }
        }
    }
}
