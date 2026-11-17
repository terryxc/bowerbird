import AppKit
import SwiftUI

/// Right-click menu on a row: on right-click, first move the selection to this row, then show the
/// items that fit this entry.
///
/// Why not SwiftUI's `.contextMenu`: its content is built ahead of time along with the view, and the
/// closure isn't re-run at the moment it pops up, so there is no point at which to "change the
/// selection before showing".
///
/// Why each row handles it itself, rather than one global monitor on the panel mapping coordinates
/// back to a row: in AppKit this is the control's own job. NSTableView uses `row(at:)` on
/// right-click to find the row, then supplies the menu from `menu(for:)`; SwiftUI's `List` has
/// `contextMenu(forSelectionType:)` too. Our list is hand-built on LazyVStack (for section headers,
/// delete animations and batched loading) and gets none of that, so following NSTableView's approach
/// we add one per row: whoever is right-clicked knows it. Mapping coordinates back was tried; row
/// rects had to be reported all the way up, and right-clicks in the preview on the right were
/// mistaken for list rows.
///
/// This view only responds to right-clicks: `hitTest` returns nil for every other event, so left
/// clicks, double-clicks and drags all fall through to the SwiftUI underneath as usual.
struct RowContextMenu: NSViewRepresentable {
    struct Entry {
        let title: String
        /// The keycap in the right column. Menus already have two columns, "action on the left, key on
        /// the right"; with the right column empty, short two-character verbs (in Chinese) shrink the
        /// whole menu into a little square.
        var key: (equivalent: String, modifiers: NSEvent.ModifierFlags)?
        var separatorBefore = false
        let action: () -> Void
    }

        /// Asked only at right-click time, giving the type and state as of that moment
    let entries: () -> [Entry]
        /// Move the selection to this row before showing
    let onOpen: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = RightClickView()
        view.owner = self
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        (view as? RightClickView)?.owner = self
    }

    final class RightClickView: NSView {
        var owner: RowContextMenu?

        /// Takes right-clicks and ⌃-left-clicks; for every other event this view acts as if it isn't
        /// there, so ordinary clicks, double-clicks and drags reach the row underneath.
        ///
        /// ⌃-left-click used to be passed through on the theory that AppKit would open the contextual
        /// menu by itself. It does, but only for the view that was hit, which was then the hosting
        /// view with no menu: on a real ⌃-click the row was merely selected and no
        /// menu appeared. The panel is no longer draggable by its background, so taking the click
        /// here can't drag the panel away either.
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent else { return nil }
            switch event.type {
            case .rightMouseDown, .rightMouseUp, .rightMouseDragged:
                return super.hitTest(point)
            case .leftMouseDown, .leftMouseUp, .leftMouseDragged:
                return event.modifierFlags.contains(.control) ? super.hitTest(point) : nil
            default:
                return nil
            }
        }

        /// AppKit sends a ⌃-left-click here as an ordinary mouseDown; show the same menu a right-click gets.
        override func mouseDown(with event: NSEvent) {
            guard event.modifierFlags.contains(.control), let menu = menu(for: event) else {
                super.mouseDown(with: event)
                return
            }
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }

        override func menu(for event: NSEvent) -> NSMenu? {
            guard let owner else { return nil }
            owner.onOpen()
            let menu = NSMenu()
            // Right-clicking different rows in the same list shouldn't make the menu width jump around.
            // The text and file menus are naturally 176 pt (stretched by the zh-Hans items
            // "粘贴为纯文本 ⇧⌘↩" (Paste as Plain Text) and "在访达中显示" (Show in Finder)), while the
            // image menu has only four two-character verbs and shrinks to 108 pt, like a little square.
            // A minimum keeps all four kinds the same width; in other languages with longer words it
            // grows to its natural width. This is a floor, not a ceiling.
            menu.minimumWidth = 176
            for entry in owner.entries() {
                if entry.separatorBefore { menu.addItem(.separator()) }
                let item = NSMenuItem(title: entry.title, action: #selector(run(_:)),
                                      keyEquivalent: entry.key?.equivalent ?? "")
                item.keyEquivalentModifierMask = entry.key?.modifiers ?? []
                item.target = self
                item.representedObject = Handler(entry.action)
                menu.addItem(item)
            }
            return menu
        }

        @objc private func run(_ sender: NSMenuItem) {
            (sender.representedObject as? Handler)?.action()
        }

        private final class Handler {
            let action: () -> Void
            init(_ action: @escaping () -> Void) { self.action = action }
        }
    }
}
