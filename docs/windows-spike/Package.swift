// swift-tools-version:5.9
// Step 3 of the Windows spike. Drop in as C:\spike\ProbeFFI\Package.swift.
//
// The `.dynamic` product type is what asks SwiftPM for a real DLL. Note that
// ProbeFFI is named directly in `targets:` — that placement is load-bearing
// (see the -static trap note in FFI.swift and README.md step 3).
import PackageDescription

let package = Package(
    name: "ProbeFFI",
    products: [
        .library(name: "ProbeFFI", type: .dynamic, targets: ["ProbeFFI"])
    ],
    targets: [
        .target(name: "ProbeFFI", path: "Sources/ProbeFFI")
    ]
)
