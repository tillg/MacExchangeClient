#!/bin/sh
# The macOS 27 SDK turns @State into a macro whose plugin ships only with Xcode.
# With Command Line Tools only, build against the 26.x SDK instead.
set -e
cd "$(dirname "$0")"
# Tests only use MailModel (no SwiftUI) and need the default SDK, where the Testing macros live.
# Separate scratch path: `swift test` alone would also compile the app target under the default SDK.
if [ "$1" = test ]; then
  swift build --scratch-path .build/tests --target MailModelTests
  exec swift test --scratch-path .build/tests --skip-build
fi
export SDKROOT="${SDKROOT:-$(xcrun --show-sdk-path --sdk macosx26.5 2>/dev/null || echo /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk)}"
case "$1" in
  build) swift build ;;
  *) swift build && exec .build/debug/MailReplica ;;
esac
