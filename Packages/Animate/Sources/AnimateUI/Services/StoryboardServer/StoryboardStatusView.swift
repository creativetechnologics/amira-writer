import SwiftUI
import AppKit

// MARK: - StoryboardStatusView
//
// Popover that shows the LAN URL for the iPad storyboard tool and a Copy button.
// Optionally renders a QR code via CIFilter so the user can scan instead of type.
// §27 checklist observed: no @StateObject, no focusable+onKeyPress on containers,
// uses .plain buttonStyle to match OperaChromeActionButton pattern.

@available(macOS 26.0, *)
struct StoryboardStatusView: View {
    let url: URL

    @State private var copied = false
    @State private var qrImage: NSImage? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "tablet.and.pencil")
                    .font(.system(size: 12, weight: .semibold))
                Text("Storyboard")
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(.primary)

            Text("Open this on your iPad to sketch storyboards.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                Text(url.absoluteString)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10, weight: .medium))
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(copied ? .green : .secondary)
                .animation(.easeInOut(duration: 0.15), value: copied)
                .help("Copy URL")
            }
            .padding(8)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))

            if let qr = qrImage {
                Image(nsImage: qr)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 120, height: 120)
                    .padding(4)
                    .background(.white, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .padding(14)
        .frame(width: 240)
        .task(id: url.absoluteString) { qrImage = makeQR(for: url.absoluteString) }
    }

    private func makeQR(for string: String) -> NSImage? {
        guard let data = string.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let ciImage = filter.outputImage else { return nil }
        let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: 6, y: 6))
        let rep = NSCIImageRep(ciImage: scaled)
        let nsImage = NSImage(size: rep.size)
        nsImage.addRepresentation(rep)
        return nsImage
    }
}
