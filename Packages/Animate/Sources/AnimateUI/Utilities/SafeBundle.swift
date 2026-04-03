import Foundation

/// Safe alternative to `Bundle.module` that returns `nil` instead of crashing
/// when the SPM resource bundle is not embedded in the deployed app.
///
/// SPM's auto-generated `Bundle.module` uses `fatalError` when the resource
/// bundle is missing, which crashes the app on launch. This accessor replicates
/// the lookup logic but returns `nil` on failure, allowing graceful degradation.
@available(macOS 26.0, *)
enum SafeBundle {
    static let module: Bundle? = {
        let bundleName = "Animate_AnimateUI"
        let candidates: [URL] = [
            // Standard macOS app bundle resource location
            Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/\(bundleName).bundle"),
            // SPM default: beside the executable
            Bundle.main.bundleURL.appendingPathComponent("\(bundleName).bundle"),
            // SPM build directory (development)
            Bundle.main.bundlePath
                .components(separatedBy: ".build/")
                .first
                .map { URL(fileURLWithPath: $0 + ".build/arm64-apple-macosx/debug/\(bundleName).bundle") },
        ].compactMap { $0 }

        for candidate in candidates {
            if let bundle = Bundle(url: candidate) {
                return bundle
            }
        }

        NSLog("[SafeBundle] Could not locate \(bundleName).bundle — Metal shaders and bundled models will be unavailable.")
        return nil
    }()
}
