import AppKit
import SwiftUI

@available(macOS 26.0, *)
struct CharacterPackageCardView: View {
    let package: InstalledCharacterPackage
    let previewURL: URL?
    let isActive: Bool
    let onSetActive: () -> Void
    let onDelete: (() -> Void)?

    private var errorCount: Int {
        package.validationReport.issues.filter { $0.severity == .error }.count
    }

    private var warningCount: Int {
        package.validationReport.issues.filter { $0.severity == .warning }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                previewThumbnail

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(package.manifest.displayName)
                            .font(.callout.weight(.semibold))

                        if isActive {
                            capsuleLabel(
                                title: "Active on Canvas",
                                color: .blue,
                                systemImage: "play.circle.fill"
                            )
                        }
                    }

                    HStack(spacing: 8) {
                        capsuleLabel(
                            title: package.validationReport.isValid ? "Ready" : "Needs Attention",
                            color: package.validationReport.isValid ? .green : .orange,
                            systemImage: package.validationReport.isValid ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                        )
                        capsuleLabel(
                            title: package.manifest.packageKind.rawValue.capitalized,
                            color: .secondary,
                            systemImage: "shippingbox"
                        )
                    }

                    Text("\(package.manifest.assets.count) assets, \(package.manifest.blueprints.count) blueprints")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text("Errors: \(errorCount)  Warnings: \(warningCount)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(errorCount > 0 ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.tertiary))

                    if let importedAt = package.importedAt {
                        Text("Imported \(importedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }

                Spacer()
            }

            debugPathRow(title: "Package", url: package.packageDirectoryURL)
            debugPathRow(title: "Manifest", url: package.manifestURL)

            HStack(spacing: 8) {
                if isActive {
                    Button("Active") { }
                        .buttonStyle(.borderedProminent)
                        .disabled(true)
                } else {
                    Button("Set Active") {
                        onSetActive()
                    }
                    .buttonStyle(.borderedProminent)
                }

                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([package.packageDirectoryURL])
                }
                .buttonStyle(.bordered)

                Button("Copy Package Path") {
                    copyToPasteboard(package.packageDirectoryURL.path)
                }
                .buttonStyle(.bordered)

                if let onDelete {
                    Button("Delete", role: .destructive) {
                        onDelete()
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 12)
                .fill(.quaternary.opacity(0.35))
        }
    }

    @ViewBuilder
    private var previewThumbnail: some View {
        if let previewURL {
            AsyncResolvedImageView(path: previewURL.path, maxPixelSize: 448, contentMode: .fill)
                .frame(width: 112, height: 112)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        } else {
            RoundedRectangle(cornerRadius: 10)
                .fill(.quaternary)
                .frame(width: 112, height: 112)
                .overlay {
                    Image(systemName: "photo")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                }
        }
    }

    private func capsuleLabel(title: String, color: Color, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(color.opacity(0.12), in: Capsule())
            .foregroundStyle(color)
    }

    private func debugPathRow(title: String, url: URL) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .leading)

            Text(url.path)
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }

    private func copyToPasteboard(_ value: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
    }
}
