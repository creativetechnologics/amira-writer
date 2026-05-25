import SwiftUI

@available(macOS 26.0, *)
extension InspectorView {
    @ViewBuilder
    func labeledTextField(_ title: String, text: Binding<String>, axis: Axis = .horizontal) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(title, text: text, axis: axis)
                .textFieldStyle(.roundedBorder)
        }
    }

    @ViewBuilder
    func labeledIntegerField(_ title: String, value: Binding<Int>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(title, value: value, format: IntegerFormatStyle<Int>().grouping(.never))
                .textFieldStyle(.roundedBorder)
        }
    }

    @ViewBuilder
    func labeledOptionalIntegerField(_ title: String, value: Binding<Int?>) -> some View {
        let stringBinding = Binding<String>(
            get: { value.wrappedValue.map(String.init) ?? "" },
            set: { newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                value.wrappedValue = trimmed.isEmpty ? nil : Int(trimmed)
            }
        )
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(title, text: stringBinding)
                .textFieldStyle(.roundedBorder)
        }
    }

    @ViewBuilder
    func labeledDoubleField(_ title: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(title, value: value, format: .number.precision(.fractionLength(1...2)))
                .textFieldStyle(.roundedBorder)
        }
    }

    func statusCapsule(title: String, color: Color) -> some View {
        Text(title)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(color.opacity(0.12), in: Capsule())
            .foregroundStyle(color)
    }
}
