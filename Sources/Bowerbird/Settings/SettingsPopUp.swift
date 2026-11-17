import AppKit
import SwiftUI

/// A pop-up menu in Settings: a real NSPopUpButton with a fixed width.
///
/// On macOS a SwiftUI Picker sizes itself to its content; frame(width:) only centres it inside that
/// frame, so three pop-ups in one column end up three different widths with ragged right edges.
/// NSPopUpButton draws at whatever width it's given, so the column lines up.
struct SettingsPopUp<Value: Hashable>: NSViewRepresentable {
    struct Option {
        let value: Value
        let title: String
        var image: NSImage? = nil
        var toolTip: String? = nil
        /// Draw a separator above this item
        var separatorBefore = false
    }

    @Binding var selection: Value
    let options: [Option]

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.controlSize = .small
        button.font = NSFont.systemFont(ofSize: NSFont.systemFontSize(for: .small))
        button.target = context.coordinator
        button.action = #selector(Coordinator.changed(_:))
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: SettingsMetrics.shortcutFieldWidth).isActive = true
        return button
    }

    @Environment(\.isEnabled) private var isEnabled

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.parent = self
        button.isEnabled = isEnabled
        let menu = NSMenu()
        for (index, option) in options.enumerated() {
            if option.separatorBefore { menu.addItem(.separator()) }
            let item = NSMenuItem(title: option.title, action: nil, keyEquivalent: "")
            item.tag = index
            item.toolTip = option.toolTip
            if let image = option.image {
                item.image = image
            }
            menu.addItem(item)
        }
        button.menu = menu
        if let index = options.firstIndex(where: { $0.value == selection }) {
            button.selectItem(withTag: index)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject {
        var parent: SettingsPopUp
        init(_ parent: SettingsPopUp) { self.parent = parent }

        // AppKit always sends control actions on the main thread; say so explicitly
        @MainActor @objc func changed(_ sender: NSPopUpButton) {
            let tag = sender.selectedTag()
            guard parent.options.indices.contains(tag) else { return }
            parent.selection = parent.options[tag].value
        }
    }
}

/// Placed at the right of a settings row: the fixed-width pop-up is right-aligned, its right edge in line
/// with the other controls
struct SettingsPopUpStyle: ViewModifier {
    func body(content: Content) -> some View {
        content.frame(width: SettingsMetrics.controlWidth, alignment: .trailing)
    }
}
