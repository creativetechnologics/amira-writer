import AppKit
import Foundation
import SwiftUI
import WebKit

/// 3D map preview hosted inside the Amira Writer app.
///
/// Strategy: reuse the existing `Scripts/3d-map-pipeline/` three.js viewer via
/// WKWebView. Prefers the local Python dev server at `http://127.0.0.1:8787`
/// (started by `run_all.sh`) so iteration is instant — reloading the pipeline
/// is reflected on next page reload. Falls back to a direct `file://` URL if
/// the server isn't up, so the view still works offline.
///
/// Future migration: swap WKWebView for a native SceneKit renderer that
/// consumes the same `scene.json`/`heightmap.png`/`texture.jpg` produced by
/// `04_compose_scene.py`.
@available(macOS 26.0, *)
struct PlacesMap3DView: View {
    @State private var probe: ProbeResult = .probing
    @State private var probedURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("3D Map").font(.title2).fontWeight(.semibold)
                statusPill
                Spacer()
                Button("Reload") { Task { await probeAndLoad() } }
                    .controlSize(.small)
                if let url = probedURL {
                    Button("Open in browser") {
                        NSWorkspace.shared.open(url)
                    }
                    .controlSize(.small)
                }
            }
            Text(hint).font(.caption).foregroundStyle(.secondary)
            Group {
                if case .ready(let url) = probe {
                    MapWebView(url: url)
                        .frame(minHeight: 560)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(.white.opacity(0.08)))
                } else {
                    VStack(spacing: 8) {
                        ProgressView()
                        if case .missing(let msg) = probe {
                            Text(msg).font(.callout).foregroundStyle(.red)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 560)
                }
            }
        }
        .task { await probeAndLoad() }
    }

    private var statusPill: some View {
        let (text, color): (String, Color) = {
            switch probe {
            case .probing: return ("probing…", .secondary)
            case .ready: return ("live", .green)
            case .missing: return ("no scene", .red)
            }
        }()
        return Text(text)
            .font(.caption2).fontWeight(.semibold)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .foregroundStyle(color)
            .background(color.opacity(0.15))
            .clipShape(Capsule())
    }

    private var hint: String {
        switch probe {
        case .probing: return "Checking the 3D-map-pipeline dev server…"
        case .ready(let url):
            if url.scheme == "http" { return "Connected to local dev server — edits to the pipeline viewer are hot-reloadable." }
            return "Loaded static pipeline output."
        case .missing(let msg): return msg
        }
    }

    private func probeAndLoad() async {
        probe = .probing
        let serverURL = URL(string: "http://127.0.0.1:8787/")!
        if await PlacesMap3DView.httpReachable(serverURL) {
            probedURL = serverURL
            probe = .ready(serverURL)
            return
        }
        if let fileURL = PlacesMap3DView.staticFallbackURL() {
            probedURL = fileURL
            probe = .ready(fileURL)
            return
        }
        probe = .missing("No dev server on :8787 and no pipeline output found. Run Scripts/3d-map-pipeline/run_all.sh.")
    }

    private static func httpReachable(_ url: URL) async -> Bool {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 1.2
        do {
            let (_, resp) = try await URLSession.shared.data(for: request)
            if let http = resp as? HTTPURLResponse, (200...399).contains(http.statusCode) { return true }
        } catch { /* fall through */ }
        return false
    }

    private static func staticFallbackURL() -> URL? {
        // 1. Developer override: point at a local viewer/ dir while iterating.
        if let override = ProcessInfo.processInfo.environment["AMIRA_MAP3D_DIR"], !override.isEmpty {
            let u = URL(fileURLWithPath: override).appendingPathComponent("index.html")
            if FileManager.default.fileExists(atPath: u.path) { return u }
        }
        // 2. App-bundled viewer (embedded by Scripts/build-app.sh). This is
        //    the default offline path on any installed machine.
        if let resourceURL = Bundle.main.resourceURL {
            let bundled = resourceURL
                .appendingPathComponent("map3d-viewer")
                .appendingPathComponent("index.html")
            if FileManager.default.fileExists(atPath: bundled.path) { return bundled }
        }
        // 3. Legacy: direct path on the build server. No-op elsewhere.
        let candidates = [
            "/Volumes/Storage VIII/Programming/Amira Writer/Scripts/3d-map-pipeline/viewer/index.html",
        ]
        for path in candidates {
            if FileManager.default.fileExists(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    enum ProbeResult: Equatable {
        case probing
        case ready(URL)
        case missing(String)
    }
}

@available(macOS 26.0, *)
private struct MapWebView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        let web = WKWebView(frame: .zero, configuration: config)
        web.setValue(false, forKey: "drawsBackground")
        web.allowsBackForwardNavigationGestures = false
        load(into: web)
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        if web.url != url { load(into: web) }
    }

    private func load(into web: WKWebView) {
        if url.scheme == "file" {
            // Allow the viewer to read its sibling assets (scene.json, etc.).
            web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            web.load(URLRequest(url: url))
        }
    }
}
