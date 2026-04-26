import AppKit
import Foundation

@available(macOS 26.0, *)
final class ReferenceSheetCropService {

    struct CropResult {
        let pose: CharacterReferencePose
        let imageData: Data
        let cropRect: CropRect
        let confidence: Double  // 0-1
    }

    enum CropKind {
        case head
        case fullBody
    }

    // MARK: - Public Entry Point

    func cropSheet(
        image: NSImage,
        kind: CropKind,
        expectedPoses: [CharacterReferencePose] = CharacterReferencePose.allCases
    ) -> [CropResult] {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return []
        }

        let imageWidth = cgImage.width
        let imageHeight = cgImage.height
        let gridCols = 3
        let gridRows = 2

        // Step 1 — binary mask (white background vs dark content)
        guard let binaryMask = createBinaryMask(from: cgImage, threshold: 240) else {
            return []
        }

        // Step 2 — connected components
        let components = findConnectedComponents(
            in: binaryMask,
            width: imageWidth,
            height: imageHeight,
            minFraction: 0.02,
            gridCols: gridCols,
            gridRows: gridRows
        )

        // Step 3 — assign components to grid poses
        let assignments = assignComponentsToGrid(
            components: components,
            gridCols: gridCols,
            gridRows: gridRows,
            imageWidth: imageWidth,
            imageHeight: imageHeight,
            poses: expectedPoses
        )

        // Step 4 — for each assignment, crop with padding and mask adjacent figures
        var results: [CropResult] = []
        for (pose, component) in assignments {
            guard let pngData = cropComponent(
                component: component,
                allComponents: Array(assignments.values),
                binaryMask: binaryMask,
                cgImage: cgImage,
                imageWidth: imageWidth,
                imageHeight: imageHeight,
                gridCols: gridCols,
                gridRows: gridRows,
                paddingFraction: 0.06
            ) else { continue }

            let normalizedBox = CGRect(
                x: Double(component.expandedBounds.origin.x) / Double(imageWidth),
                y: Double(component.expandedBounds.origin.y) / Double(imageHeight),
                width: Double(component.expandedBounds.size.width) / Double(imageWidth),
                height: Double(component.expandedBounds.size.height) / Double(imageHeight)
            )

            let result = CropResult(
                pose: pose,
                imageData: pngData,
                cropRect: CropRect.from(normalizedBox),
                confidence: component.confidence
            )
            results.append(result)
        }

        return results
    }

    // MARK: - Binary Mask

    /// Returns a flat array of UInt8 where 0 = dark content, 255 = white background.
    private func createBinaryMask(from cgImage: CGImage, threshold: UInt8) -> [UInt8]? {
        let width = cgImage.width
        let height = cgImage.height
        let bytesPerRow = width
        var pixels = [UInt8](repeating: 0, count: width * height)

        guard let ctx = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }

        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Threshold: bright pixels → 255 (background), dark → 0 (content)
        for i in 0..<pixels.count {
            pixels[i] = pixels[i] >= threshold ? 255 : 0
        }
        return pixels
    }

    // MARK: - Connected Components

    struct ComponentInfo {
        let label: Int
        var minX: Int
        var maxX: Int
        var minY: Int
        var maxY: Int
        var pixelCount: Int
        var centroidX: Double
        var centroidY: Double
        var confidence: Double = 1.0
        // Padded bounds used for actual cropping
        var expandedBounds: CGRect = .zero
    }

    private func findConnectedComponents(
        in mask: [UInt8],
        width: Int,
        height: Int,
        minFraction: Double,
        gridCols: Int,
        gridRows: Int
    ) -> [ComponentInfo] {
        // Union-Find
        var parent = [Int](0..<(width * height))
        var rank = [Int](repeating: 0, count: width * height)

        func find(_ x: Int) -> Int {
            var x = x
            while parent[x] != x {
                parent[x] = parent[parent[x]]
                x = parent[x]
            }
            return x
        }

        func union(_ a: Int, _ b: Int) {
            let ra = find(a), rb = find(b)
            if ra == rb { return }
            if rank[ra] < rank[rb] { parent[ra] = rb }
            else if rank[ra] > rank[rb] { parent[rb] = ra }
            else { parent[rb] = ra; rank[ra] += 1 }
        }

        // Only connect content pixels (value == 0)
        for y in 0..<height {
            for x in 0..<width {
                let idx = y * width + x
                if mask[idx] != 0 { continue }  // background — skip
                if x + 1 < width && mask[idx + 1] == 0 { union(idx, idx + 1) }
                if y + 1 < height && mask[idx + width] == 0 { union(idx, idx + width) }
            }
        }

        // Collect bounding boxes per root
        var boxes: [Int: (minX: Int, maxX: Int, minY: Int, maxY: Int, sumX: Int, sumY: Int, count: Int)] = [:]
        for y in 0..<height {
            for x in 0..<width {
                let idx = y * width + x
                if mask[idx] != 0 { continue }
                let root = find(idx)
                if var b = boxes[root] {
                    b.minX = min(b.minX, x)
                    b.maxX = max(b.maxX, x)
                    b.minY = min(b.minY, y)
                    b.maxY = max(b.maxY, y)
                    b.sumX += x
                    b.sumY += y
                    b.count += 1
                    boxes[root] = b
                } else {
                    boxes[root] = (x, x, y, y, x, y, 1)
                }
            }
        }

        // Minimum cell area for filtering
        let cellArea = Double(width * height) / Double(gridCols * gridRows)
        let minPixels = Int(cellArea * minFraction)

        var label = 0
        var components: [ComponentInfo] = []
        for (_, b) in boxes {
            guard b.count >= minPixels else { continue }
            let cx = Double(b.sumX) / Double(b.count)
            let cy = Double(b.sumY) / Double(b.count)
            var info = ComponentInfo(
                label: label,
                minX: b.minX, maxX: b.maxX,
                minY: b.minY, maxY: b.maxY,
                pixelCount: b.count,
                centroidX: cx,
                centroidY: cy
            )
            info.expandedBounds = CGRect(
                x: CGFloat(b.minX), y: CGFloat(b.minY),
                width: CGFloat(b.maxX - b.minX + 1),
                height: CGFloat(b.maxY - b.minY + 1)
            )
            components.append(info)
            label += 1
        }
        return components
    }

    // MARK: - Grid Assignment

    private func assignComponentsToGrid(
        components: [ComponentInfo],
        gridCols: Int,
        gridRows: Int,
        imageWidth: Int,
        imageHeight: Int,
        poses: [CharacterReferencePose]
    ) -> [CharacterReferencePose: ComponentInfo] {
        let cellWidth = Double(imageWidth) / Double(gridCols)
        let cellHeight = Double(imageHeight) / Double(gridRows)

        // Map each pose to its expected grid cell centre
        func cellCenter(for pose: CharacterReferencePose) -> (x: Double, y: Double) {
            let (row, col): (Int, Int) = switch pose {
            case .frontNeutral: (0, 0)
            case .quarterLeft:  (0, 1)
            case .quarterRight: (0, 2)
            case .back:         (1, 0)
            case .leftProfile:  (1, 1)
            case .rightProfile: (1, 2)
            }
            return (
                (Double(col) + 0.5) * cellWidth,
                (Double(row) + 0.5) * cellHeight
            )
        }

        var assignments: [CharacterReferencePose: ComponentInfo] = [:]
        var usedLabels = Set<Int>()

        for pose in poses {
            let center = cellCenter(for: pose)

            // Prefer the component whose centroid is closest to the cell centre
            var best: ComponentInfo? = nil
            var bestDist = Double.infinity
            for comp in components {
                guard !usedLabels.contains(comp.label) else { continue }
                let dx = comp.centroidX - center.x
                let dy = comp.centroidY - center.y
                let dist = sqrt(dx * dx + dy * dy)
                if dist < bestDist {
                    bestDist = dist
                    best = comp
                }
            }

            guard var component = best else { continue }

            // Confidence: how close is the centroid to the expected cell centre?
            let maxDist = sqrt(cellWidth * cellWidth + cellHeight * cellHeight) / 2.0
            let confidence = max(0.0, 1.0 - bestDist / maxDist)
            component.confidence = confidence

            usedLabels.insert(component.label)
            assignments[pose] = component
        }
        return assignments
    }

    // MARK: - Crop + Mask Adjacent Figures

    private func cropComponent(
        component: ComponentInfo,
        allComponents: [ComponentInfo],
        binaryMask: [UInt8],
        cgImage: CGImage,
        imageWidth: Int,
        imageHeight: Int,
        gridCols: Int,
        gridRows: Int,
        paddingFraction: Double
    ) -> Data? {
        let cellWidth = Double(imageWidth) / Double(gridCols)
        let cellHeight = Double(imageHeight) / Double(gridRows)
        let padX = cellWidth * paddingFraction
        let padY = cellHeight * paddingFraction

        let rawBounds = component.expandedBounds
        let paddedRect = CGRect(
            x: max(0, rawBounds.minX - padX),
            y: max(0, rawBounds.minY - padY),
            width: min(Double(imageWidth),  rawBounds.maxX + padX) - max(0, rawBounds.minX - padX),
            height: min(Double(imageHeight), rawBounds.maxY + padY) - max(0, rawBounds.minY - padY)
        ).integral

        guard let cropped = cgImage.cropping(to: paddedRect) else { return nil }

        // Render into a writable RGBA bitmap so we can isolate the target
        // figure, remove the sheet background, and save a true 1:1 contained
        // PNG. This keeps sheet-derived animated/costume references visually
        // uniform even when the detected figure bounds are not square.
        let cropW = Int(paddedRect.width)
        let cropH = Int(paddedRect.height)
        let bytesPerRow = cropW * 4
        var rgba = [UInt8](repeating: 0, count: cropH * bytesPerRow)

        guard let ctx = CGContext(
            data: &rgba,
            width: cropW,
            height: cropH,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: cropW, height: cropH))

        // Mask adjacent figure pixels — any content pixel NOT belonging to this component.
        // Also remove the near-white reference-sheet background so the saved
        // square contains only the figure, centered on a transparent canvas.
        let cropOriginX = Int(paddedRect.minX)
        let cropOriginY = Int(paddedRect.minY)

        let edgeConnectedBackground = Self.edgeConnectedReferenceSheetBackgroundMask(
            rgba: rgba,
            width: cropW,
            height: cropH
        )

        for localY in 0..<cropH {
            for localX in 0..<cropW {
                let globalX = cropOriginX + localX
                let globalY = cropOriginY + localY
                guard globalX >= 0, globalX < imageWidth,
                      globalY >= 0, globalY < imageHeight else { continue }
                let maskIdx = globalY * imageWidth + globalX
                let rgbaIdx = localY * bytesPerRow + localX * 4
                let isWithinTargetBounds = rawBounds.contains(CGPoint(x: globalX, y: globalY))
                let isTargetContent = binaryMask[maskIdx] == 0
                let isProtectedInteriorLightPixel = !edgeConnectedBackground[localY * cropW + localX]
                let shouldKeep = isWithinTargetBounds && (isTargetContent || isProtectedInteriorLightPixel)
                if !shouldKeep {
                    rgba[rgbaIdx] = 0
                    rgba[rgbaIdx + 1] = 0
                    rgba[rgbaIdx + 2] = 0
                    rgba[rgbaIdx + 3] = 0
                }
            }
        }

        return Self.squareContainedPNG(fromRGBA: rgba, width: cropW, height: cropH)
    }

    static func squareContainedPNG(
        from cgImage: CGImage,
        cropRect: CGRect,
        removeReferenceSheetBackground: Bool = true
    ) -> Data? {
        let boundedRect = cropRect.integral.intersection(
            CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height)
        )
        guard boundedRect.width > 0,
              boundedRect.height > 0,
              let cropped = cgImage.cropping(to: boundedRect) else { return nil }

        let cropW = Int(boundedRect.width)
        let cropH = Int(boundedRect.height)
        let bytesPerRow = cropW * 4
        var rgba = [UInt8](repeating: 0, count: cropH * bytesPerRow)

        guard let ctx = CGContext(
            data: &rgba,
            width: cropW,
            height: cropH,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: cropW, height: cropH))

        if removeReferenceSheetBackground {
            Self.clearEdgeConnectedReferenceSheetBackground(&rgba, width: cropW, height: cropH)
        }

        return squareContainedPNG(fromRGBA: rgba, width: cropW, height: cropH)
    }

    private static func clearEdgeConnectedReferenceSheetBackground(_ rgba: inout [UInt8], width: Int, height: Int) {
        let mask = edgeConnectedReferenceSheetBackgroundMask(rgba: rgba, width: width, height: height)
        let bytesPerRow = width * 4
        for y in 0..<height {
            for x in 0..<width where mask[y * width + x] {
                let idx = y * bytesPerRow + x * 4
                rgba[idx] = 0
                rgba[idx + 1] = 0
                rgba[idx + 2] = 0
                rgba[idx + 3] = 0
            }
        }
    }

    private static func edgeConnectedReferenceSheetBackgroundMask(rgba: [UInt8], width: Int, height: Int) -> [Bool] {
        guard width > 0, height > 0 else { return [] }
        let bytesPerRow = width * 4
        var visited = [Bool](repeating: false, count: width * height)
        var queue: [(Int, Int)] = []
        queue.reserveCapacity(width * 2 + height * 2)

        func isNearWhiteBackground(_ x: Int, _ y: Int) -> Bool {
            let idx = y * bytesPerRow + x * 4
            return isLikelyReferenceSheetBackground(
                red: rgba[idx],
                green: rgba[idx + 1],
                blue: rgba[idx + 2],
                alpha: rgba[idx + 3]
            )
        }

        func enqueueIfBackground(_ x: Int, _ y: Int) {
            guard x >= 0, x < width, y >= 0, y < height else { return }
            let key = y * width + x
            guard !visited[key], isNearWhiteBackground(x, y) else { return }
            visited[key] = true
            queue.append((x, y))
        }

        for x in 0..<width {
            enqueueIfBackground(x, 0)
            enqueueIfBackground(x, height - 1)
        }
        if height > 2 {
            for y in 1..<(height - 1) {
                enqueueIfBackground(0, y)
                enqueueIfBackground(width - 1, y)
            }
        }

        var head = 0
        while head < queue.count {
            let (x, y) = queue[head]
            head += 1
            enqueueIfBackground(x + 1, y)
            enqueueIfBackground(x - 1, y)
            enqueueIfBackground(x, y + 1)
            enqueueIfBackground(x, y - 1)
        }

        return visited
    }

    private static func isLikelyReferenceSheetBackground(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8) -> Bool {
        guard alpha > 0 else { return true }
        let maxChannel = max(red, max(green, blue))
        let minChannel = min(red, min(green, blue))
        let chroma = Int(maxChannel) - Int(minChannel)
        let average = (Int(red) + Int(green) + Int(blue)) / 3
        return average >= 238 && chroma <= 18
    }

    private static func squareContainedPNG(fromRGBA rgba: [UInt8], width: Int, height: Int) -> Data? {
        guard width > 0, height > 0 else { return nil }
        let squareSide = max(width, height)
        let squareBytesPerRow = squareSide * 4
        var squareRGBA = [UInt8](repeating: 0, count: squareSide * squareBytesPerRow)
        let offsetX = (squareSide - width) / 2
        let offsetY = (squareSide - height) / 2
        let sourceBytesPerRow = width * 4

        for y in 0..<height {
            let sourceStart = y * sourceBytesPerRow
            let targetStart = (y + offsetY) * squareBytesPerRow + offsetX * 4
            squareRGBA.replaceSubrange(
                targetStart..<(targetStart + sourceBytesPerRow),
                with: rgba[sourceStart..<(sourceStart + sourceBytesPerRow)]
            )
        }

        guard let squareCtx = CGContext(
            data: &squareRGBA,
            width: squareSide,
            height: squareSide,
            bitsPerComponent: 8,
            bytesPerRow: squareBytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let squareCG = squareCtx.makeImage() else { return nil }

        let nsImage = NSImage(cgImage: squareCG, size: NSSize(width: squareSide, height: squareSide))
        guard let tiff = nsImage.tiffRepresentation,
              let bmp = NSBitmapImageRep(data: tiff),
              let png = bmp.representation(using: .png, properties: [:]) else { return nil }
        return png
    }
}
