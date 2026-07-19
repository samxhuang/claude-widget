import Cocoa
import SwiftUI

/// Stock-ticker-style expanded graph window (item 3). One shared instance,
/// same lifecycle pattern as LoginWindowController: `show()` re-shows it on
/// subsequent clicks rather than recreating it, and the close button hides
/// the window instead of tearing it down (so it never terminates the
/// accessory app, which has no other windows to fall back on).
final class GraphWindowController: NSWindowController, NSWindowDelegate {

    convenience init(graphModel: GraphModel) {
        // 560pt default height (rather than the more common ~500) leaves
        // enough room for both charts at their idealHeight (220 + 140) plus
        // every fixed-height row around them (period picker, section
        // headers, axis labels, hover readout bar, optional coverage note)
        // without anything clipping — see ExpandedGraphView's minHeight
        // comments for the underlying budget.
        let frame = NSRect(x: 0, y: 0, width: 800, height: 560)
        let hosting = NSHostingView(rootView: ExpandedGraphView(model: graphModel))

        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Claude Usage — Graph"
        window.contentView = hosting
        // Height floor matches the two charts' combined minHeight (150+90)
        // plus the fixed rows around them, so shrinking the window can't
        // clip content the way the un-audited default height briefly did
        // during development (item 1's lesson generalized here).
        window.minSize = NSSize(width: 520, height: 520)
        // Remembers the user's resize/move across launches — same spirit as
        // the panel's own position persistence, but window-manager-native
        // since this is a normal titled window rather than the borderless
        // anchored panel.
        window.setFrameAutosaveName("GraphWindow")
        if window.setFrameUsingName("GraphWindow") == false {
            window.center()
        }

        self.init(window: window)
        window.delegate = self
    }

    func show() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Closing the window (red traffic light, ⌘W) hides it instead of
    /// destroying it — `show()` re-shows the same instance next time, and
    /// the app (an accessory app with no Dock icon / other windows) never
    /// terminates just because this one closed.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
}
