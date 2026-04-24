import SwiftUI
import ProjectKit

// MARK: - StoryboardURLButton
//
// Toolbar button that shows the LAN URL for the iPad storyboard drawing tool.
// Uses @State for popover — no ObservableObject needed for a single boolean.

@available(macOS 26.0, *)
struct StoryboardURLButton: View {

    @State private var showPopover = false

    var body: some View {
        Button {
            showPopover.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "tablet.and.pencil")
                    .font(.system(size: 10, weight: .medium))
                Text("Storyboard")
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
            }
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(OperaChromeTheme.textSecondary)
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .frame(minHeight: 28)
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(showPopover ? OperaChromeTheme.selection : Color.clear)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(showPopover ? OperaChromeTheme.accent.opacity(0.24) : Color.clear, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            let url = StoryboardAPIServer.shared?.currentURL()
                ?? URL(string: "http://127.0.0.1:\(StoryboardAPIServer.port)")!
            StoryboardStatusView(url: url)
        }
    }
}
