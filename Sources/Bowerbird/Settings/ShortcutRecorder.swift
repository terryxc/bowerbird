import AppKit
import KeyboardShortcuts
import SwiftUI

/// Recorder field for panel shortcuts.
///
/// Click to start recording, press a combination to record it, Esc cancels, ⌫ removes the shortcut
/// (or hover and click the ×). Letter keys must carry a modifier: while the panel is open the search
/// field always has focus, so a bare letter is typing and must not be swallowed as a shortcut.
/// Panel actions may use bare ↩, ⌅ and ⇥, which the search field has no use for.
/// Global hotkeys always require a modifier.

/// Which recorder is currently recording. Shared by every recorder on the settings page.
@MainActor
final class RecordingSession: ObservableObject {
    static let shared = RecordingSession()
    @Published var active: UUID? {
        didSet {
            // The global hotkey is a Carbon hotkey and bypasses the recorder's key monitor: pressing
            // ⇧⌘V into a field recorded it and summoned the panel over Settings. Disarm it meanwhile.
            guard (active == nil) != (oldValue == nil) else { return }
            if active == nil {
                KeyboardShortcuts.enable(.togglePanel)
            } else {
                KeyboardShortcuts.disable(.togglePanel)
            }
        }
    }
}

struct ShortcutRecorder: View {
    /// Whether this records an in-panel action or the global hotkey that summons the panel.
    /// Both use the same field: the global hotkey used to use the library's own recorder, white with
    /// a ×, which next to the grey fields in the rows below looked like it came from another app.
    enum Target {
        case panel(PanelAction)
        case togglePanel
    }

    let target: Target
    @ObservedObject private var settings = AppSettings.shared
    /// Only one field records at a time.
    ///
    /// If each field managed its own state, clicking A and then B would leave A's key monitor
    /// running: two monitors armed at once, the next key press eaten by whichever was installed
    /// first, and the key recorded against the other action.
    @ObservedObject private var session = RecordingSession.shared
    private let identity = UUID()
    private var recording: Bool { session.active == identity }
    @State private var hovering = false
    /// The global hotkey lives in the library, not in a @Published; bump this after changing it to redraw the view
    @State private var revision = 0

    /// nil means no shortcut
    private var display: String? {
        switch target {
        case .panel(let action): settings.shortcut(for: action)?.display
        // Not the library's `description`: for Space it looks the word up in the library's resource
        // bundle, which isn't inside the .app, and failing to find it is a fatal error. It only
        // worked on the machine that built the app, where the library falls back to the build folder.
        case .togglePanel: KeyboardShortcuts.getShortcut(for: .togglePanel).map(PanelShortcut.init)?.display
        }
    }

    /// Removes the shortcut. The action stays, just without a shortcut; the mouse still works.
    private func clear() {
        switch target {
        case .panel(let action): settings.panelShortcuts[action] = PanelShortcut.unbound
        case .togglePanel: KeyboardShortcuts.setShortcut(nil, for: .togglePanel)
        }
        revision += 1
    }

    var body: some View {
        // The field itself isn't a Button: the × is a Button, and nested inside another Button's label
        // the outer one swallows the click, so clicking × started recording. The field uses a tap
        // gesture and the × is a separate button.
        ZStack {
            RoundedRectangle(cornerRadius: Radius.chip + 2)
                .fill(recording ? AppColors.accentWash : AppColors.subtleFill)
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.chip + 2)
                        .strokeBorder(recording ? AppColors.accent : Color.clear,
                                      lineWidth: Hairline.width * 2)
                )
                .contentShape(Rectangle())
                .onTapGesture { session.active = recording ? nil : identity }
            Group {
                if recording {
                    Text("Press keys…")
                        .foregroundStyle(AppColors.accent)
                } else if let display {
                    Text(verbatim: display)
                        .foregroundStyle(Color.primary)
                } else {
                    Text("None")
                        .foregroundStyle(.tertiary)
                }
            }
            .font(.system(size: SettingsMetrics.rowTitleFontSize))
            .lineLimit(1)
            .allowsHitTesting(false)
            // The × that appears on hover removes the shortcut. Only shown when there is one.
            if hovering, !recording, display != nil {
                HStack {
                    Spacer()
                    Button(action: clear) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: SettingsMetrics.rowActionSymbolSize))
                            .foregroundStyle(.secondary)
                            .frame(width: SettingsMetrics.rowActionSize, height: SettingsMetrics.rowActionSize)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Remove Shortcut")
                }
                .padding(.trailing, 2)
            }
        }
        // The box itself is sized to its content-width tier, the same width as other rows' controls
        .frame(width: SettingsMetrics.shortcutFieldWidth, height: 22)
        .id(revision)
        // The key-capture layer sits in the background and explicitly opts out of hit testing;
        // inside the ZStack it would block clicks and recording could never start.
        .background(
            KeyCaptureView(recording: recording, onKey: record)
                .allowsHitTesting(false)
        )
        // Wrapped in a trailing-aligned controlWidth frame so the right edge lines up with other controls
        .frame(width: SettingsMetrics.controlWidth, alignment: .trailing)
        .onHover { hovering = $0 }
        .help(hint)
    }

    /// Each tooltip states its own rule: global hotkeys need a modifier, in-panel ↩, ⌅ and ⇥ don't.
    /// Both kinds used to share one sentence, which also said ⌫ "restores the default"; it actually removes the shortcut.
    private var hint: LocalizedStringKey {
        switch target {
        case .panel:
            "Click, then press the new keys (letters need ⌘, ⌥ or ⌃). Esc cancels, ⌫ removes the shortcut."
        case .togglePanel:
            "Click, then press a combination with ⌘, ⌥ or ⌃. Esc cancels, ⌫ removes the shortcut."
        }
    }

    /// Whether the key produces text: letters, digits, punctuation, space. Return, Tab, Delete and
    /// Escape are control characters; arrows and F-keys come through in the private-use range.
    static func typesCharacter(_ event: NSEvent) -> Bool {
        (event.charactersIgnoringModifiers ?? "").unicodeScalars.contains { scalar in
            !CharacterSet.controlCharacters.contains(scalar) && !(0xF700...0xF8FF).contains(scalar.value)
        }
    }

    private func record(_ event: NSEvent) {
        defer { session.active = nil; revision += 1 }
        // Esc cancels
        if event.keyCode == 53 { return }
        // Backspace alone: remove the shortcut
        if event.keyCode == 51,
           event.modifierFlags.intersection(PanelShortcut.relevantModifiers).isEmpty {
            clear()
            return
        }
        let modifiers = event.modifierFlags.intersection(PanelShortcut.relevantModifiers)
        // In the panel, bare Return and Tab are allowed (the search field has no use for them);
        // any other bare key would fight with typing, and a global one would eat normal input, so reject it
        let bareAllowed = [36, 76, 48].contains(Int(event.keyCode))
        if case .panel = target, modifiers.isEmpty, bareAllowed {
        } else {
            guard !modifiers.isEmpty else { return }
        }
        // ⇧ on its own doesn't make a typing key safe: ⇧A is just a capital A. As a global hotkey it
        // would swallow that letter in every app; in the panel it would swallow it in the search
        // field. Keys that type something need ⌘, ⌥ or ⌃. ⇧ still combines with keys that don't
        // type, like ⇧↩ or ⇧F5.
        if Self.typesCharacter(event), modifiers.subtracting(.shift).isEmpty { return }
        switch target {
        case .panel(let action):
            let shortcut = PanelShortcut(keyCode: event.keyCode, modifiers: modifiers)
            // One combination, one action. The panel takes the first action that matches, so a
            // second action given the same keys could never be reached, with nothing saying so.
            // The keys move to the action just recorded, as in System Settings.
            for other in PanelAction.allCases where other != action && settings.shortcut(for: other) == shortcut {
                settings.panelShortcuts[other] = PanelShortcut.unbound
            }
            settings.panelShortcuts[action] = shortcut
        case .togglePanel:
            if let shortcut = KeyboardShortcuts.Shortcut(event: event) {
                KeyboardShortcuts.setShortcut(shortcut, for: .togglePanel)
            }
        }
    }
}

/// The layer that actually captures keys. SwiftUI has no direct way to capture raw keyDown, so an NSView sits underneath.
private struct KeyCaptureView: NSViewRepresentable {
    let recording: Bool
    let onKey: (NSEvent) -> Void

    func makeNSView(context: Context) -> CaptureView {
        let view = CaptureView()
        view.onKey = onKey
        return view
    }

    func updateNSView(_ nsView: CaptureView, context: Context) {
        nsView.onKey = onKey
        nsView.isRecording = recording
    }

    final class CaptureView: NSView {
        var onKey: ((NSEvent) -> Void)?
        private var monitor: Any?

        var isRecording = false {
            didSet {
                guard isRecording != oldValue else { return }
                isRecording ? start() : stop()
            }
        }

        private func start() {
            stop()
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                // Only while the Settings window is on screen. It is closed, not released, so this
                // view never leaves it; a recording left open used to take the next key pressed in
                // the panel as the new shortcut.
                guard let self, self.window?.isVisible == true else {
                    RecordingSession.shared.active = nil
                    return event
                }
                self.onKey?(event)
                return nil   // swallow keys while recording so they don't trigger other actions
            }
        }

        private func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        /// Tear down when the view leaves its window. deinit can't touch main-actor-isolated state; the window callback is more reliable and earlier.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { stop() }
        }
        /// Doesn't block clicks underneath; clicks are handled by the SwiftUI layer
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
