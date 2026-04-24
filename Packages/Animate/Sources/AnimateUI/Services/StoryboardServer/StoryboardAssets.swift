import Foundation

// MARK: - StoryboardAssets
//
// Serves bundled web resources from Resources/storyboard-web/ via Bundle.module.
// Maps file extensions to MIME types; any path under /static/ is resolved relative
// to the storyboard-web bundle directory. GET / is aliased to index.html.

@available(macOS 26.0, *)
enum StoryboardAssets {

    static func serve(path: String) -> (data: Data, mimeType: String)? {
        let relativePath: String
        if path == "/" || path.isEmpty {
            relativePath = "index.html"
        } else if path.hasPrefix("/static/") {
            relativePath = String(path.dropFirst("/static/".count))
        } else {
            return nil
        }
        guard let webRoot = Bundle.module.url(forResource: "storyboard-web", withExtension: nil) else {
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
