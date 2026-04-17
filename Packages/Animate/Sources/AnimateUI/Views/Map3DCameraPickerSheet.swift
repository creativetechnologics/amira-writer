import AppKit
import Foundation
import SwiftUI
import WebKit

/// Modal sheet that hosts the 3D map viewer for picking a camera angle to
/// attach to a Gemini generation draft. When the user clicks "💾 Save camera
/// for draft" inside the viewer, the JS posts the camera metadata via
/// `webkit.messageHandlers.amiraMapCamera`; the coordinator decodes it into
/// a `MapViewPreset` and dismisses the sheet.
@available(macOS 26.0, *)
struct Map3DCameraPickerSheet: View {
    let initialPreset: MapViewPreset?
    let onSave: (MapViewPreset) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Pick a Map View")
                        .font(.title3).fontWeight(.semibold)
                    Text("Orbit to the angle you want, then click \"💾 Save camera for draft\" in the viewer's left panel.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(14)

            Divider()

            Map3DPickerWebView(onCameraSave: onSave)
                .frame(minWidth: 720, idealWidth: 1160, maxWidth: .infinity, minHeight: 560, idealHeight: 760, maxHeight: .infinity)
        }
        .frame(minWidth: 900, idealWidth: 1160, maxWidth: .infinity, minHeight: 640, idealHeight: 780, maxHeight: .infinity)
        .background(
            ResizableSheetWindowAccessor(
                minSize: NSSize(width: 900, height: 640),
                initialSize: NSSize(width: 1160, height: 780)
            )
        )
    }
}

@available(macOS 26.0, *)
private struct Map3DPickerWebView: NSViewRepresentable {
    let onCameraSave: (MapViewPreset) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCameraSave: onCameraSave)
    }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        let onCameraSave: (MapViewPreset) -> Void
        init(onCameraSave: @escaping (MapViewPreset) -> Void) {
            self.onCameraSave = onCameraSave
        }
        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == "amiraMapCamera" else { return }
            guard let preset = MapViewPreset.decode(from: message.body) else {
                print("[Map3DCameraPicker] received bad payload: \(message.body)")
                return
            }
            Task { @MainActor in self.onCameraSave(preset) }
        }
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "amiraMapCamera")
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        // ES-module imports under `file://` fail with a CORS error in
        // WKWebView without these. See PlacesMap3DView.swift for the full
        // write-up — same viewer, same requirement.
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        config.setValue(true, forKey: "allowUniversalAccessFromFileURLs")
        let web = WKWebView(frame: .zero, configuration: config)
        // Do NOT set drawsBackground=false — the viewer's body background
        // must paint during load, otherwise the picker appears solid black.
        if let url = Self.resolveViewerURL() {
            if url.scheme == "file" {
                web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
            } else {
                web.load(URLRequest(url: url))
            }
        }
        return web
    }

    func updateNSView(_: WKWebView, context _: Context) {}

    /// Prefer the dev server, then the app-bundled viewer, then the
    /// server-side source path (for developer machines).
    static func resolveViewerURL() -> URL? {
        if let resourceURL = Bundle.main.resourceURL {
            let bundled = resourceURL
                .appendingPathComponent("map3d-viewer")
                .appendingPathComponent("index.html")
            if FileManager.default.fileExists(atPath: bundled.path) { return bundled }
        }
        let candidates = [
            "/Volumes/Storage VIII/Programming/Amira Writer/Scripts/3d-map-pipeline/viewer/index.html"
        ]
        for path in candidates {
            if FileManager.default.fileExists(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }
}
