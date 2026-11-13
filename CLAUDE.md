# Mail Replica

This is a SwiftUI copy of the macOS Mail main window, built with SwiftPM. The data is a set of fixture messages kept in memory. See `README.md` for what was read from Mail.app (✅) and what is estimated (⚠️).

## Build and test (Command Line Tools only, no Xcode)

- **App:** `./run.sh` builds and launches, and `./run.sh build` only builds. `./run.sh release` builds optimized and launches (the user's daily app); any `./run.sh` build replaces the binary in `.build/MailReplica.app`. It uses the macOS 26.5 SDK, because in the 27 SDK `@State` is a macro whose plugin ships only with Xcode.
- **Tests:** these need the default SDK and their own build folder:
  ```sh
  swift build --package-path . --scratch-path .build/tests --target MailModelTests \
    -Xswiftc -load-plugin-library -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib
  swift test  --package-path . --scratch-path .build/tests --skip-build
  ```
  In Claude Code, run each command as its own top-level Bash call. Inside `sh -c`, `run.sh` or `&&` chains, the Testing macro plugin fails to load (the rtk hook only wraps top-level calls). `./run.sh test` works in a normal terminal.
- The build's dependency scanner sometimes leaves out the Testing macro plugin (`plugin for module 'TestingMacros' not found`, which also hides real compile errors). The `-load-plugin-library` flag above loads it explicitly. After a failed build, `swift test --skip-build` runs the old binary, so check the test count.
- Don't share `.build` between the app build and the test build. Their SDK configs poison each other's cache.

## Verifying the UI

`screencapture` has no permission on this machine. Use the in-app hook instead. It selects the first message, saves a PNG of the whole window and quits:

```sh
tools/snapshot.sh $PWD/tmp/snap.png
tools/snapshot.sh $PWD/tmp/snap-dark.png MAIL_SNAPSHOT_DARK=1
```

Never run `.build/debug/MailReplica` directly to take a snapshot. The app's defaults hold a real Exchange account, so it would connect to it. `tools/snapshot.sh` runs a copy of the binary under its own empty defaults domain, with `MAIL_SAMPLE_DATA=1`. Read the PNG before you say a visual change works. Artifacts go in `tmp/`, which is gitignored.

## Layout

- `Sources/MailModel`: `MailStore` (`@MainActor @Observable`) and the models. All behaviour lives here, and every change gets a test in `Tests/MailModelTests`.
- `Sources/MailReplica`: the views, `MailCommands` (menu shortcuts read from `MainMenu.nib`) and `DebugSnapshot`.
- Mail.app source files: `/System/Applications/Mail.app/Contents/Resources` (`MainWindow.toolbar`, `*.loctable`, `Base.lproj/*.nib`). Decode nibs with `~/git/bear_design/tools/nibdump.py`.

## Change log (Help ▸ What's New)

With every change a user would notice, update `WhatsNew.days` in `Sources/MailModel/WhatsNew.swift` in the same change: add a line to today's day (newest day first; start a new day if today has none). Write for people who don't program: what they can now do or see, in one short sentence, no technical terms (no EWS, SQLite, FTS, cid, cache…). Leave out purely internal changes.
