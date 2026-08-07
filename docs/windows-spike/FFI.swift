// Steps 3 and 7 of the Windows spike.
// Drop in as C:\spike\ProbeFFI\Sources\ProbeFFI\FFI.swift.
//
// Both functions MUST be `public` AND live in a target named directly in the
// .dynamic product's `targets:` array — SwiftPM passes -static to every Swift
// module on Windows, which strips dllexport. A function in a merely-depended-on
// target compiles, links, and silently vanishes from the export table.
import Foundation

@_cdecl("probe_hello")
public func probe_hello(_ name: UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>? {
    let who = name.map { String(cString: $0) } ?? "world"
    let obj: [String: Any] = ["ok": true, "greeting": "hello \(who)"]
    let data = try! JSONSerialization.data(withJSONObject: obj)
    let s = String(decoding: data, as: UTF8.self)
    return strdup(s)          // core-allocated; freed by probe_free below
}

@_cdecl("probe_free")
public func probe_free(_ p: UnsafeMutablePointer<CChar>?) {
    // If the process dies here, it's a cross-CRT free: the DLL's allocator and
    // the host's differ, and the real design needs a Swift-side allocator
    // exported too.
    free(p)
}

// Step 7. Expected finding: "returning from probe_main_queue" prints and
// "MAIN QUEUE RAN" never does — libdispatch's main queue has no runloop
// draining it inside a .NET-hosted Swift DLL. If that holds, every
// DispatchQueue.main.async in the shared core needs a scheduler seam and every
// FFI entry point must stay synchronous (never async, never @MainActor —
// those silently never run, while plain C functions work).
@_cdecl("probe_main_queue")
public func probe_main_queue() {
    DispatchQueue.main.async { print("MAIN QUEUE RAN") }
    Thread.sleep(forTimeInterval: 1.0)
    print("returning from probe_main_queue")
}
