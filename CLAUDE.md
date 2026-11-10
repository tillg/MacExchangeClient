# Mail Replica

This is a SwiftUI copy of the macOS Mail main window, built with SwiftPM. The data is a set of fixture messages kept in memory. See `README.md` for what was read from Mail.app (✅) and what is estimated (⚠️).

## Build and test (Command Line Tools only, no Xcode)

- **App:** `./run.sh` builds and launches, and `./run.sh build` only builds. It uses the macOS 26.5 SDK, because in the 27 SDK `@State` is a macro whose plugin ships only with Xcode.
- **Tests:** these need the default SDK and their own build folder:
  ```sh
  swift build --package-path . --scratch-path .build/tests --target MailModelTests
  swift test  --package-path . --scratch-path .build/tests --skip-build
  ```
  In Claude Code, run each command as its own top-level Bash call. Inside `sh -c`, `run.sh` or `&&` chains, the Testing macro plugin fails to load (the rtk hook only wraps top-level calls). `./run.sh test` works in a normal terminal.
- Don't share `.build` between the app build and the test build. Their SDK configs poison each other's cache.

## Verifying the UI

`screencapture` has no permission on this machine. Use the in-app hook instead. It selects the first message, saves a PNG of the whole window and quits:

```sh
MAIL_SNAPSHOT=$PWD/tmp/snap.png .build/debug/MailReplica
MAIL_SNAPSHOT=$PWD/tmp/snap-dark.png MAIL_SNAPSHOT_DARK=1 .build/debug/MailReplica
```

Read the PNG before you say a visual change works. Artifacts go in `tmp/`, which is gitignored.

## Layout

- `Sources/MailModel`: `MailStore` (`@MainActor @Observable`) and the models. All behaviour lives here, and every change gets a test in `Tests/MailModelTests`.
- `Sources/MailReplica`: the views, `MailCommands` (menu shortcuts read from `MainMenu.nib`) and `DebugSnapshot`.
- Mail.app source files: `/System/Applications/Mail.app/Contents/Resources` (`MainWindow.toolbar`, `*.loctable`, `Base.lproj/*.nib`). Decode nibs with `~/git/bear_design/tools/nibdump.py`.
