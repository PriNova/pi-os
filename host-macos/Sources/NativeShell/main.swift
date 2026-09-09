import AppKit

// Only the app executable enters AppKit. Pure helper tests never call this.
let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
withExtendedLifetime(delegate) {
    application.run()
}
