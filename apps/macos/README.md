# BlakTail for macOS

Native SwiftUI menu bar + endpoint manager. One session searches and manages
machines across every authorised network workspace, while **This Mac** controls
the local tunnel. See [`docs/macos-desktop.md`](../../docs/macos-desktop.md).

```sh
swift test
swift build -c release
```

Minimum macOS 14 Sonoma. Session tokens go in Keychain; join keys go on `blaktaild` stdin only.
