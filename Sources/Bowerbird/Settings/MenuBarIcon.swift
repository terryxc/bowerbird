import AppKit

/// Candidate menu bar icons.
///
/// All are template images that the system tints to match the menu bar, so only the shape matters
/// here, not the colour. At 18 pt tall no interior detail is legible, so every choice has a clear
/// outline.
///
/// Always system symbols, never our own bird. The Dock wants a logo; the menu bar wants a function
/// symbol, and those don't need to be the same thing. A bird version was actually drawn: at 18 px,
/// whether full body, head or just the beak, it came out as a blob, while Apple's symbols naturally
/// share a stroke style with the system icons next to them.
enum MenuBarIcon: String, CaseIterable, Identifiable, Codable {
    case clipboard
    case scissors
    case paperclip
    case tray

    var id: String { rawValue }

    var title: String {
        switch self {
        case .clipboard: "Clipboard"
        case .scissors: "Scissors"
        case .paperclip: "Paperclip"
        case .tray: "Tray"
        }
    }

    private var symbolName: String {
        switch self {
        case .clipboard: "list.clipboard"
        case .scissors: "scissors"
        case .paperclip: "paperclip"
        case .tray: "tray.full"
        }
    }

    func image() -> NSImage? {
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: title)
        image?.isTemplate = true
        image?.size = NSSize(width: 18, height: 18)
        return image
    }
}
