import Foundation

// MARK: - StoryboardAssets
//
// Serves bundled web resources from Resources/storyboard-web/ via Bundle.module.
// Maps file extensions to MIME types; /static/* is the primary path, but we
// also serve root-level compatibility aliases like /style.css and /app.js.
// GET / is aliased to index.html.

@available(macOS 26.0, *)
enum StoryboardAssets {

    static func serve(path: String) -> (data: Data, mimeType: String)? {
        let relativePath: String
        if path == "/" || path.isEmpty {
            relativePath = "index.html"
        } else if path.hasPrefix("/static/") {
            relativePath = String(path.dropFirst("/static/".count))
        } else if path.hasPrefix("/") {
            relativePath = String(path.dropFirst())
        } else {
            return nil
        }

        // Only allow the storyboard web assets we actually bundle.
        let allowedFiles: Set<String> = [
            "index.html",
            "style.css",
            "app.js",
            "drawing.js",
            "vendor/perfect-freehand.min.js",
            "manifest.webmanifest",
            "apple-touch-icon.png",
            "favicon.png",
            "icon-192.png",
            "icon-512.png"
        ]
        guard allowedFiles.contains(relativePath) else { return nil }

        guard let webRoot = SafeBundle.module?.url(forResource: "storyboard-web", withExtension: nil) else {
            return nil
        }
        let fileURL = webRoot.appendingPathComponent(relativePath)
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return (data, mimeType(for: fileURL.pathExtension))
    }

    private static func mimeType(for ext: String) -> String {
        switch ext.lowercased() {
        case "html": return "text/html; charset=utf-8"
        case "css":  return "text/css; charset=utf-8"
        case "js":   return "application/javascript; charset=utf-8"
        case "webmanifest": return "application/manifest+json; charset=utf-8"
        case "svg":  return "image/svg+xml"
        case "woff2": return "font/woff2"
        case "woff":  return "font/woff"
        case "png":   return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "json":  return "application/json; charset=utf-8"
        default:      return "application/octet-stream"
        }
    }
}
