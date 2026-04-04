import Foundation

@available(macOS 26.0, *)
struct MeshyAssetValidationService: Sendable {

    enum ValidationResult: Sendable {
        case valid(MeshValidationReport)
        case invalid(String)
    }

    struct MeshValidationReport: Sendable {
        let fileSize: Int64
        let format: String
        let hasTextures: Bool
        let thumbnailExists: Bool
        let metadataExists: Bool
    }

    /// Validate a downloaded Meshy asset directory
    /// Expected structure:
    ///   {taskID}/
    ///     model.glb
    ///     model.usdz (optional)
    ///     thumbnail.png (optional)
    ///     metadata.json (optional)
    static func validate(assetDirectory: URL) -> [String: ValidationResult] {
        let fm = FileManager.default
        var results: [String: ValidationResult] = [:]

        let thumbnailExists = fm.fileExists(atPath: assetDirectory.appendingPathComponent("thumbnail.png").path)
        let metadataExists = fm.fileExists(atPath: assetDirectory.appendingPathComponent("metadata.json").path)

        // Check each model file
        let modelFormats = ["glb", "usdz", "fbx", "obj", "stl"]
        for format in modelFormats {
            let modelPath = assetDirectory.appendingPathComponent("model.\(format)")
            guard fm.fileExists(atPath: modelPath.path) else { continue }

            do {
                let attributes = try fm.attributesOfItem(atPath: modelPath.path)
                let fileSize = attributes[.size] as? Int64 ?? 0

                // Basic validation
                if fileSize == 0 {
                    results[format] = .invalid("File is empty (0 bytes)")
                    continue
                }

                if fileSize < 100 {
                    results[format] = .invalid("File suspiciously small (\(fileSize) bytes)")
                    continue
                }

                // Format-specific header validation
                if let headerError = validateFileHeader(at: modelPath, format: format) {
                    results[format] = .invalid(headerError)
                    continue
                }

                // Check for textures (GLB can embed them, others need external files)
                let hasTextures: Bool
                switch format {
                case "glb":
                    // GLB files > 10KB with textures are typically much larger than mesh-only
                    hasTextures = fileSize > 50_000
                case "usdz":
                    hasTextures = fileSize > 50_000
                default:
                    // For OBJ/FBX, check if material/texture files exist nearby
                    let mtlExists = fm.fileExists(atPath: assetDirectory.appendingPathComponent("model.mtl").path)
                    hasTextures = mtlExists
                }

                results[format] = .valid(MeshValidationReport(
                    fileSize: fileSize,
                    format: format,
                    hasTextures: hasTextures,
                    thumbnailExists: thumbnailExists,
                    metadataExists: metadataExists
                ))
            } catch {
                results[format] = .invalid("Cannot read file attributes: \(error.localizedDescription)")
            }
        }

        return results
    }

    /// Validate file header bytes match expected format
    private static func validateFileHeader(at url: URL, format: String) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return "Cannot open file for reading"
        }
        defer { try? handle.close() }

        guard let headerData = try? handle.read(upToCount: 12) else {
            return "Cannot read file header"
        }

        switch format {
        case "glb":
            // GLB magic: "glTF" (0x46546C67) followed by version 2 (0x02000000)
            if headerData.count >= 4 {
                let magic = String(data: headerData[0..<4], encoding: .ascii)
                if magic != "glTF" {
                    return "Invalid GLB header (expected 'glTF', got '\(magic ?? "nil")')"
                }
            }
        case "usdz":
            // USDZ is a zip archive — starts with PK (0x504B)
            if headerData.count >= 2 {
                if headerData[0] != 0x50 || headerData[1] != 0x4B {
                    return "Invalid USDZ header (expected ZIP magic bytes)"
                }
            }
        case "fbx":
            // FBX binary starts with "Kaydara FBX Binary"
            if headerData.count >= 10 {
                let prefix = String(data: headerData[0..<10], encoding: .ascii)
                if prefix?.hasPrefix("Kaydara") != true {
                    // Could be ASCII FBX, which starts with "; FBX"
                    let asciiPrefix = String(data: headerData[0..<5], encoding: .ascii)
                    if asciiPrefix?.hasPrefix("; FBX") != true {
                        return "Invalid FBX header"
                    }
                }
            }
        case "obj":
            // OBJ is text — should start with printable ASCII
            if let text = String(data: headerData, encoding: .ascii) {
                // OBJ typically starts with comment (#) or vertex (v)
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty && !trimmed.hasPrefix("#") && !trimmed.hasPrefix("v") && !trimmed.hasPrefix("m") && !trimmed.hasPrefix("o") && !trimmed.hasPrefix("g") {
                    return "OBJ file does not start with expected content"
                }
            }
        default:
            break
        }

        return nil
    }

    /// Human-readable summary of validation results
    static func summary(for results: [String: ValidationResult]) -> String {
        let valid = results.filter { if case .valid = $0.value { return true }; return false }
        let invalid = results.filter { if case .invalid = $0.value { return true }; return false }

        if results.isEmpty {
            return "No model files found"
        }

        var parts: [String] = []
        if !valid.isEmpty {
            let formats = valid.keys.sorted().joined(separator: ", ")
            parts.append("\(valid.count) valid (\(formats))")
        }
        if !invalid.isEmpty {
            let formats = invalid.keys.sorted().joined(separator: ", ")
            parts.append("\(invalid.count) invalid (\(formats))")
        }

        return parts.joined(separator: ", ")
    }
}
