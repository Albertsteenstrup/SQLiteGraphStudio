import SwiftUI

/// How much visual weight a control carries. Pane chrome is mostly `.secondary`
/// or `.quiet`; `.primary` is kept for the one action a surface exists for.
public enum StudioControlProminence: Sendable {
    /// Solid ink capsule with light text.
    case primary
    /// Faint tinted capsule, no border.
    case secondary
    /// Text only until hovered.
    case quiet
}

/// What a control is drawn on. The panes, the graph canvas and their chrome use
/// the fixed light `StudioPalette` whatever the system appearance, so controls
/// there keep dark ink. Popovers, sheets and material overlays follow the system
/// appearance, so controls there must too.
public enum StudioSurface: Sendable {
    case adaptive
    case light
}

extension EnvironmentValues {
    @Entry var studioSurface: StudioSurface = .adaptive
    /// True while the control's own dropdown or popover is open, so it stays lit.
    @Entry var studioControlActive: Bool = false
}

public extension View {
    /// Declares the surface for the studio controls inside. Presentations inherit
    /// it, so a popover opened from a pane declares `.adaptive` again.
    func studioSurface(_ surface: StudioSurface) -> some View {
        environment(\.studioSurface, surface)
    }
}

extension View {
    /// Keeps the studio button this wraps drawn as pressed while `isActive`, for a
    /// trigger whose dropdown is open.
    func studioControlActive(_ isActive: Bool) -> some View {
        environment(\.studioControlActive, isActive)
    }
}

/// Ink for one surface: black on the light palette, white on a dark system surface.
struct StudioInk {
    let isDark: Bool

    init(surface: StudioSurface, colorScheme: ColorScheme) {
        isDark = surface == .adaptive && colorScheme == .dark
    }

    var base: Color { isDark ? .white : .black }
    var primary: Color { isDark ? Color.white.opacity(0.92) : StudioPalette.primaryText }
    var secondary: Color { isDark ? Color.white.opacity(0.6) : StudioPalette.secondaryText }
    var tertiary: Color { isDark ? Color.white.opacity(0.38) : StudioPalette.tertiaryText }
    /// Scales the faint tints, which need more weight to read on a dark surface.
    func tint(_ light: Double) -> Color { base.opacity(isDark ? light * 1.6 : light) }
}

/// Sizes follow the environment's control size so `.controlSize(.small)` keeps working.
struct StudioControlMetrics {
    let height: CGFloat
    let horizontalPadding: CGFloat
    let fontSize: CGFloat

    init(_ size: ControlSize) {
        switch size {
        case .mini: (height, horizontalPadding, fontSize) = (20, 8, 10.5)
        case .small: (height, horizontalPadding, fontSize) = (24, 10, 11.5)
        case .large, .extraLarge: (height, horizontalPadding, fontSize) = (34, 16, 13.5)
        default: (height, horizontalPadding, fontSize) = (28, 12, 12.5)
        }
    }
}

/// The fill and ink every studio control shares, so buttons, menus and chips
/// respond to hover and press the same way.
struct StudioControlChrome {
    let prominence: StudioControlProminence
    let ink: StudioInk
    let isDestructive: Bool
    let isHovered: Bool
    let isPressed: Bool
    let isEnabled: Bool

    static let destructiveInk = Color(red: 0.78, green: 0.18, blue: 0.16)

    var fill: Color {
        switch prominence {
        case .primary:
            let base = isDestructive ? Color(red: 0.82, green: 0.2, blue: 0.18) : ink.base
            if !isEnabled { return base.opacity(0.28) }
            return base.opacity(isPressed ? 0.7 : isHovered ? 0.8 : 0.9)
        case .secondary:
            if !isEnabled { return ink.tint(0.03) }
            return ink.tint(isPressed ? 0.12 : isHovered ? 0.085 : 0.055)
        case .quiet:
            if !isEnabled { return .clear }
            return ink.tint(isPressed ? 0.09 : isHovered ? 0.05 : 0)
        }
    }

    var foreground: Color {
        if prominence == .primary {
            let text: Color = ink.isDark && !isDestructive ? .black : .white
            return text.opacity(isEnabled ? 1 : 0.85)
        }
        if isDestructive { return Self.destructiveInk.opacity(isEnabled ? 1 : 0.4) }
        guard isEnabled else { return ink.tertiary }
        if prominence == .quiet, !(isHovered || isPressed) { return ink.secondary }
        return ink.primary
    }
}

// MARK: - Buttons

/// A capsule button for in-pane chrome, replacing the system's bezeled push button.
public struct StudioButtonStyle: ButtonStyle {
    let prominence: StudioControlProminence

    public init(_ prominence: StudioControlProminence = .secondary) {
        self.prominence = prominence
    }

    public func makeBody(configuration: Configuration) -> some View {
        StudioButtonBody(configuration: configuration, prominence: prominence)
    }
}

private struct StudioButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let prominence: StudioControlProminence
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.studioSurface) private var surface
    @Environment(\.studioControlActive) private var isActive
    @State private var isHovered = false

    var body: some View {
        let metrics = StudioControlMetrics(controlSize)
        let chrome = StudioControlChrome(
            prominence: prominence,
            ink: StudioInk(surface: surface, colorScheme: colorScheme),
            isDestructive: configuration.role == .destructive,
            isHovered: isHovered,
            isPressed: configuration.isPressed || isActive,
            isEnabled: isEnabled
        )
        configuration.label
            .font(.system(size: metrics.fontSize, weight: .medium))
            .lineLimit(1)
            .foregroundStyle(chrome.foreground)
            .padding(.horizontal, metrics.horizontalPadding)
            .frame(minHeight: metrics.height)
            .background(Capsule().fill(chrome.fill))
            .contentShape(Capsule())
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovered)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

/// A round, icon-only button. Give it an `Image` label plus `.help` and an
/// accessibility label, since there is no visible title.
public struct StudioIconButtonStyle: ButtonStyle {
    let prominence: StudioControlProminence

    public init(_ prominence: StudioControlProminence = .quiet) {
        self.prominence = prominence
    }

    public func makeBody(configuration: Configuration) -> some View {
        StudioIconButtonBody(configuration: configuration, prominence: prominence)
    }
}

private struct StudioIconButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let prominence: StudioControlProminence
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.studioSurface) private var surface
    @Environment(\.studioControlActive) private var isActive
    @State private var isHovered = false

    var body: some View {
        let metrics = StudioControlMetrics(controlSize)
        let chrome = StudioControlChrome(
            prominence: prominence,
            ink: StudioInk(surface: surface, colorScheme: colorScheme),
            isDestructive: configuration.role == .destructive,
            isHovered: isHovered,
            isPressed: configuration.isPressed || isActive,
            isEnabled: isEnabled
        )
        configuration.label
            .labelStyle(.iconOnly)
            .font(.system(size: metrics.fontSize, weight: .semibold))
            .foregroundStyle(chrome.foreground)
            .frame(width: metrics.height, height: metrics.height)
            .background(Circle().fill(chrome.fill))
            .contentShape(Circle())
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovered)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

/// A full-width row in a popover or list that highlights under the pointer,
/// like a menu item.
public struct StudioRowButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        StudioRowButtonBody(configuration: configuration)
    }
}

private struct StudioRowButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.studioSurface) private var surface
    @State private var isHovered = false

    var body: some View {
        let ink = StudioInk(surface: surface, colorScheme: colorScheme)
        configuration.label
            .foregroundStyle(configuration.role == .destructive ? StudioControlChrome.destructiveInk : ink.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(ink.tint(configuration.isPressed ? 0.08 : isHovered && isEnabled ? 0.045 : 0))
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .opacity(isEnabled ? 1 : 0.4)
            .onHover { isHovered = $0 }
    }
}

public extension ButtonStyle where Self == StudioRowButtonStyle {
    static var studioRow: StudioRowButtonStyle { StudioRowButtonStyle() }
}

public extension ButtonStyle where Self == StudioButtonStyle {
    static var studio: StudioButtonStyle { StudioButtonStyle(.secondary) }
    static var studioPrimary: StudioButtonStyle { StudioButtonStyle(.primary) }
    static var studioQuiet: StudioButtonStyle { StudioButtonStyle(.quiet) }
}

public extension ButtonStyle where Self == StudioIconButtonStyle {
    static var studioIcon: StudioIconButtonStyle { StudioIconButtonStyle(.quiet) }
    static var studioIconTinted: StudioIconButtonStyle { StudioIconButtonStyle(.secondary) }
    static var studioIconPrimary: StudioIconButtonStyle { StudioIconButtonStyle(.primary) }
}

// MARK: - Segmented picker

/// A few mutually exclusive choices in a single capsule track, with the chosen
/// one raised.
public struct StudioSegmentedPicker<Value: Hashable>: View {
    private let options: [(title: String, value: Value)]
    @Binding private var selection: Value
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.studioSurface) private var surface

    public init(_ options: [(title: String, value: Value)], selection: Binding<Value>) {
        self.options = options
        _selection = selection
    }

    public var body: some View {
        let ink = StudioInk(surface: surface, colorScheme: colorScheme)
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index]
                let isSelected = option.value == selection
                Button { selection = option.value } label: {
                    Text(option.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(isSelected ? ink.primary : ink.secondary)
                        .padding(.horizontal, 12)
                        .frame(height: 24)
                        .background {
                            if isSelected {
                                Capsule()
                                    .fill(ink.isDark ? Color.white.opacity(0.16) : Color.white)
                                    .overlay { Capsule().strokeBorder(ink.tint(0.08), lineWidth: 1) }
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Capsule().fill(ink.tint(0.05)))
        .fixedSize()
        .animation(.easeOut(duration: 0.15), value: selection)
        // One group, so a label on the picker names it without replacing each segment's title.
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Tabs

/// A document tab: a raised capsule when active, bare text that tints on hover
/// otherwise. Tabs only live on the light panes, so their ink is fixed.
struct StudioTabChrome: ViewModifier {
    let isActive: Bool
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .font(.system(size: 12.5, weight: isActive ? .medium : .regular))
            .foregroundStyle(isActive ? StudioPalette.primaryText : StudioPalette.secondaryText)
            .padding(.leading, 12)
            .padding(.trailing, 5)
            .frame(height: 30)
            .background {
                Capsule()
                    .fill(isActive ? Color.white : Color.black.opacity(isHovered ? 0.045 : 0))
            }
            .overlay {
                Capsule().strokeBorder(Color.black.opacity(isActive ? 0.09 : 0), lineWidth: 1)
            }
            .contentShape(Capsule())
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovered)
            .studioSurface(.light)
    }
}

extension View {
    func studioTabChrome(isActive: Bool) -> some View {
        modifier(StudioTabChrome(isActive: isActive))
    }
}

/// The close control inside a `studioTabChrome` tab.
struct StudioTabCloseButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 8.5, weight: .bold))
        }
        .buttonStyle(.studioIcon)
        .controlSize(.mini)
        .help(title)
        .accessibilityLabel(title)
    }
}

// MARK: - Popover lists

/// One entry in a `StudioPopoverList`.
public struct StudioListItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let detail: String?
    public let tag: String?

    public init(id: String? = nil, title: String, detail: String? = nil, tag: String? = nil) {
        self.id = id ?? [title, detail ?? "", tag ?? ""].joined(separator: "\u{1F}")
        self.title = title
        self.detail = detail
        self.tag = tag
    }
}

/// A short, readable list shown in a popover. Replaces pull-down menus whose
/// items were only there to be read, which AppKit draws dimmed like disabled
/// commands.
public struct StudioPopoverList: View {
    let title: String
    let items: [StudioListItem]
    let wrapsTitles: Bool
    @Environment(\.colorScheme) private var colorScheme

    /// Identifiers read best on one line, truncated in the middle; prose such as
    /// notes should set `wrapsTitles`.
    public init(title: String, items: [StudioListItem], wrapsTitles: Bool = false) {
        self.title = title
        self.items = items
        self.wrapsTitles = wrapsTitles
    }

    /// A popover follows the system appearance even when it opens from a pane.
    private var ink: StudioInk { StudioInk(surface: .adaptive, colorScheme: colorScheme) }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(ink.secondary)
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 6)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(items) { item in
                        row(item)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 8)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: 320)
        }
        .frame(minWidth: 240, idealWidth: 300, maxWidth: 380, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
        .studioSurface(.adaptive)
    }

    private func row(_ item: StudioListItem) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(item.title)
                    .font(.system(size: 12.5, weight: wrapsTitles ? .regular : .medium))
                    .foregroundStyle(ink.primary)
                    .lineLimit(wrapsTitles ? nil : 1)
                    .truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: wrapsTitles)
                Spacer(minLength: 8)
                if let tag = item.tag {
                    Text(tag)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(ink.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(ink.tint(0.05)))
                }
            }
            if let detail = item.detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
