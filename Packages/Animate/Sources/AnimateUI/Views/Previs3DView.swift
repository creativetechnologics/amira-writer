import AppKit
import Foundation
import SwiftUI
import WebKit
import os.log

@available(macOS 26.0, *)
struct Previs3DView: View {
    var sceneJSON: String
    var characterGLBPaths: [(slug: String, path: String)]
    var onCaptureResult: ((String, Data) -> Void)?
    var onCaptureError: ((String) -> Void)?

    @State private var viewerURL: URL?
    @State private var missingMessage: String?
    @State private var reloadToken: Int = 0
    @State private var webCoordinator: PrevisWebView.Coordinator?

    var body: some View {
        ZStack {
            if let url = viewerURL {
                PrevisWebView(
                    url: url,
                    sceneJSON: sceneJSON,
                    characterGLBPaths: characterGLBPaths,
                    onCaptureResult: { label, data in
                        onCaptureResult?(label, data)
                    },
                    onCaptureError: { msg in
                        onCaptureError?(msg)
                    },
                    webCoordinator: $webCoordinator
                )
                .id(reloadToken)
            } else if let msg = missingMessage {
                VStack(spacing: 8) {
                    Image(systemName: "cube").font(.system(size: 32)).foregroundStyle(.tertiary)
                    Text(msg).foregroundStyle(.secondary).font(.callout)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView("Loading 3D viewer...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            resolveViewer()
        }
        .onChange(of: sceneJSON) { _, _ in
            reloadToken += 1
        }
        .onChange(of: characterGLBPaths.count) { _, _ in
            reloadToken += 1
        }
    }

    private func resolveViewer() {
        viewerURL = nil
        missingMessage = nil
        if let url = PrevisResourceLocator.indexURL() {
            viewerURL = url
        } else {
            missingMessage = "Previs viewer not found. Ensure previs-web/ is bundled in the app Resources."
        }
    }
}

@available(macOS 26.0, *)
private enum PrevisResourceLocator {
    static func indexURL() -> URL? {
        let sourceTree = URL(fileURLWithPath: "/Volumes/Storage VIII/Programming/Amira Writer/Packages/Animate/Sources/AnimateUI/Resources/previs-web")
        if let idx = indexURL(in: sourceTree) { return idx }
        if let resourceURL = Bundle.main.resourceURL {
            let bundled = resourceURL.appendingPathComponent("previs-web")
            if let idx = indexURL(in: bundled) { return idx }
        }
        return nil
    }

    private static func indexURL(in dir: URL) -> URL? {
        let idx = dir.appendingPathComponent("index.html")
        return FileManager.default.fileExists(atPath: idx.path) ? idx : nil
    }
}

// MARK: - WKWebView Wrapper

@available(macOS 26.0, *)
private struct PrevisWebView: NSViewRepresentable {
    let url: URL
    let sceneJSON: String
    let characterGLBPaths: [(slug: String, path: String)]
    let onCaptureResult: (String, Data) -> Void
    let onCaptureError: (String) -> Void
    @Binding var webCoordinator: Coordinator?

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")

        let userContent = config.userContentController
        let coordinator = context.coordinator
        userContent.add(coordinator, name: "previsLog")
        userContent.add(coordinator, name: "previsCapture")

        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = coordinator
        web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())

        DispatchQueue.main.async {
            self.webCoordinator = coordinator
        }

        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        // Intentionally empty. Reload triggered by .id(hash) recreation.
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let parent: PrevisWebView

        init(parent: PrevisWebView) {
            self.parent = parent
        }

        func webView(_ web: WKWebView, didFinish navigation: WKNavigation!) {
            let sceneJSON = parent.sceneJSON
            let glbPaths = parent.characterGLBPaths

            web.evaluateJavaScript("console.log('[previs] page loaded')")

            for entry in glbPaths {
                let slug = entry.slug
                let path = entry.path
                let slugJSON = String(data: (try? JSONEncoder().encode([slug])) ?? Data(), encoding: .utf8)?.dropFirst().dropLast() ?? "\"\(slug)\""
                let pathJSON = String(data: (try? JSONEncoder().encode([path])) ?? Data(), encoding: .utf8)?.dropFirst().dropLast() ?? "\"\(path)\""
                web.evaluateJavaScript("loadCharacter(\(slugJSON), \(pathJSON))")
            }

            if !sceneJSON.isEmpty {
                let sceneJSONValue = String(data: (try? JSONEncoder().encode([sceneJSON])) ?? Data(), encoding: .utf8)?.dropFirst().dropLast() ?? "\"\(sceneJSON)\""
                web.evaluateJavaScript("try { window.__previs_state.sceneData = JSON.parse(\(sceneJSONValue)); } catch(e) { console.log('[previs] scene parse error:', e); }")
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            parent.onCaptureError("Viewer load failed: \(error.localizedDescription)")
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            switch message.name {
            case "previsLog":
                if let body = message.body as? String {
                    print("[previs:log]", body)
                }
            case "previsCapture":
                guard let dict = message.body as? [String: Any],
                      let label = dict["label"] as? String,
                      let dataURL = dict["dataURL"] as? String,
                      let data = Data(base64Encoded: dataURL.replacingOccurrences(of: "data:image/jpeg;base64,", with: ""))
                else {
                    parent.onCaptureError("Invalid capture payload")
                    return
                }
                parent.onCaptureResult(label, data)
            default:
                break
            }
        }
    }
}
