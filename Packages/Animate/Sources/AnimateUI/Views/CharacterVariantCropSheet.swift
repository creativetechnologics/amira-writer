import SwiftUI
import AppKit

@available(macOS 26.0, *)
enum CropHandle: CaseIterable, Equatable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
}

@available(macOS 26.0, *)
struct CharacterVariantCropSheet: View {
    let store: AnimateStore
    let sourceImagePath: String
    let initialCropRect: CGRect?
    let aspectRatioHint: CGFloat?
    let onCrop: (CGRect) -> Void
    let onCancel: () -> Void

    @State private var cropRect: CGRect = CGRect(x: 0.15, y: 0.15, width: 0.7, height: 0.7)
    @State private var imageDisplayRect: CGRect = .zero
    @State private var aspectRatioLocked: Bool = false
    @State private var activeHandle: CropHandle? = nil
    @State private var dragStartCropRect: CGRect = .zero
    @State private var loadedImage: NSImage? = nil
    @State private var pixelSize: CGSize = .zero  // actual pixel dimensions from CGImage
    @State private var isDraggingInterior: Bool = false
    @State private var dragStartOriginInCrop: CGPoint = .zero

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            GeometryReader { geo in
                cropCanvas(in: geo)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black.opacity(0.85))
            Divider()
            controlBar
        }
        .frame(minWidth: 800, minHeight: 700)
        .background(Color(nsColor: .windowBackgroundColor))
        .task(id: sourceImagePath) {
            loadedImage = nil
            pixelSize = .zero
            if let url = store.resolvedCharacterAssetURL(for: sourceImagePath),
               let image = await loadSharedFullResolutionImage(at: url.path) {
                loadedImage = image
                if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    pixelSize = CGSize(width: cg.width, height: cg.height)
                } else {
                    pixelSize = image.size
                }
            }
            if let initial = initialCropRect {
                cropRect = initial
            } else if let ar = aspectRatioHint {
                cropRect = defaultCropRect(for: ar)
            }
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Adjust Crop")
                    .font(.headline)
                Text("Drag handles to resize. Drag inside the selection to move it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel") { onCancel() }
                .buttonStyle(.bordered)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Crop Canvas

    @ViewBuilder
    private func cropCanvas(in geo: GeometryProxy) -> some View {
        if let image = loadedImage {
            let displaySize = fitSize(for: image.size, in: geo.size, padding: 32)
            let originX = (geo.size.width - displaySize.width) / 2
            let originY = (geo.size.height - displaySize.height) / 2
            let imgRect = CGRect(origin: CGPoint(x: originX, y: originY), size: displaySize)

            ZStack {
                // Source image
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: displaySize.width, height: displaySize.height)
                    .position(x: imgRect.midX, y: imgRect.midY)

                // Dark overlay outside crop (even-odd to punch out the crop hole)
                CropOverlayShape(cropRect: screenCropRect(from: cropRect, imgRect: imgRect), containerSize: geo.size)
                    .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
                    .allowsHitTesting(false)

                // Rule-of-thirds grid inside crop
                RuleOfThirdsGrid(screenRect: screenCropRect(from: cropRect, imgRect: imgRect))
                    .stroke(Color.white.opacity(0.20), lineWidth: 0.5)
                    .allowsHitTesting(false)

                // Crop border
                let scr = screenCropRect(from: cropRect, imgRect: imgRect)
                Rectangle()
                    .strokeBorder(Color.white, lineWidth: 1.5)
                    .frame(width: scr.width, height: scr.height)
                    .position(x: scr.midX, y: scr.midY)
                    .allowsHitTesting(false)

                // Interior drag target
                Rectangle()
                    .fill(Color.white.opacity(0.001))
                    .frame(width: max(0, scr.width - 28), height: max(0, scr.height - 28))
                    .position(x: scr.midX, y: scr.midY)
                    .gesture(interiorDragGesture(imgRect: imgRect))

                // Handles
                ForEach(CropHandle.allCases, id: \.self) { handle in
                    Circle()
                        .fill(Color.white)
                        .frame(width: 14, height: 14)
                        .overlay(Circle().strokeBorder(Color.black.opacity(0.25), lineWidth: 1))
                        .position(handlePosition(handle, screenRect: scr))
                        .gesture(handleDragGesture(handle: handle, imgRect: imgRect))
                        .zIndex(10)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        } else {
            Color.black
                .overlay(
                    Text("Loading image…")
                        .foregroundStyle(.secondary)
                )
        }
    }

    // MARK: - Control Bar

    private var controlBar: some View {
        HStack(spacing: 16) {
            // Pixel readout using actual CGImage pixel dimensions
            if loadedImage != nil {
                let pixW = Int(cropRect.width * pixelSize.width)
                let pixH = Int(cropRect.height * pixelSize.height)
                Text("W: \(pixW)px  H: \(pixH)px")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Aspect ratio toggle
            HStack(spacing: 4) {
                Button {
                    aspectRatioLocked = true
                    guard pixelSize.width > 0, pixelSize.height > 0 else { return }
                    // For 1:1 pixel output: width_px == height_px
                    // width_px = cropRect.width * pixelSize.width
                    // height_px = cropRect.height * pixelSize.height
                    // Set cropRect.height = cropRect.width * (pixelSize.width / pixelSize.height)
                    let imgAR = pixelSize.width / pixelSize.height
                    let currentPixW = cropRect.width * pixelSize.width
                    let currentPixH = cropRect.height * pixelSize.height
                    let side = min(currentPixW, currentPixH) // target pixel side length
                    let normW = side / pixelSize.width
                    let normH = side / pixelSize.height
                    cropRect = CGRect(
                        x: max(0, min(cropRect.midX - normW / 2, 1 - normW)),
                        y: max(0, min(cropRect.midY - normH / 2, 1 - normH)),
                        width: normW,
                        height: normH
                    ).clamped(to: CGRect(x: 0, y: 0, width: 1, height: 1))
                } label: {
                    Text("1:1")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .background(aspectRatioLocked ? Color.accentColor.opacity(0.15) : Color.clear, in: RoundedRectangle(cornerRadius: 6))

                Button {
                    aspectRatioLocked = false
                } label: {
                    Text("Free")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .background(!aspectRatioLocked ? Color.accentColor.opacity(0.15) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            }

            Button("Crop & Save") {
                onCrop(cropRect)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - Coordinate Helpers

    private func screenCropRect(from normalized: CGRect, imgRect: CGRect) -> CGRect {
        CGRect(
            x: imgRect.minX + normalized.minX * imgRect.width,
            y: imgRect.minY + normalized.minY * imgRect.height,
            width: normalized.width * imgRect.width,
            height: normalized.height * imgRect.height
        )
    }

    private func handlePosition(_ handle: CropHandle, screenRect: CGRect) -> CGPoint {
        switch handle {
        case .topLeft:     return CGPoint(x: screenRect.minX, y: screenRect.minY)
        case .top:         return CGPoint(x: screenRect.midX, y: screenRect.minY)
        case .topRight:    return CGPoint(x: screenRect.maxX, y: screenRect.minY)
        case .right:       return CGPoint(x: screenRect.maxX, y: screenRect.midY)
        case .bottomRight: return CGPoint(x: screenRect.maxX, y: screenRect.maxY)
        case .bottom:      return CGPoint(x: screenRect.midX, y: screenRect.maxY)
        case .bottomLeft:  return CGPoint(x: screenRect.minX, y: screenRect.maxY)
        case .left:        return CGPoint(x: screenRect.minX, y: screenRect.midY)
        }
    }

    private func fitSize(for imageSize: CGSize, in containerSize: CGSize, padding: CGFloat = 0) -> CGSize {
        let maxW = containerSize.width - padding * 2
        let maxH = containerSize.height - padding * 2
        let ar = imageSize.width / imageSize.height
        if ar > maxW / maxH {
            return CGSize(width: maxW, height: maxW / ar)
        } else {
            return CGSize(width: maxH * ar, height: maxH)
        }
    }

    private func defaultCropRect(for aspectRatio: CGFloat) -> CGRect {
        // aspectRatio is width/height in normalized image space
        let margin = 0.1
        let w = 1.0 - margin * 2
        let h = w / aspectRatio
        if h <= 1.0 - margin * 2 {
            return CGRect(x: margin, y: (1 - h) / 2, width: w, height: h)
        } else {
            let h2 = 1.0 - margin * 2
            let w2 = h2 * aspectRatio
            return CGRect(x: (1 - w2) / 2, y: margin, width: w2, height: h2)
        }
    }

    // MARK: - Gestures

    private func interiorDragGesture(imgRect: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if !isDraggingInterior {
                    isDraggingInterior = true
                    dragStartCropRect = cropRect
                }
                let dx = value.translation.width / imgRect.width
                let dy = value.translation.height / imgRect.height
                let newX = (dragStartCropRect.minX + dx).clamped(to: 0...(1 - cropRect.width))
                let newY = (dragStartCropRect.minY + dy).clamped(to: 0...(1 - cropRect.height))
                cropRect = CGRect(x: newX, y: newY, width: cropRect.width, height: cropRect.height)
            }
            .onEnded { _ in isDraggingInterior = false }
    }

    private func handleDragGesture(handle: CropHandle, imgRect: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if activeHandle != handle {
                    activeHandle = handle
                    dragStartCropRect = cropRect
                }
                let dx = value.translation.width / imgRect.width
                let dy = value.translation.height / imgRect.height
                var r = dragStartCropRect

                switch handle {
                case .topLeft:
                    r.origin.x = min(r.maxX - 0.05, r.origin.x + dx)
                    r.origin.y = min(r.maxY - 0.05, r.origin.y + dy)
                    r.size.width = dragStartCropRect.maxX - r.origin.x
                    r.size.height = dragStartCropRect.maxY - r.origin.y
                case .top:
                    r.origin.y = min(r.maxY - 0.05, r.origin.y + dy)
                    r.size.height = dragStartCropRect.maxY - r.origin.y
                case .topRight:
                    r.origin.y = min(r.maxY - 0.05, r.origin.y + dy)
                    r.size.width = max(0.05, dragStartCropRect.width + dx)
                    r.size.height = dragStartCropRect.maxY - r.origin.y
                case .right:
                    r.size.width = max(0.05, dragStartCropRect.width + dx)
                case .bottomRight:
                    r.size.width = max(0.05, dragStartCropRect.width + dx)
                    r.size.height = max(0.05, dragStartCropRect.height + dy)
                case .bottom:
                    r.size.height = max(0.05, dragStartCropRect.height + dy)
                case .bottomLeft:
                    r.origin.x = min(r.maxX - 0.05, r.origin.x + dx)
                    r.size.width = dragStartCropRect.maxX - r.origin.x
                    r.size.height = max(0.05, dragStartCropRect.height + dy)
                case .left:
                    r.origin.x = min(r.maxX - 0.05, r.origin.x + dx)
                    r.size.width = dragStartCropRect.maxX - r.origin.x
                }

                if aspectRatioLocked, pixelSize.width > 0, pixelSize.height > 0 {
                    // Maintain square pixel output: width_norm * pixelW == height_norm * pixelH
                    // => height_norm = width_norm * (pixelW / pixelH)
                    let imgAR = pixelSize.width / pixelSize.height
                    r.size.height = r.size.width * imgAR
                    // For top/left handles, anchor bottom-right edge
                    switch handle {
                    case .topLeft:
                        r.origin.x = dragStartCropRect.maxX - r.size.width
                        r.origin.y = dragStartCropRect.maxY - r.size.height
                    case .top:
                        r.origin.y = dragStartCropRect.maxY - r.size.height
                    case .left:
                        r.origin.x = dragStartCropRect.maxX - r.size.width
                    case .bottomLeft:
                        r.origin.x = dragStartCropRect.maxX - r.size.width
                    default:
                        break
                    }
                }

                // Clamp to [0,1]
                r.origin.x = max(0, r.origin.x)
                r.origin.y = max(0, r.origin.y)
                r.size.width = min(r.size.width, 1 - r.origin.x)
                r.size.height = min(r.size.height, 1 - r.origin.y)

                cropRect = r
            }
            .onEnded { _ in activeHandle = nil }
    }
}

// MARK: - Crop Overlay Shape

@available(macOS 26.0, *)
private struct CropOverlayShape: Shape {
    let cropRect: CGRect
    let containerSize: CGSize

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addRect(CGRect(origin: .zero, size: containerSize))
        path.addRect(cropRect)
        return path
    }
}

// MARK: - Rule of Thirds Grid

@available(macOS 26.0, *)
private struct RuleOfThirdsGrid: Shape {
    let screenRect: CGRect

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = screenRect.width
        let h = screenRect.height
        // Vertical lines at 1/3 and 2/3
        for i in 1...2 {
            let x = screenRect.minX + CGFloat(i) * w / 3
            path.move(to: CGPoint(x: x, y: screenRect.minY))
            path.addLine(to: CGPoint(x: x, y: screenRect.maxY))
        }
        // Horizontal lines at 1/3 and 2/3
        for i in 1...2 {
            let y = screenRect.minY + CGFloat(i) * h / 3
            path.move(to: CGPoint(x: screenRect.minX, y: y))
            path.addLine(to: CGPoint(x: screenRect.maxX, y: y))
        }
        return path
    }
}

// MARK: - CGRect helpers

private extension CGRect {
    func clamped(to bounds: CGRect) -> CGRect {
        let x = max(bounds.minX, min(bounds.maxX - width, minX))
        let y = max(bounds.minY, min(bounds.maxY - height, minY))
        let w = min(width, bounds.width)
        let h = min(height, bounds.height)
        return CGRect(x: x, y: y, width: w, height: h)
    }
}

private extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.max(range.lowerBound, Swift.min(range.upperBound, self))
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.max(range.lowerBound, Swift.min(range.upperBound, self))
    }
}
