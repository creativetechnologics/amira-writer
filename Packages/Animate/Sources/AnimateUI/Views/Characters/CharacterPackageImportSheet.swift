import SwiftUI

@available(macOS 26.0, *)
struct CharacterPackageImportPreview: Identifiable {
    let id = UUID()
    let bundle: CharacterPackageImportBundle
    let importPlan: CharacterPackageImportPlan?
    let importErrorMessage: String?
}

@available(macOS 26.0, *)
struct CharacterPackageImportSheet: View {
    let preview: CharacterPackageImportPreview
    let onImport: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Import Character Package")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text("Review the package manifest, validation results, and staging target before importing.")
                    .foregroundStyle(.secondary)
            }

            GroupBox("Package Summary") {
                VStack(alignment: .leading, spacing: 8) {
                    summaryRow("Display Name", preview.bundle.manifest.displayName)
                    summaryRow("Slug", preview.bundle.manifest.slug)
                    summaryRow("Type", preview.bundle.manifest.packageKind.rawValue.capitalized)
                    summaryRow("Assets", "\(preview.bundle.manifest.assets.count)")
                    summaryRow("Blueprints", "\(preview.bundle.manifest.blueprints.count)")
                    if let importPlan = preview.importPlan {
                        summaryRow("Target Path", importPlan.stagingDirectoryURL.path)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox(validationTitle) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if preview.bundle.validationReport.issues.isEmpty {
                            Text("No validation issues were found.")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(preview.bundle.validationReport.issues) { issue in
                                VStack(alignment: .leading, spacing: 4) {
                                    Label(
                                        issue.severity.rawValue.capitalized,
                                        systemImage: issue.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill"
                                    )
                                    .foregroundStyle(issue.severity == .error ? .red : .yellow)
                                    .font(.caption.weight(.semibold))
                                    Text(issue.message)
                                        .font(.callout)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 2)
                            }
                        }

                        if let importErrorMessage = preview.importErrorMessage {
                            Divider()
                            Label("Import Plan Error", systemImage: "xmark.circle.fill")
                                .foregroundStyle(.red)
                                .font(.caption.weight(.semibold))
                            Text(importErrorMessage)
                                .font(.callout)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 160, maxHeight: 260)
            }

            Spacer(minLength: 0)

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .buttonStyle(.bordered)

                Spacer()

                Button("Import Package") {
                    onImport()
                }
                .buttonStyle(.borderedProminent)
                .disabled(preview.importPlan == nil || !preview.bundle.validationReport.isValid)
            }
        }
        .padding(24)
        .frame(minWidth: 620, minHeight: 480)
    }

    private var validationTitle: String {
        let warnings = preview.bundle.validationReport.issues.filter { $0.severity == .warning }.count
        let errors = preview.bundle.validationReport.issues.filter { $0.severity == .error }.count
        return "Validation (\(errors) errors, \(warnings) warnings)"
    }

    @ViewBuilder
    private func summaryRow(_ label: String, _ value: String) -> some View {
        LabeledContent(label) {
            Text(value)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .font(.callout)
    }
}
