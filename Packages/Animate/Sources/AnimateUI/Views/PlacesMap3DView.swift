import AppKit
import Foundation
import SwiftUI
import WebKit
import os.log

/// Full-pane 3D map viewer for the Places → 3D Map tab.
///
/// Hosts the local three.js scene at
/// `Scripts/3d-map-pipeline/viewer/index.html` (copied into the app bundle as
/// `Contents/Resources/map3d-viewer/` by `Scripts/build-app.sh`). The viewer
/// itself brings the terrain, texture drape, buildings, roads, water,
/// OrbitControls mouse interaction, and HUD.
///
/// History (for context — do NOT revert without good reason):
///   1. WKWebView + three.js (CDN import map) — black canvas under `file://`
///      because WKWebView can't reach unpkg.com and importmaps silently fail
///      with no error. Fixed 2026-04-15 by vendoring three.js locally.
///   2. SCNView — rendered nothing under SwiftUI on macOS 26 Tahoe.
///   3. Native SwiftUI `Image` + gestures — worked but was 2D only, no
///      terrain/lighting/layers. Gary wanted parity with the dev-server
///      preview.
///   4. **Current:** WKWebView loading the vendored viewer (parity with
///      `Map3DCameraPickerSheet`, which has been working reliably).
///
/// Requirements / gotchas:
/// - Do NOT set `drawsBackground = false` on the WKWebView — the viewer's
///   body background has to paint during load or the whole surface reads as
///   solid black.
/// - `loadFileURL(_:, allowingReadAccessTo:)` MUST point at the viewer
///   directory so `scene.json`, `heightmap.png`, `texture.jpg`, and the
///   vendored `three/*.js` files are reachable as sibling `file://` URLs.
/// - `crossOrigin = ''` on TextureLoader and Image — already set in the
///   viewer's `main.js`; WKWebView hangs with `anonymous`.
/// - `updateNSView` MUST stay empty. Comparing `web.url != url` there kicks
///   off an infinite reload loop because WebKit only publishes `.url` *after*
///   a navigation commits, so `web.url` is momentarily `nil`/stale right
///   after `loadFileURL` is called and the comparison fires a second load
///   before the first finishes. Reloads happen via `.id(reloadToken)` on the
///   parent view, which tears the NSView down and runs `makeNSView` again.
/// - JS bridge ("map3dLog") forwards `console.*` + `window.onerror` into the
///   Debug pane so future black-canvas regressions can be diagnosed without
///   attaching Safari's Web Inspector.
@available(macOS 26.0, *)
struct PlacesMap3DView: View {
    var onCaptureDraft: ((MapCaptureResult) -> Void)? = nil
    var onCaptureError: ((String) -> Void)? = nil

    @State private var viewerURL: URL?
    @State private var missingMessage: String?
    @State private var reloadToken: Int = 0
    // Default-open while we're debugging the black-canvas regression. Once
    // the viewer loads cleanly in the wild, flip this back to `false`.
    @State private var showDiagnostics: Bool = true
    @State private var isCapturing: Bool = false
    @State private var webCoordinator: Map3DWebView.Coordinator? = nil
    @StateObject private var diagnostics = Map3DDiagnostics()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            headerRow
            Text(hint).font(.caption).foregroundStyle(.secondary)
            if showDiagnostics { diagnosticsPane }
            mapSurface
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { resolveViewer() }
    }

    /// Payload delivered to the parent when a capture succeeds. Parent owns
    /// the temp PNG file and is responsible for deleting it on cancel.
    struct MapCaptureResult {
        let captureImagePath: String   // absolute path to the temp PNG
        let aspectRatioHint: String    // "16:9" or "1:1"
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Map").font(.title2).fontWeight(.semibold)
            statusPill
            Spacer()
            Button {
                showDiagnostics.toggle()
            } label: {
                Label(
                    diagnostics.hasErrors ? "Debug (!)" : "Debug",
                    systemImage: diagnostics.hasErrors ? "exclamationmark.triangle.fill" : "ladybug"
                )
            }
            .controlSize(.small)
            .tint(diagnostics.hasErrors ? .red : .secondary)

            Button {
                performCapture()
            } label: {
                if isCapturing {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Capture", systemImage: "camera.fill")
                }
            }
            .controlSize(.small)
            .disabled(isCapturing || viewerURL == nil || onCaptureDraft == nil)
            .help("Snapshot the current viewport and open the Gemini preflight")

            if let url = viewerURL {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([url.deletingLastPathComponent()])
                }
                .controlSize(.small)
            }
            Button("Reload") {
                diagnostics.reset()
                reloadToken &+= 1
                resolveViewer()
            }
            .controlSize(.small)
        }
    }

    private var statusPill: some View {
        let (text, color): (String, Color) = {
            if diagnostics.hasErrors { return ("error", .red) }
            if viewerURL != nil { return ("3D viewer", .green) }
            if missingMessage != nil { return ("no map", .red) }
            return ("loading…", .secondary)
        }()
        return Text(text)
            .font(.caption2).fontWeight(.semibold)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .foregroundStyle(color)
            .background(color.opacity(0.15))
            .clipShape(Capsule())
    }

    private var hint: String {
        if viewerURL != nil {
            return "Left-drag: orbit · right-drag: pan · scroll: zoom · HUD: toggle layers, reset view, grounding card."
        }
        if let message = missingMessage {
            return message
        }
        return "Locating 3D map viewer assets…"
    }

    // MARK: - Diagnostics pane

    /// Single selectable `Text` block instead of a `ForEach`. SwiftUI's
    /// `textSelection` is scoped per-Text, so per-entry Text views can only
    /// be copied one line at a time — that was useless when debugging
    /// remotely. Joining everything into one string means ⌘A + ⌘C works.
    private var diagnosticsPane: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("3D map diagnostics")
                    .font(.caption).fontWeight(.semibold)
                Text("\(diagnostics.log.count) entries")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("Copy") {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(diagnostics.joinedText, forType: .string)
                }
                .controlSize(.small)
                .disabled(diagnostics.log.isEmpty)

                Button("Save to Desktop…") {
                    if let url = diagnostics.saveToDesktop() {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
                .controlSize(.small)
                .disabled(diagnostics.log.isEmpty)

                Button("Clear") { diagnostics.reset() }
                    .controlSize(.small)
                    .disabled(diagnostics.log.isEmpty)
            }
            .padding(.horizontal, 2)

            ScrollView {
                Text(diagnostics.log.isEmpty
                     ? "(no messages yet — click Reload to capture startup)"
                     : diagnostics.joinedText)
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(maxHeight: 220)
            .background(Color.black.opacity(0.65))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }

    // MARK: - Map surface

    private var mapSurface: some View {
        ZStack {
            if let url = viewerURL {
                Map3DWebView(
                    url: url,
                    diagnostics: diagnostics,
                    coordinatorSink: { coord in
                        Task { @MainActor in webCoordinator = coord }
                    }
                )
                    .id(reloadToken)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(.white.opacity(0.08))
                    )
            } else if let message = missingMessage {
                VStack(spacing: 6) {
                    Image(systemName: "map")
                        .font(.title)
                        .foregroundStyle(.tertiary)
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Viewer resolution

    private func resolveViewer() {
        viewerURL = nil
        missingMessage = nil
        diagnostics.append("mirror log: \(diagnostics.mirrorPath)", level: .info)
        if let url = Map3DResourceLocator.indexURL() {
            viewerURL = url
            diagnostics.append("viewer url: \(url.path)", level: .info)
        } else {
            let msg = "3D map viewer not found. Run Scripts/3d-map-pipeline/run_all.sh to (re)generate the pipeline assets."
            missingMessage = msg
            diagnostics.append(msg, level: .error)
        }
    }

    private func performCapture() {
        guard let coordinator = webCoordinator else {
            onCaptureError?("3D map viewport isn't ready yet.")
            return
        }
        isCapturing = true
        Task { @MainActor in
            defer { isCapturing = false }
            guard let image = await coordinator.captureSnapshot() else {
                onCaptureError?("Viewport capture failed.")
                return
            }
            guard let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let pngData = rep.representation(using: .png, properties: [:]) else {
                onCaptureError?("Failed to encode snapshot as PNG.")
                return
            }
            let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("map3d-capture-\(UUID().uuidString).png")
            do {
                try pngData.write(to: tempURL)
            } catch {
                onCaptureError?("Could not write snapshot to temp: \(error.localizedDescription)")
                return
            }
            let aspect: String = {
                let w = image.size.width
                let h = image.size.height
                guard w > 0, h > 0 else { return "16:9" }
                let ratio = w / h
                return abs(ratio - 1.0) < 0.15 ? "1:1" : "16:9"
            }()
            onCaptureDraft?(MapCaptureResult(captureImagePath: tempURL.path, aspectRatioHint: aspect))
        }
    }
}

// MARK: - Diagnostics store

@MainActor
final class Map3DDiagnostics: ObservableObject {
    enum Level: String {
        case debug, info, warn, error
    }

    struct Entry: Identifiable, Sendable {
        let id = UUID()
        let text: String
        let level: Level
        var color: Color {
            switch level {
            case .error: return .red
            case .warn: return .yellow
            case .info: return .green
            case .debug: return .white.opacity(0.85)
            }
        }
    }

    @Published private(set) var log: [Entry] = []
    @Published private(set) var hasErrors: Bool = false

    private static let osLog = Logger(subsystem: "com.creativetechnologics.amira.animate", category: "map3d")

    /// Mirror file that tail-friendly tools (and remote agents) can read
    /// without needing UI access. Overwritten on each append. `nil` until
    /// first mirror attempt so the computed path can be logged at boot.
    private lazy var mirrorURL: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("AmiraWriter", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("map3d-diagnostics.log")
    }()

    var joinedText: String {
        log.map(\.text).joined(separator: "\n")
    }

    func append(_ text: String, level: Level) {
        let stamp = Date().formatted(date: .omitted, time: .standard)
        let line = "[\(stamp)] \(level.rawValue): \(text)"
        log.append(Entry(text: line, level: level))
        if log.count > 500 {
            log.removeFirst(log.count - 500)
        }
        if level == .error { hasErrors = true }
        switch level {
        case .error: Self.osLog.error("\(text, privacy: .public)")
        case .warn:  Self.osLog.warning("\(text, privacy: .public)")
        case .info:  Self.osLog.info("\(text, privacy: .public)")
        case .debug: Self.osLog.debug("\(text, privacy: .public)")
        }
        // Mirror to disk so we can tail / cat from the terminal without
        // depending on clipboard, os_log, or SwiftUI text selection.
        mirrorToDiskSilently()
    }

    func reset() {
        log.removeAll()
        hasErrors = false
        mirrorToDiskSilently()
    }

    /// Write the current log to `~/Desktop/map3d-diagnostics-<ts>.log` and
    /// return the URL. Used by the Save to Desktop… button.
    func saveToDesktop() -> URL? {
        let fm = FileManager.default
        let desktop = fm.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Desktop")
        let ts = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let target = desktop.appendingPathComponent("map3d-diagnostics-\(ts).log")
        do {
            try joinedText.write(to: target, atomically: true, encoding: .utf8)
            Self.osLog.info("diagnostics saved → \(target.path, privacy: .public)")
            return target
        } catch {
            Self.osLog.error("save failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Path of the auto-mirrored log file. Safe for `cat` / `tail -f`.
    var mirrorPath: String { mirrorURL.path }

    private func mirrorToDiskSilently() {
        // Do not call `append` from here — would recurse forever.
        do {
            try joinedText.write(to: mirrorURL, atomically: true, encoding: .utf8)
        } catch {
            Self.osLog.error("mirror write failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

// MARK: - WebKit host

@available(macOS 26.0, *)
struct Map3DWebView: NSViewRepresentable {
    let url: URL
    let diagnostics: Map3DDiagnostics
    var coordinatorSink: ((Coordinator) -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        let coord = Coordinator(diagnostics: diagnostics)
        coordinatorSink?(coord)
        return coord
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        // Developer extras help diagnose the "black canvas" failure modes we
        // hit during the CDN/import-map era. Harmless in production builds.
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        // Required for ES-module graphs under `file://`. WKWebView enforces
        // CORS on `<script type="module">` and dynamic `import()` even when
        // the importing doc and the target module are sibling files in the
        // same directory — rejecting the load with "Cross-origin script load
        // denied by Cross-Origin Resource Sharing policy". These two KVC keys
        // are the documented WebKit workaround and are used by many shipping
        // macOS apps. Without them the viewer loads a blank canvas with no
        // error event, because module script failures don't fire `error`
        // events in WKWebView. Verified via the dynamic-import probe on
        // 2026-04-16.
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        config.setValue(true, forKey: "allowUniversalAccessFromFileURLs")

        // Bridge console.* + window.onerror + unhandledrejection into Swift
        // via WKScriptMessageHandler. Installed at documentStart so it fires
        // before any viewer script runs.
        let bridgeSource = """
        (function() {
          const post = (level, args) => {
            try {
              const text = Array.from(args).map(a => {
                if (a instanceof Error) return (a.stack || a.message || String(a));
                if (a && typeof a === 'object') {
                  try { return JSON.stringify(a); } catch (e) { return String(a); }
                }
                return String(a);
              }).join(' ');
              window.webkit?.messageHandlers?.map3dLog?.postMessage({ level: level, text: text });
            } catch (e) { /* swallow — can't surface if the bridge itself is broken */ }
          };
          const wrap = (orig, level) => function() { post(level, arguments); return orig.apply(console, arguments); };
          console.log   = wrap(console.log,   'log');
          console.info  = wrap(console.info,  'info');
          console.warn  = wrap(console.warn,  'warn');
          console.error = wrap(console.error, 'error');
          console.debug = wrap(console.debug, 'debug');
          window.addEventListener('error', function(e) {
            post('error', ['uncaught: ' + (e.message || '(no message)') + ' @ ' + (e.filename || '(no file)') + ':' + (e.lineno || '?')]);
          });
          window.addEventListener('unhandledrejection', function(e) {
            const r = e.reason;
            post('error', ['unhandled rejection: ' + ((r && (r.stack || r.message)) || String(r))]);
          });
          post('info', ['js bridge installed @ ' + location.href]);
        })();
        """
        let userScript = WKUserScript(
            source: bridgeSource,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        config.userContentController.addUserScript(userScript)
        config.userContentController.add(context.coordinator, name: "map3dLog")

        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.uiDelegate = context.coordinator
        // Intentionally NOT setting drawsBackground = false — see file header.

        context.coordinator.webViewRef = web
        context.coordinator.load(url: url, into: web)
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        // Intentionally empty — see header doc. Reloads happen by parent
        // bumping `reloadToken` (on the `.id` modifier), which remounts the
        // NSView and runs makeNSView again.
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        let diagnostics: Map3DDiagnostics
        weak var webViewRef: WKWebView?

        init(diagnostics: Map3DDiagnostics) { self.diagnostics = diagnostics }

        /// Snapshot the current viewport via `WKWebView.takeSnapshot`. A 100ms
        /// settle delay is inserted BEFORE the snapshot to avoid blank-canvas
        /// races with three.js (the WebGL canvas can be mid-repaint when the
        /// user hits the camera button). `width` controls the output pixel
        /// width; the snapshot preserves the webview's aspect ratio.
        @MainActor
        func captureSnapshot(width: CGFloat = 2048) async -> NSImage? {
            guard let web = webViewRef else { return nil }
            try? await Task.sleep(nanoseconds: 100_000_000)
            let config = WKSnapshotConfiguration()
            config.snapshotWidth = NSNumber(value: Double(width))
            return await withCheckedContinuation { cont in
                web.takeSnapshot(with: config) { image, error in
                    if let error {
                        MainActor.assumeIsolated {
                            self.diagnostics.append("snapshot failed: \(error.localizedDescription)", level: .error)
                        }
                    }
                    cont.resume(returning: image)
                }
            }
        }

        func load(url: URL, into web: WKWebView) {
            MainActor.assumeIsolated {
                diagnostics.append("load: \(url.lastPathComponent) (\(url.deletingLastPathComponent().lastPathComponent))", level: .info)
            }
            if url.isFileURL {
                web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
            } else {
                web.load(URLRequest(url: url))
            }
        }

        // MARK: WKNavigationDelegate

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            MainActor.assumeIsolated {
                diagnostics.append("nav start → \(webView.url?.absoluteString ?? "?")", level: .info)
            }
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            MainActor.assumeIsolated {
                diagnostics.append("nav commit", level: .info)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            MainActor.assumeIsolated {
                diagnostics.append("nav finish", level: .info)
            }
            // Probe the renderer so we can tell an *empty* DOM apart from a
            // DOM-with-failed-WebGL. Runs after the load completes.
            webView.evaluateJavaScript(
                "JSON.stringify({ " +
                "  doc: document.readyState, " +
                "  bodyChildren: document.body ? document.body.children.length : -1, " +
                "  canvas: !!document.querySelector('canvas'), " +
                "  webgl2: (function(){ try { return !!document.createElement('canvas').getContext('webgl2'); } catch(e) { return false; } })(), " +
                "  webgl:  (function(){ try { return !!document.createElement('canvas').getContext('webgl');  } catch(e) { return false; } })(), " +
                "  userAgent: navigator.userAgent " +
                "})"
            ) { [weak self] result, err in
                guard let self else { return }
                MainActor.assumeIsolated {
                    if let err {
                        self.diagnostics.append("probe eval failed: \(err.localizedDescription)", level: .error)
                    } else if let s = result as? String {
                        self.diagnostics.append("probe: \(s)", level: .info)
                    } else {
                        self.diagnostics.append("probe: (no result)", level: .warn)
                    }
                }
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            MainActor.assumeIsolated {
                diagnostics.append("nav fail: \((error as NSError).domain) \((error as NSError).code) — \(error.localizedDescription)", level: .error)
            }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            MainActor.assumeIsolated {
                diagnostics.append("provisional fail: \((error as NSError).domain) \((error as NSError).code) — \(error.localizedDescription)", level: .error)
            }
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            MainActor.assumeIsolated {
                diagnostics.append("web content process terminated (WebGL crash?) — reloading", level: .error)
            }
            webView.reload()
        }

        // MARK: WKScriptMessageHandler

        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard message.name == "map3dLog" else { return }
            guard let dict = message.body as? [String: Any] else { return }
            let levelString = (dict["level"] as? String) ?? "log"
            let text = (dict["text"] as? String) ?? "(empty)"
            let level: Map3DDiagnostics.Level = {
                switch levelString {
                case "error": return .error
                case "warn":  return .warn
                case "info":  return .info
                case "debug": return .debug
                default:      return .debug
                }
            }()
            MainActor.assumeIsolated {
                self.diagnostics.append(text, level: level)
            }
        }
    }
}

// MARK: - Resource locator

@available(macOS 26.0, *)
private enum Map3DResourceLocator {
    /// Returns the viewer's `index.html`, searching in order:
    ///   1. `AMIRA_MAP3D_DIR` env var (dev override),
    ///   2. the app-bundled `map3d-viewer/` folder (shipped via
    ///      `Scripts/build-app.sh`),
    ///   3. the source-tree `Scripts/3d-map-pipeline/viewer/` fallback for
    ///      developer machines.
    static func indexURL() -> URL? {
        if let override = ProcessInfo.processInfo.environment["AMIRA_MAP3D_DIR"], !override.isEmpty {
            let dir = URL(fileURLWithPath: override)
            if let idx = indexURL(in: dir) { return idx }
        }
        if let resourceURL = Bundle.main.resourceURL {
            let bundled = resourceURL.appendingPathComponent("map3d-viewer")
            if let idx = indexURL(in: bundled) { return idx }
        }
        let sourceTree = URL(fileURLWithPath: "/Volumes/Storage VIII/Programming/Amira Writer/Scripts/3d-map-pipeline/viewer")
        if let idx = indexURL(in: sourceTree) { return idx }
        return nil
    }

    private static func indexURL(in dir: URL) -> URL? {
        let idx = dir.appendingPathComponent("index.html")
        return FileManager.default.fileExists(atPath: idx.path) ? idx : nil
    }
}
