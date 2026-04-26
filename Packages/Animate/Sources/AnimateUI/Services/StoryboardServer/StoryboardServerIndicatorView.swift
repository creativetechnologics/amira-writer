import SwiftUI
import ProjectKit

@available(macOS 26.0, *)
struct StoryboardServerIndicatorView: View {
    @ObservedObject private var status = StoryboardServerStatusModel.shared
    @State private var showPopover = false
    @State private var saveFlash = false
    @State private var pulse = false

    var body: some View {
        Button {
            showPopover.toggle()
        } label: {
            HStack(spacing: 5) {
                ZStack {
                    Circle()
                        .fill(statusColor.opacity(saveFlash ? 0.24 : 0))
                        .frame(width: 18, height: 18)
                        .scaleEffect(pulse ? 1.45 : 0.75)
                    Circle()
                        .fill(statusColor)
                        .frame(width: 7, height: 7)
                        .shadow(color: statusColor.opacity(status.isLive ? 0.55 : 0), radius: saveFlash ? 5 : 2)
                }
                .frame(width: 18, height: 18)

                Text(saveFlash ? "iPad Saved" : status.shortStatusText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(saveFlash ? statusColor : OperaChromeTheme.textSecondary)
                    .lineLimit(1)
            }
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule(style: .continuous)
                    .fill(saveFlash ? statusColor.opacity(0.14) : OperaChromeTheme.raisedBackground.opacity(0.42))
            )
            .overlay {
                Capsule(style: .continuous)
                    .stroke(saveFlash ? statusColor.opacity(0.32) : Color.white.opacity(0.06), lineWidth: 1)
            }
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .help(composeHelpText())
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            VStack(spacing: 0) {
                StoryboardStatusView(url: status.displayURL)

                Divider()
                    .padding(.horizontal, 14)

                VStack(alignment: .leading, spacing: 8) {
                    statusRow(
                        title: "Current",
                        value: status.statusText,
                        systemImage: status.statusSymbolName,
                        tint: statusColor
                    )

                    statusRow(
                        title: "Last save",
                        value: status.lastSaveDescription ?? "No storyboard saves yet",
                        systemImage: "square.and.arrow.down",
                        tint: status.lastSaveDescription == nil ? .secondary : OperaChromeTheme.success,
                        timestamp: status.lastSaveDate
                    )

                    statusRow(
                        title: "Recovery",
                        value: status.recoveryQueueText,
                        systemImage: "arrow.triangle.2.circlepath",
                        tint: status.lastRecoveryError != nil ? .red : .secondary,
                        timestamp: status.lastRecoveryDate
                    )

                    if let error = status.lastRecoveryError {
                        statusRow(
                            title: "Recovery error",
                            value: error,
                            systemImage: "exclamationmark.triangle.fill",
                            tint: .red,
                            timestamp: status.lastRecoveryDate
                        )
                    } else if status.lastRecoveryDescription == nil {
                        statusRow(
                            title: "Recovery note",
                            value: "Startup recovery status will appear here once a scan is recorded.",
                            systemImage: "info.circle",
                            tint: .secondary
                        )
                    }
                }
                .font(.system(size: 11))
                .padding(14)
            }
            .frame(width: 280)
        }
        .onChange(of: status.lastSaveToken) { _, token in
            guard token > 0 else { return }
            animateSavePulse()
        }
        .animation(.easeInOut(duration: 0.16), value: saveFlash)
        .animation(.easeInOut(duration: 0.16), value: status.state)
    }

    private var statusColor: Color {
        switch status.state {
        case .live:
            return OperaChromeTheme.success
        case .starting:
            return .orange
        case .failed:
            return .red
        case .stopped:
            return OperaChromeTheme.textTertiary
        }
    }

    private func animateSavePulse() {
        saveFlash = true
        pulse = false
        withAnimation(.spring(response: 0.22, dampingFraction: 0.58)) {
            pulse = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
            withAnimation(.easeOut(duration: 0.22)) {
                pulse = false
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.35) {
            withAnimation(.easeInOut(duration: 0.18)) {
                saveFlash = false
            }
        }
    }

    @ViewBuilder
    private func statusRow(
        title: String,
        value: String,
        systemImage: String,
        tint: Color,
        timestamp: Date? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 12)

                Text(title)
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)

                Spacer(minLength: 8)

                if let timestamp {
                    Text(timestamp.formatted(date: .omitted, time: .shortened))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            Text(value)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func composeHelpText() -> String {
        let parts = [
            status.statusText,
            status.detailStatusText,
            status.displayURL.absoluteString
        ].compactMap { $0 }
        return parts.joined(separator: " — ")
    }
}
