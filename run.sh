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
# Signing identity: an Apple Development certificate first. It has a Team ID, so the Keychain recognises every
# new build and stops asking for the password item. Otherwise the self-signed one from make-signing-identity.sh,
# otherwise ad hoc (both make the Keychain ask after each build).
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*\([0-9A-F]\{40\}\) "Apple Development: .*/\1/p' | head -1)
if [ -z "$IDENTITY" ] && security find-certificate -c "MailReplica Dev" >/dev/null 2>&1; then IDENTITY="MailReplica Dev"; fi
sign() {
  if [ -n "$IDENTITY" ]; then
    codesign -f -s "$IDENTITY" -i MailReplica .build/debug/MailReplica 2>/dev/null
  fi
}
# Wrap the binary in MailReplica.app, so Activity Monitor, the Dock and Keychain dialogs show the app's icon.
# The identifier stays "MailReplica", the defaults domain the bare binary used, so saved accounts stay.
APP=.build/MailReplica.app
bundle() {
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
  cp .build/debug/MailReplica "$APP/Contents/MacOS/MailReplica"
  # The icon is drawn in code (AppIcon.swift): export it again whenever that file changes.
  if [ ! -f "$APP/Contents/Resources/AppIcon.icns" ] || [ Sources/MailReplica/AppIcon.swift -nt "$APP/Contents/Resources/AppIcon.icns" ]; then
    set_dir=.build/AppIcon.iconset
    rm -rf "$set_dir" && mkdir -p "$set_dir"
    MAIL_SAMPLE_DATA=1 MAIL_ICON_EXPORT="$PWD/.build/icon-1024.png" .build/debug/MailReplica
    for s in 16 32 128 256 512; do
      sips -z $s $s .build/icon-1024.png --out "$set_dir/icon_${s}x${s}.png" >/dev/null
      sips -z $((s * 2)) $((s * 2)) .build/icon-1024.png --out "$set_dir/icon_${s}x${s}@2x.png" >/dev/null
    done
    iconutil -c icns "$set_dir" -o "$APP/Contents/Resources/AppIcon.icns"
  fi
  # Build number: one up per build, kept in .build-number (not in git). About shows it and the build time.
  BUILD=$(( $(cat .build-number 2>/dev/null || echo 0) + 1 ))
  echo "$BUILD" > .build-number
  BUILT=$(date '+%Y-%m-%d %H:%M')
  cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>MailReplica</string>
  <key>CFBundleName</key><string>MailReplica</string>
  <key>CFBundleExecutable</key><string>MailReplica</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>NSHumanReadableCopyright</key><string>Built $BUILT</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>UTExportedTypeDeclarations</key><array><dict>
    <key>UTTypeIdentifier</key><string>local.mailreplica.messages</string>
    <key>UTTypeDescription</key><string>MailReplica Messages</string>
    <key>UTTypeConformsTo</key><array><string>public.data</string></array>
  </dict></array>
</dict></plist>
PLIST
  if [ -n "$IDENTITY" ]; then
    codesign -f -s "$IDENTITY" -i MailReplica "$APP" 2>/dev/null
  else
    codesign -f -s - -i MailReplica "$APP" 2>/dev/null
  fi
  # Register the bundle, so the system knows the drag type above (dragging messages onto the sidebar needs it).
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
}
case "$1" in
  build) swift build && sign && bundle ;;
  *) swift build && sign && bundle && exec "$APP/Contents/MacOS/MailReplica" ;;
esac
