**English** | [简体中文](faq.zh-CN.md) | [繁體中文](faq.zh-TW.md) | [日本語](faq.ja.md) | [Español](faq.es.md) | [Français](faq.fr.md) | [Русский](faq.ru.md)

# FAQ

### Why does macOS block the first launch?

The app uses a self-signed certificate, without a Developer ID signature or Apple notarization. Allow it once under System Settings → Privacy & Security → Open Anyway, or run `xattr -d com.apple.quarantine /Applications/Bowerbird.app`.

### Why does it ask for Accessibility?

To press ⌘V in the app you came from when you hit Return. It asks the first time you paste. Without it, Return copies and you paste yourself.

### I granted Accessibility, but Return doesn't paste.

The grant is tied to the app's signature, and the switch can show as on while it still refers to an old signature. In System Settings → Privacy & Security → Accessibility, remove Bowerbird with "−" and add it back with "+".

### I revoked Accessibility, but the app still says it's granted.

macOS doesn't tell running apps. Quit and reopen Bowerbird.

### Does it need Screen Recording or Full Disk Access?

No. Images come from the clipboard, and files are stored as paths.

### Does it connect to the internet?

No. No telemetry, no update check, no sync.

### Where is my data?

`~/Library/Application Support/Bowerbird/`: a SQLite database plus image files, not encrypted. Settings are in `defaults` under `app.bowerbird.mac`.

### How do I delete everything?

Settings → History → Clear → Everything removes the history; pinned items have their own Clear button in the row below. Clear on Quit, in the same tab, does this every time you quit; pinned items stay. To remove every trace, quit the app and run:

```sh
rm -rf ~/Library/Application\ Support/Bowerbird
defaults delete app.bowerbird.mac
```

### What is never recorded?

- Anything a password manager marks as a password.
- Anything copied from an app on the ignore list. 1Password, Bitwarden and Keychain Access are on it by default.
- Text that matches one of your ignore patterns.
- Anything copied while recording is paused.

### How long is history kept?

Text and files 30 days, images 7 days. Change it in Settings → History. Pinned items are kept forever.

### Why don't my screenshots show up?

By default macOS saves a screenshot as a file on the Desktop and never puts it on the clipboard, so Bowerbird never sees it. Press ⌃⇧⌘4 to copy a screenshot to the clipboard instead, or press ⇧⌘5, open Options and set *Save to* to *Clipboard*.

### Does it see what I copy on my iPhone or iPad?

Text and images, if the option in Settings → History is on. Files are not.
