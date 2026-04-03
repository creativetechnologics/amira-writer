import SwiftUI
import ProjectKit
import UniformTypeIdentifiers

@available(macOS 26.0, *)
public struct PropsWorkspace: View {
    @ObservedObject private var controller: AnimateWorkspaceController

    public init(controller: AnimateWorkspaceController) {
        _controller = ObservedObject(wrappedValue: controller)
    }

    public var body: some View {
        ZStack {
            PropsWorkspaceContent(store: controller.store)
                .allowsHitTesting(!(controller.isLoadingProject || controller.isSelectionRestorePending))

            if controller.isLoadingProject || controller.isSelectionRestorePending {
                AnimateWorkspaceLoadOverlay(
                    title: controller.store.owpURL == nil ? "Opening Props" : "Refreshing Props",
                    message: controller.loadStatusMessage
                )
            }
        }
    }
}

@available(macOS 26.0, *)
private struct PropsWorkspaceContent: View {
    @Bindable var store: AnimateStore
    @State private var animateWorkspaceState = AnimateWorkspaceState()
    @State private var importConfirmation: String?

    @AppStorage("novotro.props.sidebarVisible") private var sidebarVisible = true
    @AppStorage("novotro.props.sidebar.width") private var sidebarWidth: Double = OperaChromeSidebarMetrics.defaultWidth
    @AppStorage("novotro.props.inspector.visible") private var inspectorVisible = true
    @AppStorage("novotro.props.inspector.width") private var inspectorWidth: Double = 320

    private static let supportedExtensions: Set<String> = ["usdz", "glb", "obj", "png", "jpg", "jpeg"]

    var body: some View {
        Group {
            if store.owpURL == nil {
                OperaChromeEmptyState(
                    systemImage: "shippingbox",
                    title: "Open A Project",
                    message: "Use File > Open Project to pick a local Amira project folder from disk."
                )
            } else {
                workspaceBody
            }
        }
        .overlay {
            if let message = importConfirmation {
                importConfirmationOverlay(message: message)
            }
        }
    }

    private var workspaceBody: some View {
        HStack(spacing: 0) {
            if sidebarVisible {
                OperaChromeFlatPane(
                    headerPadding: OperaChromeSidebarMetrics.headerPadding
                ) {
                    OperaChromePaneHeader(
                        eyebrow: "PROPS",
                        title: "Props",
                        subtitle: ""
                    ) {
                        Button {
                            importModelsFromPicker()
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(OperaChromeTheme.textSecondary)
                                .frame(width: 22, height: 22)
                                .background(
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .fill(OperaChromeTheme.raisedBackground.opacity(0.5))
                                )
                        }
                        .buttonStyle(.plain)
                        .help("Import Model")
                    }
                } content: {
                    propsSidebar
                }
                .frame(width: sidebarWidth)

                OperaChromeSplitHandle(
                    onDragChanged: resizeSidebar,
                    onDragEnded: { }
                )
            }

            OperaChromeFlatPane {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("PROPS")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .tracking(1.2)
                            .foregroundStyle(OperaChromeTheme.textTertiary)
                        Text(store.owpURL?.deletingPathExtension().lastPathComponent ?? "Untitled Opera")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(OperaChromeTheme.textPrimary)
                            .lineLimit(1)
                        Text("Scene objects, vehicles, and interactive props")
                            .font(.system(size: 11))
                            .foregroundStyle(OperaChromeTheme.textSecondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 10)
                }
            } content: {
                propsCenterPanel
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if inspectorVisible {
                OperaChromeSplitHandle(
                    onDragChanged: resizeInspector,
                    onDragEnded: { }
                )

                OperaChromeFlatPane {
                    OperaChromePaneHeader(
                        eyebrow: "DETAILS",
                        title: "Inspector",
                        subtitle: "Props"
                    ) {
                        OperaChromeActionButton(systemImage: "xmark") {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                inspectorVisible = false
                            }
                        }
                    }
                } content: {
                    InspectorView(
                        store: store,
                        currentPage: .props,
                        animateWorkspaceState: animateWorkspaceState
                    )
                }
                .frame(width: inspectorWidth)
            }
        }
        .background(OperaChromeTheme.workspaceBackground)
    }

    // MARK: - Sidebar

    private var propsSidebar: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 8) {
                Image(systemName: "shippingbox")
                    .font(.system(size: 28))
                    .foregroundStyle(OperaChromeTheme.textTertiary)
                Text("Props will appear here")
                    .font(.system(size: 12))
                    .foregroundStyle(OperaChromeTheme.textSecondary)
                Text("Import models or wait for the libretto extraction agent to discover props in the script.")
                    .font(.system(size: 11))
                    .foregroundStyle(OperaChromeTheme.textTertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Center Panel

    private var propsCenterPanel: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 16) {
                Image(systemName: "square.and.arrow.down.on.square")
                    .font(.system(size: 36))
                    .foregroundStyle(OperaChromeTheme.textTertiary)
                Text("Select a prop to view details")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(OperaChromeTheme.textSecondary)
                Text("Or drag and drop model files here to import them.")
                    .font(.system(size: 12))
                    .foregroundStyle(OperaChromeTheme.textTertiary)

                Button {
                    importModelsFromPicker()
                } label: {
                    Label("Import Model", systemImage: "plus.circle")
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color(red: 0.78, green: 0.62, blue: 0.38).opacity(0.18))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(Color(red: 0.78, green: 0.62, blue: 0.38).opacity(0.3), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color(red: 0.78, green: 0.62, blue: 0.38))
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers)
            return true
        }
    }

    // MARK: - Import

    private func importModelsFromPicker() {
        guard let projectURL = store.owpURL else { return }

        let panel = NSOpenPanel()
        panel.title = "Import Prop Model"
        panel.message = "Choose model or image files to import as props."
        panel.prompt = "Import"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [
            UTType(filenameExtension: "usdz") ?? .data,
            UTType(filenameExtension: "glb") ?? .data,
            UTType(filenameExtension: "obj") ?? .data,
            .png,
            .jpeg
        ]

        guard panel.runModal() == .OK else { return }
        copyFilesToObjectsDirectory(urls: panel.urls, projectURL: projectURL)
    }

    private func handleDrop(_ providers: [NSItemProvider]) {
        guard let projectURL = store.owpURL else { return }

        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                let ext = url.pathExtension.lowercased()
                guard Self.supportedExtensions.contains(ext) else { return }
                DispatchQueue.main.async {
                    copyFilesToObjectsDirectory(urls: [url], projectURL: projectURL)
                }
            }
        }
    }

    private func copyFilesToObjectsDirectory(urls: [URL], projectURL: URL) {
        let objectsDir = projectURL.appendingPathComponent("Animate/objects", isDirectory: true)
        let fm = FileManager.default

        do {
            if !fm.fileExists(atPath: objectsDir.path) {
                try fm.createDirectory(at: objectsDir, withIntermediateDirectories: true)
            }

            var importedNames: [String] = []
            for url in urls {
                let destination = objectsDir.appendingPathComponent(url.lastPathComponent)
                if fm.fileExists(atPath: destination.path) {
                    try fm.removeItem(at: destination)
                }
                try fm.copyItem(at: url, to: destination)
                importedNames.append(url.lastPathComponent)
            }

            let summary = importedNames.count == 1
                ? "Imported \(importedNames[0])"
                : "Imported \(importedNames.count) files"
            importConfirmation = summary

            Task {
                try? await Task.sleep(for: .seconds(2.5))
                await MainActor.run {
                    if importConfirmation == summary {
                        importConfirmation = nil
                    }
                }
            }
        } catch {
            importConfirmation = "Import failed: \(error.localizedDescription)"
            Task {
                try? await Task.sleep(for: .seconds(3))
                await MainActor.run {
                    importConfirmation = nil
                }
            }
        }
    }

    // MARK: - Import Confirmation Overlay

    private func importConfirmationOverlay(message: String) -> some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                HStack(spacing: 8) {
                    Image(systemName: message.hasPrefix("Import failed") ? "exclamationmark.triangle" : "checkmark.circle")
                        .foregroundStyle(message.hasPrefix("Import failed") ? .red : .green)
                    Text(message)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(OperaChromeTheme.textPrimary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(OperaChromeTheme.raisedBackground)
                        .shadow(color: .black.opacity(0.3), radius: 8, y: 2)
                )
                Spacer()
            }
            .padding(.bottom, 24)
        }
        .allowsHitTesting(false)
        .transition(.opacity)
        .animation(.easeInOut(duration: 0.3), value: importConfirmation)
    }

    // MARK: - Resize

    private func resizeSidebar(_ delta: CGFloat) {
        sidebarWidth = min(
            max(sidebarWidth + Double(delta), OperaChromeSidebarMetrics.minWidth),
            OperaChromeSidebarMetrics.maxWidth
        )
    }

    private func resizeInspector(_ delta: CGFloat) {
        inspectorWidth = min(
            max(inspectorWidth - Double(delta), 250),
            600
        )
    }
}
