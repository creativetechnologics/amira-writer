import Foundation

/// Snapshot of a virtual-camera position inside the 3D map viewer, attached
/// to a Gemini image-generation draft so the model gets a structured brief
/// describing where the shot should be taken from.
///
/// Created by the `Scripts/3d-map-pipeline/viewer` when the user clicks
/// "Save camera for draft". The viewer sends the raw camera metadata to Swift
/// via a WKScriptMessageHandler; `MapViewPreset.decode(from:)` turns the
/// payload into this value.
@available(macOS 26.0, *)
struct MapViewPreset: Codable, Hashable, Sendable {
    var createdAtISO: String
    var name: String
    var sourceMap: String?

    // Camera geometry in the 3D scene's world-space metres.
    var positionMetersXYZ: [Double]
    var lookAtMetersXYZ: [Double]
    var fovDeg: Double
    var elevationASLMeters: Double
    var altitudeAboveGroundMeters: Double
    var compassHeadingDeg: Double
    var headingName: String
    var focalDistanceMeters: Double

    // Scene metrics at the time the preset was captured.
    var worldWidthMeters: Double
    var peakAltitudeMeters: Double
    var riverAltitudeMeters: Double

    // What the virtual camera sees.
    var visibleBuildingLabels: [String]
    var visibleBuildingDistancesMeters: [Int]
    var visibleWaterLabels: [String]
    var focalPointMeters: [Double]?

    /// Pre-built prompt fragment sent to Gemini alongside the draft prompt.
    var geminiPromptBrief: String

    /// Build from the dictionary posted by `viewer/main.js`'s
    /// `buildGroundingCardMetadata` helper.
    static func decode(from raw: Any) -> MapViewPreset? {
        guard let dict = raw as? [String: Any] else { return nil }
        let camera = dict["camera"] as? [String: Any] ?? [:]
        let world = dict["world"] as? [String: Any] ?? [:]
        let visible = dict["visible_in_frame"] as? [String: Any] ?? [:]
        let buildings = visible["buildings"] as? [[String: Any]] ?? []
        let waters = visible["water"] as? [[String: Any]] ?? []
        let focal = visible["focal_point"] as? [String: Any]

        func d(_ container: [String: Any], _ k: String, _ fallback: Double = 0) -> Double {
            if let n = container[k] as? Double { return n }
            if let n = container[k] as? NSNumber { return n.doubleValue }
            if let s = container[k] as? String, let n = Double(s) { return n }
            return fallback
        }
        func da(_ container: [String: Any], _ k: String) -> [Double] {
            (container[k] as? [Any])?.compactMap { any in
                if let n = any as? Double { return n }
                if let n = any as? NSNumber { return n.doubleValue }
                return nil
            } ?? []
        }

        return MapViewPreset(
            createdAtISO: (dict["created_at"] as? String) ?? ISO8601DateFormatter().string(from: Date()),
            name: (dict["name"] as? String) ?? "Map view",
            sourceMap: dict["source_map"] as? String,
            positionMetersXYZ: da(camera, "position_m"),
            lookAtMetersXYZ: da(camera, "look_at_m"),
            fovDeg: d(camera, "fov_deg", 55),
            elevationASLMeters: d(camera, "elevation_asl_m"),
            altitudeAboveGroundMeters: d(camera, "altitude_above_ground_m"),
            compassHeadingDeg: d(camera, "compass_heading_deg"),
            headingName: (camera["heading_name"] as? String) ?? "",
            focalDistanceMeters: d(camera, "focal_distance_m"),
            worldWidthMeters: d(world, "world_width_m"),
            peakAltitudeMeters: d(world, "peak_alt_m"),
            riverAltitudeMeters: d(world, "river_alt_m"),
            visibleBuildingLabels: buildings.compactMap { $0["label"] as? String },
            visibleBuildingDistancesMeters: buildings.compactMap { $0["distance_m"] as? Int
                ?? ($0["distance_m"] as? NSNumber)?.intValue },
            visibleWaterLabels: waters.compactMap { $0["label"] as? String },
            focalPointMeters: (focal?["world_m"] as? [Any])?.compactMap { any in
                if let n = any as? Double { return n }
                if let n = any as? NSNumber { return n.doubleValue }
                return nil
            },
            geminiPromptBrief: (dict["gemini_prompt_template"] as? String) ?? ""
        )
    }

    /// Short display string for chips in the UI.
    var summaryLine: String {
        let heading = headingName.isEmpty ? "\(Int(compassHeadingDeg))°" : headingName
        return "\(Int(elevationASLMeters)) m ASL · facing \(heading) · FOV \(Int(fovDeg))°"
    }

    /// Preamble that prepends the draft prompt at submit time.
    func formattedPromptPreamble() -> String {
        if !geminiPromptBrief.isEmpty { return "[Camera brief from 3D map]\n\(geminiPromptBrief)" }
        let buildings = visibleBuildingLabels.prefix(6).joined(separator: ", ")
        var lines: [String] = [
            "[Camera brief from 3D map]",
            "Render the image from a virtual camera at world coordinates " +
            "(X=\(Int(positionMetersXYZ.first ?? 0)), Y=\(Int(positionMetersXYZ.dropFirst().first ?? 0)), Z=\(Int(positionMetersXYZ.last ?? 0))).",
            "Camera elevation \(Int(elevationASLMeters)) m above sea level, " +
            "\(Int(altitudeAboveGroundMeters)) m above local ground, " +
            "looking compass heading \(Int(compassHeadingDeg))° (\(headingName)), " +
            "field of view \(Int(fovDeg))°.",
        ]
        if !buildings.isEmpty { lines.append("Buildings visible in frame (closest first): \(buildings).") }
        lines.append("The image must match this camera position and viewing direction exactly; do not invent a different vantage.")
        return lines.joined(separator: " ")
    }
}
