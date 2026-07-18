import Cocoa

// Plain main.swift (no @main attribute needed) so we can run this as a normal
// AppKit app from a Swift Package executable target — no Xcode project or
// Info.plist required.

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
