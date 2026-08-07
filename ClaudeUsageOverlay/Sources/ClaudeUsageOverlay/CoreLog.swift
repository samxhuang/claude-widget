import Foundation

// Windows-port seam (docs/swift-windows-audit.md §1.9).
//
// `NSLog` has no Windows equivalent worth using: it exists, but CoreFoundation
// routes it to stderr only (no OutputDebugString), and in a DLL stderr is
// usually nowhere. The call sites also used ObjC printf specifiers (`%@`) with
// Swift Strings, which is the category of thing that prints garbage rather
// than failing to compile. Everything in this directory logs through `CoreLog`
// now; the platform default keeps macOS output byte-identical to the old
// `NSLog` lines (Console.app / launchd stderr, same "[Component] message"
// text), and a host can redirect by installing `CoreLog.sink`.

public enum CoreLogLevel: Int32 {
    case debug = 0
    case info = 1
    case warn = 2
    case error = 3
}

public enum CoreLog {
    /// Host-installed sink. Unset means "use the platform default" below; an
    /// FFI host installs a C callback into its own logger instead. Written
    /// once at startup, if at all — not synchronized.
    nonisolated(unsafe) public static var sink: ((CoreLogLevel, String) -> Void)?

    public static func debug(_ message: @autoclosure () -> String) { emit(.debug, message()) }
    public static func info(_ message: @autoclosure () -> String) { emit(.info, message()) }
    public static func warn(_ message: @autoclosure () -> String) { emit(.warn, message()) }
    public static func error(_ message: @autoclosure () -> String) { emit(.error, message()) }

    private static func emit(_ level: CoreLogLevel, _ message: String) {
        if let sink = sink {
            sink(level, message)
            return
        }
        platformLog(message)
    }

    #if canImport(Darwin)
    private static func platformLog(_ message: String) {
        // "%@" with the message as an argument, never as the format string
        // itself — a message carrying a stray `%` (an error description, a
        // session title) would otherwise be interpreted as a format specifier.
        NSLog("%@", message)
    }
    #else
    private static func platformLog(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
    #endif
}
