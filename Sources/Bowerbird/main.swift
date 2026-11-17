import AppKit

// If a Bowerbird is already running, hand the panel over to it and bow out. See SingleInstance.
guard SingleInstance.claim() else { exit(0) }

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
