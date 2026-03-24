#if os(macOS)
import SwiftUI

@available(macOS 26.0, *)
public enum OperaChromeTheme {
    public static let windowBackground = Color(NSColor.windowBackgroundColor)
    public static let workspaceBackground = Color(NSColor.underPageBackgroundColor)
    public static let panelBackground = Color(NSColor.controlBackgroundColor)
    public static let headerBackground = Color(NSColor.windowBackgroundColor)
    public static let raisedBackground = Color(NSColor.controlBackgroundColor)
    public static let accent = Color.accentColor
    public static let accentMuted = Color.accentColor.opacity(0.16)
    public static let divider = Color(NSColor.separatorColor)
    public static let stroke = Color(NSColor.separatorColor)
    public static let hover = Color(NSColor.unemphasizedSelectedContentBackgroundColor)
    public static let selection = Color(NSColor.selectedContentBackgroundColor)
    public static let textPrimary = Color.primary
    public static let textSecondary = Color.secondary
    public static let textTertiary = Color(NSColor.tertiaryLabelColor)
    public static let success = Color.green
    public static let warning = Color.orange
    public static let panelCornerRadius: CGFloat = 8
}

@available(macOS 26.0, *)
public struct OperaChromeDivider: View {
    public enum Direction {
        case horizontal
        case vertical
    }

    private let direction: Direction
    private let opacity: Double

    public init(_ direction: Direction = .horizontal, opacity: Double = 1) {
        self.direction = direction
        self.opacity = opacity
    }

    public var body: some View {
        if direction == .vertical {
            Divider().frame(width: 1).opacity(opacity)
        } else {
            Divider().opacity(opacity)
        }
    }
}

@available(macOS 26.0, *)
public struct OperaChromePanel<Header: View, Content: View>: View {
    private let background: Color
    private let header: Header
    private let content: Content

    public init(
        background: Color = OperaChromeTheme.panelBackground,
        @ViewBuilder header: () -> Header,
        @ViewBuilder content: () -> Content
    ) {
        self.background = background
        self.header = header()
        self.content = content()
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(OperaChromeTheme.headerBackground)
            OperaChromeDivider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(background)
        }
        .background(background)
        .clipShape(
            RoundedRectangle(
                cornerRadius: OperaChromeTheme.panelCornerRadius,
                style: .continuous
            )
        )
        .overlay {
            RoundedRectangle(
                cornerRadius: OperaChromeTheme.panelCornerRadius,
                style: .continuous
            )
            .stroke(OperaChromeTheme.stroke, lineWidth: 1)
        }
    }
}

@available(macOS 26.0, *)
public struct OperaChromeFlatPane<Header: View, Content: View>: View {
    private let background: Color
    private let headerPadding: EdgeInsets
    private let header: Header
    private let content: Content

    public init(
        background: Color = OperaChromeTheme.panelBackground,
        headerPadding: EdgeInsets = EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14),
        @ViewBuilder header: () -> Header,
        @ViewBuilder content: () -> Content
    ) {
        self.background = background
        self.headerPadding = headerPadding
        self.header = header()
        self.content = content()
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.top, headerPadding.top)
                .padding(.leading, headerPadding.leading)
                .padding(.bottom, headerPadding.bottom)
                .padding(.trailing, headerPadding.trailing)
                .background(OperaChromeTheme.headerBackground)
            OperaChromeDivider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(background)
        }
        .background(background)
    }
}

@available(macOS 26.0, *)
public struct OperaChromePaneHeader<Actions: View>: View {
    private let eyebrow: String
    private let title: String
    private let subtitle: String
    private let actions: Actions

    public init(
        eyebrow: String,
        title: String,
        subtitle: String,
        @ViewBuilder actions: () -> Actions
    ) {
        self.eyebrow = eyebrow
        self.title = title
        self.subtitle = subtitle
        self.actions = actions()
    }

    public var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(eyebrow)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(1.2)
                    .foregroundStyle(OperaChromeTheme.textTertiary)
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(OperaChromeTheme.textPrimary)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(OperaChromeTheme.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 10)

            actions
        }
    }
}

@available(macOS 26.0, *)
public struct OperaChromeStatusBar: View {
    private let isSaving: Bool
    private let isSaved: Bool
    private let statusMessage: String
    private let isDirty: Bool?
    private let itemCountText: String?

    public init(
        isSaving: Bool = false,
        isSaved: Bool = false,
        statusMessage: String = "",
        isDirty: Bool? = nil,
        itemCountText: String? = nil
    ) {
        self.isSaving = isSaving
        self.isSaved = isSaved
        self.statusMessage = statusMessage
        self.isDirty = isDirty
        self.itemCountText = itemCountText
    }

    public var body: some View {
        HStack(spacing: 8) {
            if isSaving {
                HStack(spacing: 5) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Saving...")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(OperaChromeTheme.textSecondary)
                }
                .transition(.opacity)
            } else if isSaved {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(OperaChromeTheme.success)
                    Text("Saved")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(OperaChromeTheme.textSecondary)
                }
                .transition(.opacity)
            } else if !statusMessage.isEmpty {
                Text(statusMessage)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(OperaChromeTheme.textTertiary)
                    .lineLimit(1)
                    .transition(.opacity)
            }

            Spacer()

            if let isDirty, isDirty {
                Circle()
                    .fill(OperaChromeTheme.warning.opacity(0.85))
                    .frame(width: 6, height: 6)
                    .help("Unsaved changes")
            }

            if let itemCountText {
                Text(itemCountText)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(OperaChromeTheme.textTertiary)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isSaving)
        .animation(.easeInOut(duration: 0.2), value: isSaved)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(OperaChromeTheme.panelBackground)
    }
}

@available(macOS 26.0, *)
public enum OperaChromeSidebarMetrics {
    public static let defaultWidth: Double = 220
    public static let minWidth: Double = 196
    public static let maxWidth: Double = 320
    public static let headerPadding = EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12)
    public static let listSpacing: CGFloat = 3
    public static let listHorizontalPadding: CGFloat = 8
    public static let listVerticalPadding: CGFloat = 6
    public static let rowHorizontalPadding: CGFloat = 9
    public static let rowVerticalPadding: CGFloat = 7
    public static let rowCornerRadius: CGFloat = 9
    public static let rowIconSpacing: CGFloat = 7
}

@available(macOS 26.0, *)
public struct OperaChromeSidebarList<Content: View>: View {
    private let spacing: CGFloat
    private let content: Content

    public init(
        spacing: CGFloat = OperaChromeSidebarMetrics.listSpacing,
        @ViewBuilder content: () -> Content
    ) {
        self.spacing = spacing
        self.content = content()
    }

    public var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: spacing) {
                content
            }
            .padding(.horizontal, OperaChromeSidebarMetrics.listHorizontalPadding)
            .padding(.vertical, OperaChromeSidebarMetrics.listVerticalPadding)
        }
        .scrollIndicators(.never)
        .background(OperaChromeTheme.panelBackground)
    }
}

@available(macOS 26.0, *)
public struct OperaChromeSidebarRow<Content: View>: View {
    private let isSelected: Bool
    private let isExternallyUpdated: Bool
    private let content: Content

    public init(
        isSelected: Bool = false,
        isExternallyUpdated: Bool = false,
        @ViewBuilder content: () -> Content
    ) {
        self.isSelected = isSelected
        self.isExternallyUpdated = isExternallyUpdated
        self.content = content()
    }

    public var body: some View {
        content
            .padding(.horizontal, OperaChromeSidebarMetrics.rowHorizontalPadding)
            .padding(.vertical, OperaChromeSidebarMetrics.rowVerticalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(rowBackground)
            .overlay {
                if isExternallyUpdated {
                    RoundedRectangle(
                        cornerRadius: OperaChromeSidebarMetrics.rowCornerRadius,
                        style: .continuous
                    )
                    .stroke(Color(red: 1.0, green: 0.83, blue: 0.36).opacity(0.75), lineWidth: 1)
                }
            }
    }

    private var rowBackground: some View {
        RoundedRectangle(
            cornerRadius: OperaChromeSidebarMetrics.rowCornerRadius,
            style: .continuous
        )
        .fill(isSelected ? OperaChromeTheme.selection : Color.clear)
        .overlay(
            RoundedRectangle(
                cornerRadius: OperaChromeSidebarMetrics.rowCornerRadius,
                style: .continuous
            )
            .stroke(
                isSelected ? OperaChromeTheme.accent.opacity(0.22) : Color.clear,
                lineWidth: 1
            )
        )
    }
}

@available(macOS 26.0, *)
public struct OperaChromeStatusBadge: View {
    private let title: String
    private let systemImage: String?
    private let showsProgress: Bool
    private let tint: Color?

    public init(
        title: String,
        systemImage: String = "arrow.triangle.2.circlepath",
        showsProgress: Bool = false
    ) {
        self.title = title
        self.systemImage = systemImage
        self.showsProgress = showsProgress
        self.tint = nil
    }

    public init(text: String, tint: Color) {
        self.title = text
        self.systemImage = nil
        self.showsProgress = false
        self.tint = tint
    }

    public var body: some View {
        Group {
            if let tint {
                Text(title)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(tint.opacity(0.95))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(
                        Capsule(style: .continuous)
                            .fill(tint.opacity(0.16))
                    )
            } else {
                HStack(spacing: 6) {
                    if showsProgress {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.8)
                    } else if let systemImage {
                        Image(systemName: systemImage)
                            .font(.system(size: 10, weight: .semibold))
                    }

                    Text(title)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                }
                .foregroundStyle(OperaChromeTheme.textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    Capsule(style: .continuous)
                        .fill(OperaChromeTheme.selection.opacity(0.42))
                )
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(OperaChromeTheme.accent.opacity(0.16), lineWidth: 1)
                )
            }
        }
    }
}

@available(macOS 26.0, *)
public struct OperaChromeActionButton: View {
    private let title: String?
    private let systemImage: String
    private let isSelected: Bool
    private let isProminent: Bool
    private let action: () -> Void

    public init(
        title: String? = nil,
        systemImage: String,
        isSelected: Bool = false,
        isProminent: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.isSelected = isSelected
        self.isProminent = isProminent
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: title == nil ? 0 : 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .medium))
                if let title {
                    Text(title)
                        .font(.system(size: 11, weight: .semibold))
                }
            }
            .foregroundStyle(foregroundColor)
            .padding(.horizontal, title == nil ? 8 : 11)
            .padding(.vertical, 7)
            .frame(minHeight: 28)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(backgroundColor)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(borderColor, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }

    private var foregroundColor: Color {
        if isProminent {
            return .black.opacity(0.82)
        }
        if isSelected {
            return OperaChromeTheme.textPrimary
        }
        return OperaChromeTheme.textSecondary
    }

    private var backgroundColor: Color {
        if isProminent {
            return OperaChromeTheme.accent
        }
        if isSelected {
            return OperaChromeTheme.selection
        }
        return Color.clear
    }

    private var borderColor: Color {
        if isProminent {
            return OperaChromeTheme.accent.opacity(0.42)
        }
        if isSelected {
            return OperaChromeTheme.accent.opacity(0.24)
        }
        return Color.clear
    }
}

@available(macOS 26.0, *)
public struct OperaChromeTabItem<Selection: Hashable>: Identifiable {
    public let id: Selection
    public let title: String
    public let systemImage: String

    public init(id: Selection, title: String, systemImage: String) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
    }
}

@available(macOS 26.0, *)
public struct OperaChromeInspectorTabs<Selection: Hashable, Content: View>: View {
    @Binding private var selection: Selection
    private let tabs: [OperaChromeTabItem<Selection>]
    private let content: (Selection) -> Content

    public init(
        selection: Binding<Selection>,
        tabs: [OperaChromeTabItem<Selection>],
        @ViewBuilder content: @escaping (Selection) -> Content
    ) {
        _selection = selection
        self.tabs = tabs
        self.content = content
    }

    public var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(tabs.enumerated()), id: \.offset) { _, tab in
                        Button {
                            selection = tab.id
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: tab.systemImage)
                                    .font(.system(size: 10, weight: .medium))
                                Text(tab.title)
                                    .font(.system(size: 11, weight: .semibold))
                            }
                            .foregroundStyle(selection == tab.id ? OperaChromeTheme.textPrimary : OperaChromeTheme.textSecondary)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 7)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(selection == tab.id ? OperaChromeTheme.selection : Color.clear)
                            )
                            .overlay(
                                Capsule(style: .continuous)
                                    .stroke(
                                        selection == tab.id
                                            ? OperaChromeTheme.accent.opacity(0.28)
                                            : Color.clear,
                                        lineWidth: 1
                                    )
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .background(OperaChromeTheme.headerBackground)

            OperaChromeDivider()

            content(selection)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(OperaChromeTheme.panelBackground)
        }
        .background(OperaChromeTheme.panelBackground)
    }
}

@available(macOS 26.0, *)
public struct OperaChromeSplitHandle: View {
    private let onDragChanged: (CGFloat) -> Void
    private let onDragEnded: () -> Void
    @State private var isHovering = false
    @State private var dragStartX: CGFloat?
    @State private var lastTranslation: CGFloat = 0

    public init(
        onDragChanged: @escaping (CGFloat) -> Void,
        onDragEnded: @escaping () -> Void = {}
    ) {
        self.onDragChanged = onDragChanged
        self.onDragEnded = onDragEnded
    }

    public var body: some View {
        ZStack {
            Rectangle()
                .fill(Color.clear)
                .frame(width: 10)

            Rectangle()
                .fill(isHovering ? OperaChromeTheme.accent.opacity(0.42) : OperaChromeTheme.divider)
                .frame(width: 1)
                .padding(.vertical, 6)
        }
        .frame(width: 10)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering
        }
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    if dragStartX == nil {
                        dragStartX = value.location.x
                        lastTranslation = 0
                    }
                    let currentX = value.location.x
                    let delta = currentX - dragStartX!
                    // Only report the delta from the last update
                    let deltaDiff = delta - lastTranslation
                    lastTranslation = delta
                    onDragChanged(deltaDiff)
                }
                .onEnded { _ in
                    dragStartX = nil
                    lastTranslation = 0
                    onDragEnded()
                }
        )
    }
}

@available(macOS 26.0, *)
public struct OperaChromeEmptyState: View {
    private let systemImage: String
    private let title: String
    private let message: String
    private let buttonTitle: String?
    private let buttonAction: (() -> Void)?

    public init(
        systemImage: String,
        title: String,
        message: String,
        buttonTitle: String? = nil,
        buttonAction: (() -> Void)? = nil
    ) {
        self.systemImage = systemImage
        self.title = title
        self.message = message
        self.buttonTitle = buttonTitle
        self.buttonAction = buttonAction
    }

    public var body: some View {
        VStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(OperaChromeTheme.textTertiary)
            Text(title)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(OperaChromeTheme.textPrimary)
            Text(message)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(OperaChromeTheme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            if let buttonTitle, let buttonAction {
                OperaChromeActionButton(
                    title: buttonTitle,
                    systemImage: "server.rack",
                    isProminent: true,
                    action: buttonAction
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(28)
        .background(OperaChromeTheme.workspaceBackground)
    }
}

// MARK: - Shared Save Indicator State

public enum SaveIndicatorState: Equatable, Sendable {
    case idle
    case saving
    case saved
}

// MARK: - Compact Save Indicator (for the shell tab bar)

@available(macOS 26.0, *)
public struct OperaChromeCompactSaveIndicator: View {
    public let state: SaveIndicatorState

    public init(state: SaveIndicatorState) {
        self.state = state
    }

    public var body: some View {
        Group {
            switch state {
            case .saving:
                HStack(spacing: 4) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Saving...")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(OperaChromeTheme.textSecondary)
                }
                .transition(.opacity)
            case .saved:
                HStack(spacing: 3) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(OperaChromeTheme.success)
                    Text("Saved")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(OperaChromeTheme.textSecondary)
                }
                .transition(.opacity)
            case .idle:
                EmptyView()
            }
        }
        .animation(.easeInOut(duration: 0.2), value: state)
    }
}
#endif
