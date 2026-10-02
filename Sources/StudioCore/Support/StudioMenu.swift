import Observation
import SwiftUI

// MARK: - Dropdown

/// A dropdown drawn as a studio control.
///
/// The trigger is an ordinary studio button, so it shares chrome, hover and sizing
/// with every other control. The menu itself is a popover panel of drawn rows
/// rather than a system menu, which AppKit would paint with its own highlight and
/// checkmarks. Fill it with the `StudioMenu…` rows below; a `StudioSubmenu` drills
/// into the same panel instead of opening a second one.
public struct StudioMenu<Content: View, Label: View>: View {
    private let prominence: StudioControlProminence
    private let isIconOnly: Bool
    private let panelWidth: CGFloat
    private let fillsWidth: Bool
    private let content: Content
    private let label: Label
    @State private var isPresented = false

    /// - Parameters:
    ///   - iconOnly: draws the label as a round icon button.
    ///   - width: the width of the dropdown panel.
    ///   - fillsWidth: lets the trigger take the width it is offered, for form fields.
    public init(
        _ prominence: StudioControlProminence = .secondary,
        iconOnly: Bool = false,
        width: CGFloat = 232,
        fillsWidth: Bool = false,
        @ViewBuilder content: () -> Content,
        @ViewBuilder label: () -> Label
    ) {
        self.prominence = prominence
        self.isIconOnly = iconOnly
        self.panelWidth = width
        self.fillsWidth = fillsWidth
        self.content = content()
        self.label = label()
    }

    public var body: some View {
        trigger
            .buttonStyle(StudioMenuTriggerStyle(prominence: prominence, isIconOnly: isIconOnly))
            .fixedSize(horizontal: !fillsWidth, vertical: true)
    }

    private var trigger: some View {
        Button { isPresented.toggle() } label: { label }
            .studioControlActive(isPresented)
            .popover(isPresented: $isPresented, arrowEdge: .bottom) {
                StudioMenuPanel(width: panelWidth) { content }
            }
    }
}

/// Draws a menu trigger as the studio button it is. The icon or text choice lives
/// in the style, so the popover's host keeps its identity if a toolbar switches a
/// trigger between the two while its dropdown is open.
private struct StudioMenuTriggerStyle: ButtonStyle {
    let prominence: StudioControlProminence
    let isIconOnly: Bool

    @ViewBuilder
    func makeBody(configuration: Configuration) -> some View {
        if isIconOnly {
            StudioIconButtonStyle(prominence).makeBody(configuration: configuration)
        } else {
            StudioButtonStyle(prominence).makeBody(configuration: configuration)
        }
    }
}

/// The popover behind a `StudioMenu`: the current page of rows, with a back row
/// when a submenu is open. A long page scrolls under a pinned back row.
struct StudioMenuPanel<Content: View>: View {
    private let width: CGFloat
    private let content: Content
    @State private var controller = StudioMenuController()

    init(width: CGFloat, @ViewBuilder content: () -> Content) {
        self.width = width
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let page = controller.pages.last {
                Button { controller.pop() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 10, weight: .bold))
                            .frame(width: 12)
                        Text(page.title)
                            .font(.system(size: 12.5, weight: .semibold))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                }
                .buttonStyle(.studioRow)
                .padding(.horizontal, 6)
                .padding(.top, 6)
                .accessibilityLabel("Back from \(page.title)")
                StudioMenuDivider()
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    if let page = controller.pages.last {
                        page.content
                    } else {
                        content
                    }
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: 360)
        }
        .frame(width: width)
        .fixedSize(horizontal: false, vertical: true)
        .environment(controller)
        // A popover follows the system appearance even when it opens from a pane,
        // and must not inherit the trigger's lit state.
        .studioSurface(.adaptive)
        .studioControlActive(false)
    }
}

/// The drill-down stack of one open dropdown. Rows find it in the environment;
/// rows outside a studio dropdown, such as in the menu bar, find none and draw as
/// ordinary system menu items, so one definition of a menu serves both.
@MainActor
@Observable
final class StudioMenuController {
    struct Page: Identifiable {
        let id = UUID()
        let title: String
        let content: AnyView
    }

    private(set) var pages: [Page] = []

    func push(_ title: String, content: AnyView) {
        pages.append(Page(title: title, content: content))
    }

    func pop() {
        _ = pages.popLast()
    }
}

/// Closes the dropdown first, then runs the action on the next turn, so an action
/// that opens a sheet or a file panel does not race the popover going away.
@MainActor
private func studioMenuRun(_ action: @escaping @MainActor () -> Void, dismiss: DismissAction) {
    dismiss()
    Task { @MainActor in action() }
}

// MARK: - Rows

/// The trailing mark of a menu row.
private enum StudioMenuAccessory {
    case none
    case chevron
    case toggle(Bool)
}

/// One menu row's content: a check or icon column, the title, and a trailing mark.
/// The row button style supplies the hover fill and the ink.
private struct StudioMenuRowLabel: View {
    let title: String
    var systemImage: String?
    /// `nil` for no check column; otherwise every row of a choice list reserves the
    /// column so titles line up, and the selected one shows the mark.
    var check: Bool?
    var accessory: StudioMenuAccessory = .none
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.studioSurface) private var surface

    var body: some View {
        let ink = StudioInk(surface: surface, colorScheme: colorScheme)
        HStack(spacing: 8) {
            if let check {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 12)
                    .opacity(check ? 1 : 0)
            } else if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(ink.secondary)
                    .frame(width: 16)
            }
            Text(title)
                .font(.system(size: 12.5))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 12)
            switch accessory {
            case .none:
                EmptyView()
            case .chevron:
                Image(systemName: "chevron.right")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(ink.tertiary)
            case .toggle(let isOn):
                StudioSwitch(isOn: isOn)
            }
        }
    }
}

/// A small on/off switch drawn in the studio ink.
struct StudioSwitch: View {
    let isOn: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.studioSurface) private var surface

    var body: some View {
        let ink = StudioInk(surface: surface, colorScheme: colorScheme)
        let knob: Color = isOn ? (ink.isDark ? .black : .white) : (ink.isDark ? Color.white.opacity(0.85) : .white)
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule().fill(isOn ? ink.base.opacity(0.88) : ink.tint(0.16))
            Circle()
                .fill(knob)
                .shadow(color: Color.black.opacity(0.22), radius: 0.8, y: 0.5)
                .padding(2)
        }
        .frame(width: 26, height: 15)
        .animation(.easeOut(duration: 0.14), value: isOn)
        .accessibilityHidden(true)
    }
}

/// A command. Closes the dropdown, then runs.
public struct StudioMenuItem: View {
    private let title: String
    private let systemImage: String?
    private let role: ButtonRole?
    private let action: @MainActor () -> Void
    @Environment(StudioMenuController.self) private var controller: StudioMenuController?
    @Environment(\.dismiss) private var dismiss

    public init(
        _ title: String,
        systemImage: String? = nil,
        role: ButtonRole? = nil,
        action: @escaping @MainActor () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.role = role
        self.action = action
    }

    public var body: some View {
        if controller == nil {
            Button(role: role, action: action) {
                if let systemImage {
                    Label(title, systemImage: systemImage)
                } else {
                    Text(title)
                }
            }
        } else {
            Button(role: role) {
                studioMenuRun(action, dismiss: dismiss)
            } label: {
                StudioMenuRowLabel(title: title, systemImage: systemImage)
            }
            .buttonStyle(.studioRow)
        }
    }
}

/// A setting that is on or off. Flips in place and leaves the dropdown open, so
/// several can be changed in one visit.
public struct StudioMenuToggle: View {
    private let title: String
    private let help: String?
    @Binding private var isOn: Bool
    @Environment(StudioMenuController.self) private var controller: StudioMenuController?

    public init(_ title: String, isOn: Binding<Bool>, help: String? = nil) {
        self.title = title
        self.help = help
        _isOn = isOn
    }

    public var body: some View {
        if controller == nil {
            Toggle(title, isOn: $isOn)
                .help(help ?? "")
        } else {
            Button { isOn.toggle() } label: {
                StudioMenuRowLabel(title: title, accessory: .toggle(isOn))
            }
            .buttonStyle(.studioRow)
            .help(help ?? "")
            .accessibilityValue(isOn ? "On" : "Off")
        }
    }
}

/// One of several exclusive options, marked with a check. Closes the dropdown.
public struct StudioMenuChoice: View {
    private let title: String
    private let isSelected: Bool
    private let action: @MainActor () -> Void
    @Environment(StudioMenuController.self) private var controller: StudioMenuController?
    @Environment(\.dismiss) private var dismiss

    public init(_ title: String, isSelected: Bool, action: @escaping @MainActor () -> Void) {
        self.title = title
        self.isSelected = isSelected
        self.action = action
    }

    public var body: some View {
        if controller == nil {
            Toggle(title, isOn: Binding(get: { isSelected }, set: { _ in action() }))
        } else {
            Button {
                studioMenuRun(action, dismiss: dismiss)
            } label: {
                StudioMenuRowLabel(title: title, check: isSelected)
            }
            .buttonStyle(.studioRow)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        }
    }
}

/// A list of exclusive options bound to one value, the dropdown counterpart of
/// `StudioSegmentedPicker`.
public struct StudioMenuPicker<Value: Hashable>: View {
    private let options: [(title: String, value: Value)]
    @Binding private var selection: Value

    public init(_ options: [(title: String, value: Value)], selection: Binding<Value>) {
        self.options = options
        _selection = selection
    }

    public var body: some View {
        ForEach(options.indices, id: \.self) { index in
            let option = options[index]
            StudioMenuChoice(option.title, isSelected: option.value == selection) {
                selection = option.value
            }
        }
    }
}

/// A row that opens another page of the same dropdown. In the menu bar it is an
/// ordinary submenu.
public struct StudioSubmenu<Content: View>: View {
    private let title: String
    private let systemImage: String?
    private let content: Content
    @Environment(StudioMenuController.self) private var controller: StudioMenuController?

    public init(_ title: String, systemImage: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.content = content()
    }

    public var body: some View {
        if let controller {
            Button {
                controller.push(title, content: AnyView(content))
            } label: {
                StudioMenuRowLabel(title: title, systemImage: systemImage, accessory: .chevron)
            }
            .buttonStyle(.studioRow)
        } else {
            Menu {
                content
            } label: {
                if let systemImage {
                    Label(title, systemImage: systemImage)
                } else {
                    Text(title)
                }
            }
        }
    }
}

/// A short caption above a group of rows. Read-only, so it is drawn as a quiet
/// header rather than a dimmed command.
public struct StudioMenuHeader: View {
    private let title: String
    @Environment(StudioMenuController.self) private var controller: StudioMenuController?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.studioSurface) private var surface

    public init(_ title: String) {
        self.title = title
    }

    public var body: some View {
        if controller == nil {
            Text(title)
        } else {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(StudioInk(surface: surface, colorScheme: colorScheme).secondary)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A hairline between groups of rows.
public struct StudioMenuDivider: View {
    @Environment(StudioMenuController.self) private var controller: StudioMenuController?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.studioSurface) private var surface

    public init() {}

    public var body: some View {
        if controller == nil {
            Divider()
        } else {
            Rectangle()
                .fill(StudioInk(surface: surface, colorScheme: colorScheme).tint(0.09))
                .frame(height: 1)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
        }
    }
}

// MARK: - Select

/// A form field that picks one value from a list: the current choice with a
/// chevron, opening the same dropdown as `StudioMenu`. Replaces the system
/// pop-up button. It takes the width it is offered, so size it with `.frame`
/// or a grid column.
public struct StudioSelect<Value: Hashable>: View {
    private let name: String
    private let options: [(title: String, value: Value)]
    private let placeholder: String
    @Binding private var selection: Value

    /// - Parameter name: what the field is for, such as "Column". It is the
    ///   accessibility label, with the current choice as its value.
    public init(
        _ name: String,
        options: [(title: String, value: Value)],
        selection: Binding<Value>,
        placeholder: String = "Select"
    ) {
        self.name = name
        self.options = options
        self.placeholder = placeholder
        _selection = selection
    }

    private var selectedTitle: String {
        options.first { $0.value == selection }?.title ?? placeholder
    }

    public var body: some View {
        StudioMenu(.secondary, width: 280, fillsWidth: true) {
            StudioMenuPicker(options, selection: $selection)
        } label: {
            HStack(spacing: 6) {
                Text(selectedTitle)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8.5, weight: .bold))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityLabel(name)
        .accessibilityValue(selectedTitle)
    }
}
