#!/bin/bash
# Runs the ClaudeAPI unit tests (Tests/ClaudeAPITests, swift-testing).
#
# Why this wrapper exists: a bare `swift test` fails on a machine with only
# the Command Line Tools installed — XCTest ships inside Xcode, and while
# Testing.framework DOES ship with the toolchain, SwiftPM doesn't add its
# framework search path, and the `_Testing_Foundation` cross-import overlay
# has no module in the CLT layout (so `import Foundation` + `import Testing`
# in one file fails to build until overlays are disabled).
#
# With Xcode installed, plain `swift test` works and this script just calls it.
set -e
cd "$(dirname "$0")"

FW="$(xcode-select -p)/Library/Developer/Frameworks"
if [ -d "$(xcode-select -p)/Platforms/MacOSX.platform/Developer/Library/Frameworks" ]; then
    # Full Xcode: XCTest and Testing are both discoverable by default.
    exec swift test "$@"
fi

if [ ! -d "$FW/Testing.framework" ]; then
    echo "error: no test framework found." >&2
    echo "  Looked for Testing.framework in $FW" >&2
    echo "  Install Xcode, or a toolchain that ships swift-testing." >&2
    exit 1
fi

echo "==> Command Line Tools layout detected; using $FW"
exec swift test \
    -Xswiftc -F -Xswiftc "$FW" \
    -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays \
    -Xlinker -F -Xlinker "$FW" \
    -Xlinker -rpath -Xlinker "$FW" \
    "$@"
