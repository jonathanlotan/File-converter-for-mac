import AppKit

// A menu bar app (LSUIElement): no Dock icon and no main menu, so the
// AppKit entry point is set up by hand instead of with a storyboard or a
// SwiftUI App (whose MenuBarExtra can't accept dropped files).
let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
NSApplication.shared.run()
