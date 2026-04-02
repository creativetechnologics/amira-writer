import SwiftUI

@available(macOS 26.0, *)
struct ExpressionLibraryView: View {
    @State private var selectedCategory: EmotionLibrary.EmotionCategory?
    @State private var searchText: String = ""
    @State private var selectedPresetID: String?

    private var filteredPresets: [EmotionLibrary.ExpressionPreset] {
        var result = EmotionLibrary.presets
        if let category = selectedCategory {
            result = result.filter { $0.category == category }
        }
        if !searchText.isEmpty {
            let query = searchText.lowercased()
            result = result.filter {
                $0.displayName.lowercased().contains(query) ||
                $0.id.lowercased().contains(query) ||
                $0.aliases.contains(where: { $0.lowercased().contains(query) })
            }
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header with search and category filter
            HStack(spacing: 12) {
                TextField("Search expressions...", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)

                Picker("Category", selection: $selectedCategory) {
                    Text("All").tag(EmotionLibrary.EmotionCategory?.none)
                    ForEach(EmotionLibrary.EmotionCategory.allCases, id: \.self) { cat in
                        Text(cat.rawValue.capitalized).tag(EmotionLibrary.EmotionCategory?.some(cat))
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 140)

                Spacer()

                Text("\(filteredPresets.count) expressions")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Expression grid
            ScrollView {
                LazyVGrid(columns: [
                    GridItem(.adaptive(minimum: 180, maximum: 220))
                ], spacing: 10) {
                    ForEach(filteredPresets) { preset in
                        expressionCard(preset)
                    }
                }
                .padding(.vertical, 4)
            }
            .clipped()

            // Detail panel for selected expression
            if let selectedID = selectedPresetID,
               let preset = EmotionLibrary.presets.first(where: { $0.id == selectedID }) {
                Divider()
                expressionDetail(preset)
            }
        }
    }

    // MARK: - Expression Card

    private func expressionCard(_ preset: EmotionLibrary.ExpressionPreset) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(preset.displayName)
                    .font(.callout.weight(.medium))
                Spacer()
                categoryBadge(preset.category)
            }

            // Mini face parameter visualization
            HStack(spacing: 6) {
                parameterBar(label: "Brow", value: preset.browLift, range: -1...1)
                parameterBar(label: "Eyes", value: preset.eyeOpen - 1.0, range: -1...1)
                parameterBar(label: "Smile", value: preset.smile, range: -1...1)
            }

            if !preset.aliases.isEmpty {
                Text(preset.aliases.prefix(3).joined(separator: ", "))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(selectedPresetID == preset.id ? Color.accentColor.opacity(0.08) : Color.clear)
        )
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.quaternary.opacity(0.15))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(selectedPresetID == preset.id ? Color.accentColor.opacity(0.3) : .clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            selectedPresetID = selectedPresetID == preset.id ? nil : preset.id
        }
    }

    // MARK: - Parameter Bar

    private func parameterBar(label: String, value: Double, range: ClosedRange<Double>) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.system(size: 8))
                .foregroundStyle(.tertiary)

            GeometryReader { geo in
                let width = geo.size.width
                let midX = width / 2
                let normalized = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
                let barX = width * normalized

                ZStack(alignment: .leading) {
                    // Background track
                    RoundedRectangle(cornerRadius: 2)
                        .fill(.quaternary)
                        .frame(height: 4)

                    // Center line
                    Rectangle()
                        .fill(.tertiary)
                        .frame(width: 1, height: 6)
                        .position(x: midX, y: 3)

                    // Value indicator
                    Circle()
                        .fill(value >= 0 ? Color.blue : Color.orange)
                        .frame(width: 6, height: 6)
                        .position(x: max(3, min(width - 3, barX)), y: 3)
                }
            }
            .frame(height: 6)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Category Badge

    private func categoryBadge(_ category: EmotionLibrary.EmotionCategory) -> some View {
        let color: Color = switch category {
        case .positive: .green
        case .negative: .red
        case .surprise: .yellow
        case .social: .blue
        case .neutral: .gray
        case .compound: .purple
        case .microExpression: .orange
        }

        return Text(category.rawValue.prefix(3).uppercased())
            .font(.system(size: 8, weight: .bold, design: .monospaced))
            .foregroundStyle(color)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 3))
    }

    // MARK: - Detail Panel

    private func expressionDetail(_ preset: EmotionLibrary.ExpressionPreset) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(preset.displayName)
                    .font(.headline)
                categoryBadge(preset.category)
                Spacer()
            }

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    Text("Brow Lift").font(.caption).foregroundStyle(.secondary)
                    Text(String(format: "%.2f", preset.browLift)).font(.caption.monospaced())
                    Text("Brow Tilt").font(.caption).foregroundStyle(.secondary)
                    Text(String(format: "%.2f", preset.browTilt)).font(.caption.monospaced())
                }
                GridRow {
                    Text("Eye Open").font(.caption).foregroundStyle(.secondary)
                    Text(String(format: "%.2f", preset.eyeOpen)).font(.caption.monospaced())
                    Text("Smile").font(.caption).foregroundStyle(.secondary)
                    Text(String(format: "%.2f", preset.smile)).font(.caption.monospaced())
                }
                GridRow {
                    Text("Head Pitch").font(.caption).foregroundStyle(.secondary)
                    Text(String(format: "%.2f", preset.headPitch)).font(.caption.monospaced())
                    Text("Aliases").font(.caption).foregroundStyle(.secondary)
                    Text(preset.aliases.joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}
