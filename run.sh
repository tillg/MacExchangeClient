#!/bin/sh
# The macOS 27 SDK turns @State into a macro whose plugin ships only with Xcode.
# With Command Line Tools only, build against the 26.x SDK instead.
set -e
cd "$(dirname "$0")"
# Tests only use MailModel (no SwiftUI) and need the default SDK, where the Testing macros live.
# Separate scratch path: `swift test` alone would also compile the app target under the default SDK.
if [ "$1" = test ]; then
  # The dependency scanner sometimes drops the Testing macro plugin; load it explicitly.
  swift build --scratch-path .build/tests --target MailModelTests \
    -Xswiftc -load-plugin-library -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib
  exec swift test --scratch-path .build/tests --skip-build
fi
export SDKROOT="${SDKROOT:-$(xcrun --show-sdk-path --sdk macosx26.5 2>/dev/null || echo /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk)}"
# Sign with the stable identity from make-signing-identity.sh, if there is one. Ad-hoc signatures change with
# every build, and the Keychain then asks again for the password item.
sign() {
  if security find-certificate -c "MailReplica Dev" >/dev/null 2>&1; then
    codesign -f -s "MailReplica Dev" -i MailReplica .build/debug/MailReplica 2>/dev/null
  fi
}
case "$1" in
  build) swift build && sign ;;
  *) swift build && sign && exec .build/debug/MailReplica ;;
esac
