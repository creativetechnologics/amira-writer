import Foundation
import AppKit
import ProjectKit

@available(macOS 26.0, *)
@MainActor
final class StoryboardComposerService {
    private let store: AnimateStore

    private let panelWidth: CGFloat = 1280
    private let panelHeight: CGFloat = 720

    init(store: AnimateStore) {
        self.store = store
    }

    func composeStoryboard(
        scene: AnimationScene,
        shot: AnimationSceneShot,
        projectRoot: URL
    ) async throws -> URL {
        let characters = resolveCharacters(scene: scene, shot: shot)
        let place = resolvePlace(scene: scene)
        let camera: CameraShot = shot.cameraShot ?? scene.directionTemplate?.defaultCameraShot ?? .mediumClose
        let intent = shot.shotIntent ?? .dialogue

        let image = renderPanel(camera: camera, intent: intent, characters: characters, place: place, shot: shot)
        return try savePanel(image: image, sceneID: scene.id, shotID: shot.id, projectRoot: projectRoot)
    }

    // MARK: - Resolution

    private func resolveCharacters(scene: AnimationScene, shot: AnimationSceneShot) -> [AnimationCharacter] {
        var slugs = scene.characterSlugs
        if let focus = shot.focusCharacterSlug { slugs.append(focus) }
        return store.characters.filter { slugs.contains($0.owpSlug) }
    }

    private func resolvePlace(scene: AnimationScene) -> PlaceData? {
        guard let bgID = scene.backgroundID,
              let place = store.backgrounds.first(where: { $0.id == bgID }) else { return nil }
        return PlaceData(name: place.name, visualBrief: place.visualBrief)
    }

    // MARK: - Rendering

    private func renderPanel(
        camera: CameraShot,
        intent: ShotIntent,
        characters: [AnimationCharacter],
        place: PlaceData?,
        shot: AnimationSceneShot
    ) -> NSImage {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(panelWidth),
            pixelsHigh: Int(panelHeight),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .calibratedRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!

        let ctx = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx

        let cg = ctx.cgContext

        drawBackground(cg, place: place)
        drawGroundLine(cg)

        let viewport = cameraViewport(camera)
        let layout = blockCharacters(characters: characters, intent: intent, focusSlug: shot.focusCharacterSlug, notes: shot.notes)

        for character in characters {
            guard let placement = layout[character.owpSlug] else { continue }
            let screen = worldToScreen(placement.worldX, placement.standingY, viewport: viewport)
            drawCharacter(cg, atX: screen.x, y: screen.y, scale: screen.scale, facing: placement.facing, character: character, intent: intent)
        }

        if !characters.isEmpty && layout.count > 1 {
            drawEyelineGuides(cg, characters: characters, layout: layout, viewport: viewport)
        }

        drawFramingOverlay(cg, camera: camera)
        drawPanelLabel(cg, shot.name, camera: camera, intent: intent)

        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: NSSize(width: panelWidth, height: panelHeight))
        image.addRepresentation(rep)
        return image
    }

    // MARK: - Viewport Math

    private func cameraViewport(_ camera: CameraShot) -> CGFloat {
        switch camera {
        case .extremeWide: 22
        case .wide: 12
        case .medium: 6
        case .mediumClose: 3.5
        case .close: 1.8
        case .extremeClose: 0.6
        }
    }

    private func worldToScreen(_ wx: CGFloat, _ wy: CGFloat, viewport: CGFloat) -> (x: CGFloat, y: CGFloat, scale: CGFloat) {
        let pxPerUnit = panelWidth / viewport
        let cx = panelWidth / 2
        let groundScreenY = panelHeight * 0.72
        let sx = cx + wx * pxPerUnit
        let sy = groundScreenY - wy * pxPerUnit
        let scale = panelWidth / 1280
        return (sx, sy, scale)
    }

    // MARK: - Blocking

    struct CharPlacement {
        var worldX: CGFloat
        var standingY: CGFloat
        var facing: CGFloat
    }

    private func blockCharacters(
        characters: [AnimationCharacter],
        intent: ShotIntent,
        focusSlug: String?,
        notes: String
    ) -> [String: CharPlacement] {
        var layout: [String: CharPlacement] = [:]
        let count = characters.count
        let lowerNotes = notes.lowercased()

        guard count > 0 else { return layout }

        let defaultFacing: CGFloat = 0

        for (index, char) in characters.enumerated() {
            let slug = char.owpSlug
            var x: CGFloat = 0
            var y: CGFloat = 1.2
            var facing: CGFloat = defaultFacing

            switch count {
            case 1:
                x = 0
                facing = 0
            case 2:
                if slug == focusSlug || index == 0 {
                    x = -0.6
                    facing = 15
                } else {
                    x = 0.6
                    facing = -15
                }
            case 3:
                x = index == 0 ? -1.0 : (index == 1 ? 0 : 1.0)
                facing = index == 0 ? 10 : (index == 1 ? 0 : -10)
            default:
                x = CGFloat(index - (count - 1) / 2) * 0.9
            }

            if lowerNotes.contains("right") && (!lowerNotes.contains("left") || lowerNotes.range(of: "right")!.lowerBound > lowerNotes.range(of: "left")!.lowerBound) {
                if slug == focusSlug { x = 0.8 }
            }
            if lowerNotes.contains("left") {
                if slug == focusSlug { x = -0.8 }
            }
            if lowerNotes.contains("foreground") {
                if slug == focusSlug { x = 0; y = 1.6 }
            }
            if lowerNotes.contains("background") {
                if slug == focusSlug { x = 0; y = 0.8 }
            }

            switch intent {
            case .establishing:
                x *= 1.5; y = 0.9
            case .dialogue:
                y = 1.2
            case .reaction:
                x = 0; facing = 0
            case .movement:
                facing += 25
            case .confrontation:
                x *= 0.5
            default: break
            }

            layout[slug] = CharPlacement(worldX: x, standingY: y, facing: facing)
        }

        return layout
    }

    // MARK: - Background Drawing

    private func drawBackground(_ cg: CGContext, place: PlaceData?) {
        let skyStart = CGFloat(0)
        let skyEnd = panelHeight * 0.68

        let colors = [CGColor(gray: 0.95, alpha: 1), CGColor(gray: 0.88, alpha: 1)] as CFArray
        guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceGray(), colors: colors, locations: [0, 1]) else { return }
        cg.drawLinearGradient(gradient, start: CGPoint(x: 0, y: skyStart), end: CGPoint(x: 0, y: skyEnd), options: [])

        let groundTop = skyEnd
        let groundColors = [CGColor(gray: 0.82, alpha: 1), CGColor(gray: 0.75, alpha: 1)] as CFArray
        guard let groundGrad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceGray(), colors: groundColors, locations: [0, 1]) else { return }
        cg.drawLinearGradient(groundGrad, start: CGPoint(x: 0, y: groundTop), end: CGPoint(x: 0, y: panelHeight), options: [])

        if let place {
            let label = "\(place.name)".uppercased()
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .light),
                .foregroundColor: NSColor(white: 0.55, alpha: 1)
            ]
            let size = (label as NSString).size(withAttributes: attrs)
            (label as NSString).draw(at: CGPoint(x: panelWidth - size.width - 16, y: skyEnd - size.height - 8), withAttributes: attrs)
        }
    }

    private func drawGroundLine(_ cg: CGContext) {
        let y = panelHeight * 0.68
        cg.setStrokeColor(CGColor(gray: 0.6, alpha: 1))
        cg.setLineWidth(1)
        cg.move(to: CGPoint(x: 0, y: y))
        cg.addLine(to: CGPoint(x: panelWidth, y: y))
        cg.strokePath()
    }

    // MARK: - Character Drawing

    private func drawCharacter(
        _ cg: CGContext,
        atX x: CGFloat,
        y: CGFloat,
        scale: CGFloat,
        facing: CGFloat,
        character: AnimationCharacter,
        intent: ShotIntent
    ) {
        cg.saveGState()
        cg.translateBy(x: x, y: y)
        cg.scaleBy(x: scale, y: scale)

        let isMale = character.genderType == .male
        let isChild = (character.age ?? 25) < 14
        let charColor = colorForCharacter(character)

        let size = mannequinSize(intent: intent)
        let headR = size * (isChild ? 0.22 : 0.16)

        cg.rotate(by: facing * .pi / 180)

        // Head
        cg.setFillColor(charColor.cgColor)
        cg.fillEllipse(in: CGRect(x: -headR, y: size - headR * 2.5, width: headR * 2, height: headR * 2))

        // Neck
        cg.setStrokeColor(charColor.cgColor)
        cg.setLineWidth(2)
        cg.move(to: CGPoint(x: 0, y: size - headR * 2.5))
        cg.addLine(to: CGPoint(x: 0, y: size * 0.75))
        cg.strokePath()

        // Body
        let shoulderW = size * (isMale ? 0.28 : 0.22)
        let hipW = size * 0.16
        let bodyTop = size * 0.75
        let bodyBot = size * 0.35
        let bodyPath = CGMutablePath()
        bodyPath.move(to: CGPoint(x: -shoulderW, y: bodyTop))
        bodyPath.addLine(to: CGPoint(x: -hipW, y: bodyBot))
        bodyPath.addLine(to: CGPoint(x: hipW, y: bodyBot))
        bodyPath.addLine(to: CGPoint(x: shoulderW, y: bodyTop))
        bodyPath.closeSubpath()
        cg.setFillColor(charColor.cgColor)
        cg.addPath(bodyPath)
        cg.fillPath()

        // Arms
        let armLen = size * 0.35
        let armW: CGFloat = 3
        cg.setLineWidth(armW)
        // Left arm
        cg.move(to: CGPoint(x: -shoulderW + 4, y: bodyTop))
        cg.addLine(to: CGPoint(x: -shoulderW - 8, y: bodyTop - armLen * 0.6))
        cg.addLine(to: CGPoint(x: -shoulderW - 4, y: bodyTop - armLen))
        cg.strokePath()
        // Right arm
        cg.move(to: CGPoint(x: shoulderW - 4, y: bodyTop))
        cg.addLine(to: CGPoint(x: shoulderW + 8, y: bodyTop - armLen * 0.6))
        cg.addLine(to: CGPoint(x: shoulderW + 4, y: bodyTop - armLen))
        cg.strokePath()

        // Legs
        let legLen = size * 0.4
        cg.setLineWidth(4)
        cg.move(to: CGPoint(x: -hipW + 4, y: bodyBot))
        cg.addLine(to: CGPoint(x: -hipW + 2, y: bodyBot - legLen * 0.5))
        cg.addLine(to: CGPoint(x: -hipW + 6, y: bodyBot - legLen))
        cg.strokePath()
        cg.move(to: CGPoint(x: hipW - 4, y: bodyBot))
        cg.addLine(to: CGPoint(x: hipW - 2, y: bodyBot - legLen * 0.5))
        cg.addLine(to: CGPoint(x: hipW - 6, y: bodyBot - legLen))
        cg.strokePath()

        // Facial features
        let faceX = headR * 0.3
        let faceYTop = size - headR * 3.2
        let faceYBot = size - headR * 3.6
        cg.setLineWidth(1.5)
        cg.setStrokeColor(CGColor(gray: 0.2, alpha: 1))
        // Eyes
        cg.move(to: CGPoint(x: -faceX, y: faceYTop))
        cg.addLine(to: CGPoint(x: -faceX + 3, y: faceYTop))
        cg.strokePath()
        cg.move(to: CGPoint(x: faceX - 3, y: faceYTop))
        cg.addLine(to: CGPoint(x: faceX, y: faceYTop))
        cg.strokePath()
        // Mouth
        cg.move(to: CGPoint(x: -faceX, y: faceYBot))
        cg.addLine(to: CGPoint(x: faceX, y: faceYBot))
        cg.strokePath()

        cg.restoreGState()
    }

    private func mannequinSize(intent: ShotIntent) -> CGFloat {
        switch intent {
        case .establishing: 18
        case .reaction, .emotional: 120
        case .insert: 160
        case .dialogue, .confrontation: 80
        case .handoff: 60
        case .movement, .transition: 40
        case .reveal: 50
        }
    }

    // MARK: - Eyeline guides

    private func drawEyelineGuides(
        _ cg: CGContext,
        characters: [AnimationCharacter],
        layout: [String: CharPlacement],
        viewport: CGFloat
    ) {
        let slugs = layout.keys.sorted()
        guard slugs.count >= 2 else { return }

        let eyeY = panelHeight * 0.72 - 1.2 * (panelWidth / viewport)
        cg.setStrokeColor(CGColor(red: 0.5, green: 0.6, blue: 0.9, alpha: 0.3))
        cg.setLineWidth(1)
        cg.setLineDash(phase: 0, lengths: [6, 12])

        for i in 0..<slugs.count {
            for j in (i + 1)..<slugs.count {
                guard let a = layout[slugs[i]], let b = layout[slugs[j]] else { continue }
                let sax = panelWidth / 2 + a.worldX * (panelWidth / viewport)
                let sbx = panelWidth / 2 + b.worldX * (panelWidth / viewport)
                cg.move(to: CGPoint(x: sax, y: eyeY))
                cg.addLine(to: CGPoint(x: sbx, y: eyeY))
                cg.strokePath()
            }
        }
        cg.setLineDash(phase: 0, lengths: [])
    }

    // MARK: - Framing overlay

    private func drawFramingOverlay(_ cg: CGContext, camera: CameraShot) {
        let margin: CGFloat = 20
        let lineLen: CGFloat = 30
        cg.setStrokeColor(CGColor(gray: 0.5, alpha: 0.4))
        cg.setLineWidth(1)

        // Top-left
        cg.move(to: CGPoint(x: margin, y: panelHeight - margin - lineLen))
        cg.addLine(to: CGPoint(x: margin, y: panelHeight - margin))
        cg.addLine(to: CGPoint(x: margin + lineLen, y: panelHeight - margin))
        cg.strokePath()

        // Top-right
        cg.move(to: CGPoint(x: panelWidth - margin - lineLen, y: panelHeight - margin))
        cg.addLine(to: CGPoint(x: panelWidth - margin, y: panelHeight - margin))
        cg.addLine(to: CGPoint(x: panelWidth - margin, y: panelHeight - margin - lineLen))
        cg.strokePath()

        // Bottom-left
        cg.move(to: CGPoint(x: margin, y: margin + lineLen))
        cg.addLine(to: CGPoint(x: margin, y: margin))
        cg.addLine(to: CGPoint(x: margin + lineLen, y: margin))
        cg.strokePath()

        // Bottom-right
        cg.move(to: CGPoint(x: panelWidth - margin - lineLen, y: margin))
        cg.addLine(to: CGPoint(x: panelWidth - margin, y: margin))
        cg.addLine(to: CGPoint(x: panelWidth - margin, y: margin + lineLen))
        cg.strokePath()
    }

    // MARK: - Labels

    private func drawPanelLabel(_ cg: CGContext, _ shotName: String, camera: CameraShot, intent: ShotIntent) {
        let topText = "\(shotName)   |   \(camera.displayName)   ·   \(intent.displayName)"
        let topAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor(white: 0.3, alpha: 1)
        ]
        let topSize = (topText as NSString).size(withAttributes: topAttrs)
        (topText as NSString).draw(at: CGPoint(x: (panelWidth - topSize.width) / 2, y: panelHeight - topSize.height - 14), withAttributes: topAttrs)

        let botText = "STORYBOARD PANEL"
        let botAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .light),
            .foregroundColor: NSColor(white: 0.55, alpha: 1)
        ]
        let botSize = (botText as NSString).size(withAttributes: botAttrs)
        (botText as NSString).draw(at: CGPoint(x: (panelWidth - botSize.width) / 2, y: 12), withAttributes: botAttrs)
    }

    // MARK: - Colors

    private func colorForCharacter(_ character: AnimationCharacter) -> NSColor {
        let slug = character.owpSlug
        let hash = slug.utf8.reduce(0) { $0 &+ Int($1) }
        let hue = CGFloat(abs(hash) % 360) / 360.0
        return NSColor(hue: hue, saturation: 0.3, brightness: 0.45, alpha: 1)
    }

    // MARK: - Save

    private func savePanel(image: NSImage, sceneID: UUID, shotID: UUID, projectRoot: URL) throws -> URL {
        let dir = ProjectPaths(root: projectRoot).sceneStoryboardsDir(sceneID: sceneID)
            .appendingPathComponent(shotID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("storyboard-composed.jpg")

        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.92]) else {
            throw ServiceError.encodeFailed
        }
        try jpeg.write(to: url)
        return url
    }
}

@available(macOS 26.0, *)
extension StoryboardComposerService {
    enum ServiceError: LocalizedError {
        case encodeFailed
        var errorDescription: String? { "Failed to encode storyboard image" }
    }
}

struct PlaceData {
    var name: String
    var visualBrief: String
}
