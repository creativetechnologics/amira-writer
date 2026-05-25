import SwiftUI
import AppKit

@available(macOS 26.0, *)
struct ImageEraserView: View {
    let store: AnimateStore
    let imagePath: String
    let onDone: () -> Void
    let onCancel: () -> Void

    @State private var loadedImage: NSImage? = nil
    @State private var canvasImage: NSImage? = nil
    @State private var brushSize: CGFloat = 20
    @State private var isDrawing: Bool = false

    // Undo stack — snapshots before each drag begins
    @State private var undoStack: [NSImage] = []

    // Hover tracking for brush preview
    @State private var hoverPosition: CGPoint? = nil
    @State private var isHoveringCanvas: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            GeometryReader { geo in
                canvasArea(in: geo)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black.opacity(0.85))
            Divider()
            controlBar
        }
        .frame(minWidth: 900, minHeight: 700)
        .background(Color(nsColor: .windowBackgroundColor))
        .task(id: imagePath) {
            loadedImage = nil
            canvasImage = nil
            guard let url = store.resolvedCharacterAssetURL(for: imagePath),
                  let img = await loadSharedFullResolutionImage(at: url.path) else { return }
            loadedImage = img
            canvasImage = img.deepCopyForEraser()
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack {
            Button("Cancel") {
                onCancel()
            }
            .keyboardShortcut(.escape, modifiers: [])

            Spacer()

            Text("Paint Out — Cleanup Tool")
                .font(.headline)

            Spacer()

            Button("Save") {
                saveImage()
            }
            .keyboardShortcut(.return, modifiers: .command)
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Canvas

    @ViewBuilder
    private func canvasArea(in geo: GeometryProxy) -> some View {
        let availableSize = geo.size
        let fitRect = aspectFitRect(imageSize: canvasImage?.size ?? .zero, in: availableSize)

        ZStack {
            if let img = canvasImage {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: fitRect.width, height: fitRect.height)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .position(x: fitRect.midX, y: fitRect.midY)
            }

            // Transparent gesture capture overlay
            Color.clear
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .local)
                        .onChanged { value in
                            if !isDrawing {
                                isDrawing = true
                                pushUndoSnapshot()
                            }
                            paintAt(viewPoint: value.location, availableSize: availableSize)
                        }
                        .onEnded { _ in
                            isDrawing = false
                        }
                )
                .onContinuousHover(coordinateSpace: .local) { phase in
                    switch phase {
                    case .active(let pt):
                        isHoveringCanvas = true
                        hoverPosition = pt
                    case .ended:
                        isHoveringCanvas = false
                        hoverPosition = nil
                    }
                }
                .onHover { hovering in
                    if hovering {
                        NSCursor.crosshair.push()
                    } else {
                        NSCursor.pop()
                    }
                }

            // Brush size preview circle (outline only)
            if isHoveringCanvas, let pos = hoverPosition {
                Circle()
                    .stroke(Color.gray.opacity(0.8), lineWidth: 1)
                    .frame(width: brushSize, height: brushSize)
                    .position(pos)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: availableSize.width, height: availableSize.height)
    }

    // MARK: - Control Bar

    private var controlBar: some View {
        HStack(spacing: 16) {
            Text("Brush:")
                .foregroundStyle(.secondary)

            Slider(value: $brushSize, in: 5...80, step: 1)
                .frame(width: 180)

            Text("\(Int(brushSize)) px")
                .monospacedDigit()
                .frame(width: 44, alignment: .leading)

            Spacer()

            Button("Undo") {
                performUndo()
            }
            .keyboardShortcut("z", modifiers: .command)
            .disabled(undoStack.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Painting

    private func paintAt(viewPoint: CGPoint, availableSize: CGSize) {
        guard let img = canvasImage else { return }
        let imgSize = img.size
        let fit = aspectFitRect(imageSize: imgSize, in: availableSize)
        guard fit.width > 0, fit.height > 0 else { return }

        // Map view coords → image pixel coords
        let scaleX = imgSize.width / fit.width
        let scaleY = imgSize.height / fit.height

        let localX = viewPoint.x - fit.minX
        let localY = viewPoint.y - fit.minY

        guard localX >= 0, localY >= 0, localX <= fit.width, localY <= fit.height else { return }

        let imgX = localX * scaleX
        // NSImage origin is bottom-left; SwiftUI view origin is top-left → flip Y
        let imgY = imgSize.height - (localY * scaleY)

        let radius = (brushSize * max(scaleX, scaleY)) / 2.0
        let ovalRect = CGRect(
            x: imgX - radius,
            y: imgY - radius,
            width: radius * 2,
            height: radius * 2
        )

        let newImage = NSImage(size: imgSize)
        newImage.lockFocus()
        img.draw(in: CGRect(origin: .zero, size: imgSize))
        NSColor.white.setFill()
        NSBezierPath(ovalIn: ovalRect).fill()
        newImage.unlockFocus()

        canvasImage = newImage
    }

    // MARK: - Undo

    private func pushUndoSnapshot() {
        guard let img = canvasImage, let copy = img.deepCopyForEraser() else { return }
        if undoStack.count >= 20 {
            undoStack.removeFirst()
        }
        undoStack.append(copy)
    }

    private func performUndo() {
        guard !undoStack.isEmpty else { return }
        canvasImage = undoStack.removeLast()
    }

    // MARK: - Save

    private func saveImage() {
        guard let img = canvasImage,
              let url = store.resolvedCharacterAssetURL(for: imagePath),
              let tiff = img.tiffRepresentation,
              let bitmapRep = NSBitmapImageRep(data: tiff),
              let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
            onDone()
            return
        }
        try? pngData.write(to: url, options: .atomic)
        onDone()
    }

    // MARK: - Layout Helpers

    private func aspectFitRect(imageSize: CGSize, in containerSize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0,
              containerSize.width > 0, containerSize.height > 0 else {
            return CGRect(origin: .zero, size: containerSize)
        }
        let scale = min(containerSize.width / imageSize.width,
                        containerSize.height / imageSize.height)
        let fittedWidth  = imageSize.width  * scale
        let fittedHeight = imageSize.height * scale
        let originX = (containerSize.width  - fittedWidth)  / 2
        let originY = (containerSize.height - fittedHeight) / 2
        return CGRect(x: originX, y: originY, width: fittedWidth, height: fittedHeight)
    }
}

// MARK: - NSImage helpers

private extension NSImage {
    func deepCopyForEraser() -> NSImage? {
        guard let tiff = tiffRepresentation,
              let rep  = NSBitmapImageRep(data: tiff) else { return nil }
        let copy = NSImage(size: size)
        copy.addRepresentation(rep)
        return copy
    }
}

extension NSImage {
    /// Samples corner pixels to detect if the image has a predominantly white background.
    var hasWhiteBackground: Bool {
        guard let cgImage = self.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return false }
        let width = cgImage.width
        let height = cgImage.height
        guard width > 4, height > 4 else { return false }

        guard let data = cgImage.dataProvider?.data,
              let ptr = CFDataGetBytePtr(data) else { return false }

        let bytesPerPixel = cgImage.bitsPerPixel / 8
        let bytesPerRow = cgImage.bytesPerRow

        // Sample 8 corner pixels (2 per corner)
        let samplePoints: [(Int, Int)] = [
            (1, 1), (2, 2),                           // top-left
            (width - 2, 1), (width - 3, 2),           // top-right
            (1, height - 2), (2, height - 3),         // bottom-left
            (width - 2, height - 2), (width - 3, height - 3) // bottom-right
        ]

        var whiteCount = 0
        let threshold: UInt8 = 240

        for (x, y) in samplePoints {
            let offset = y * bytesPerRow + x * bytesPerPixel
            guard offset + 2 < CFDataGetLength(data) else { continue }
            let r = ptr[offset]
            let g = ptr[offset + 1]
            let b = ptr[offset + 2]
            if r >= threshold && g >= threshold && b >= threshold {
                whiteCount += 1
            }
        }

        return whiteCount >= 6  // at least 6 of 8 corners are white
    }
}
