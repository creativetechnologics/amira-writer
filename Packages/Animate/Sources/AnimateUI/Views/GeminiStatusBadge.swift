import AppKit
import ProjectKit
import SwiftUI

/// Title-bar indicator that shows whether any Gemini image generations are
/// in flight. Click to see the recent-activity popover (queued/running/
/// recently-completed entries with source + filename).
///
/// - Gray capsule with sparkle icon = idle
/// - Green pulsing capsule + count = N running / queued
@available(macOS 26.0, *)
struct GeminiStatusBadge: View {
    @Bindable var store: AnimateStore
    @State private var isPopoverVisible = false

    var body: some View {
        let activeCount = store.geminiActivityActiveCount
        Button {
            isPopoverVisible.toggle()
        } label: {
            badgeLabel(activeCount: activeCount)
        }
        .buttonStyle(.plain)
        .help(helpText(activeCount: activeCount))
        .popover(isPresented: $isPopoverVisible, arrowEdge: .top) {
            GeminiActivityPopover(store: store)
                .frame(width: 420, height: 480)
        }
    }

    private func helpText(activeCount: Int) -> String {
        if activeCount == 0 { return "No active Gemini generations. Click for recent activity." }
        return "\(activeCount) Gemini generation\(activeCount == 1 ? "" : "s") in flight. Click for details."
    }

    @ViewBuilder
    private func badgeLabel(activeCount: Int) -> some View {
        let isIdle = activeCount == 0
        let bg: Color = isIdle ? Color.secondary.opacity(0.08) : Color.green.opacity(0.15)
        let stroke: Color = isIdle ? Color.secondary.opacity(0.25) : Color.green.opacity(0.55)
        HStack(spacing: 6) {
            if isIdle {
                Image(systemName: "sparkle")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
                    .controlSize(.mini)
                    .progressViewStyle(CircularProgressViewStyle(tint: .green))
                Text("\(activeCount)")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.green)
            }
            Text(isIdle ? "Gemini" : "generating")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(isIdle ? Color.secondary : Color.green)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(bg, in: Capsule())
        .overlay(Capsule().stroke(stroke, lineWidth: 1))
    }
}

@available(macOS 26.0, *)
struct VertexCreditTitleBarLabel: View {
    @Bindable var store: AnimateStore

    var body: some View {
        if ImageGenBackendStore.currentBackend() == .vertex {
            Text("Vertex $\(String(format: "%.2f", store.vertexCreditRemainingUSD))")
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(Color.secondary.opacity(0.75))
                .help("Estimated Vertex AI remaining credit. Adjust it in Settings if it drifts.")
        }
    }
}

@available(macOS 26.0, *)
struct GeminiActivityPopover: View {
    @Bindable var store: AnimateStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Gemini Activity")
                        .font(.headline)
                    Text("\(store.geminiActivityActiveCount) active · \(store.geminiActivityLog.count) recent")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    store.clearCompletedGeminiActivity()
                } label: {
                    Label("Clear completed", systemImage: "eraser")
                }
                .controlSize(.small)
                .disabled(store.geminiActivityLog.allSatisfy { $0.status == .queued || $0.status == .running })
            }
            .padding(14)

            Divider()

            if store.geminiActivityLog.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "sparkle")
                        .font(.title)
                        .foregroundStyle(.tertiary)
                    Text("No recent Gemini activity")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(store.geminiActivityLog) { entry in
                            entryRow(entry)
                            Divider().opacity(0.5)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func entryRow(_ entry: AnimateStore.GeminiActivityEntry) -> some View {
        HStack(alignment: .top, spacing: 10) {
            statusIcon(for: entry.status)
                .frame(width: 18, height: 18)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(entry.title)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Text(entry.kind == .batch ? "BATCH" : "IMMEDIATE")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background((entry.kind == .batch ? Color.purple : Color.blue).opacity(0.2), in: Capsule())
                        .foregroundStyle(entry.kind == .batch ? Color.purple : Color.blue)
                }
                Text(entry.source)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let filename = entry.outputFilename {
                    Text(filename)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                if let error = entry.errorMessage {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
                Text(entry.timelineString)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)

            if entry.status == .queued || entry.status == .running {
                Button {
                    store.cancelGeminiActivity(entry.id)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Cancel this generation")
                .padding(.top, 1)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func statusIcon(for status: AnimateStore.GeminiActivityEntry.Status) -> some View {
        switch status {
        case .queued:
            Image(systemName: "clock")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
        case .running:
            ProgressView().controlSize(.mini)
                .progressViewStyle(CircularProgressViewStyle(tint: .green))
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13))
                .foregroundStyle(.red)
        }
    }
}

@available(macOS 26.0, *)
private extension AnimateStore.GeminiActivityEntry {
    var timelineString: String {
        let startFmt = Self.timeFormatter.string(from: startedAt)
        if let completedAt {
            let secs = Int(completedAt.timeIntervalSince(startedAt))
            return "started \(startFmt) · took \(secs)s"
        }
        let secs = Int(Date().timeIntervalSince(startedAt))
        return status == .running ? "running \(secs)s" : "queued \(startFmt)"
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm:ss a"
        return f
    }()
}
