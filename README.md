# Ambient

Ambient is a native macOS menu bar assistant forked from [Clicky](https://github.com/farzaa/clicky) under the [MIT license](LICENSE).

This checkout currently contains the renamed app shell and Clicky's inherited voice pipeline: Control+Option push-to-talk, screen capture, a cursor overlay, Claude chat, AssemblyAI transcription and ElevenLabs playback. The proxy endpoints remain placeholders, so building the shell does not configure working AI/voice services. The local `Packages/AmbientKit` package is not yet linked to the Xcode target.

## Build and run

Requires macOS 14.2 or later, a compatible Xcode installation (the project uses Xcode 26-era settings), and an installed Apple Development signing identity for team `Z63L6KDQ9K`.

```bash
./scripts/run.sh
```

The script builds the shared **Ambient** scheme in Debug, verifies development signing for the expected team, quits any running Ambient copy, then launches:

```text
build/Build/Products/Debug/Ambient.app
```

Keep this fixed build path and signing identity to preserve macOS privacy grants between builds. The app appears in the menu bar, with no Dock icon. Click its icon for permissions and controls; use Quit Ambient to exit. First use requires microphone, accessibility and screen recording/content access. The inherited app also registers as a login item, which can be disabled in System Settings.

You can inspect the project with `open Ambient.xcodeproj`. The app bundle ID is `com.jabir.ambient`; deployment target is macOS 14.2. Build artifacts live in the ignored `build/` directory.

## Source layout

- `Ambient/` — SwiftUI/AppKit app shell, inherited managers, providers, API clients and overlay.
- `Ambient.xcodeproj/` — app and test targets, shared `Ambient` scheme.
- `AmbientTests/`, `AmbientUITests/` — permission-routing and launch tests.
- `Packages/AmbientKit/` — separate local package; not yet consumed by the app.
- `scripts/run.sh` — repeatable signed build and launch.
- `AGENTS.md` — architecture and code conventions.

Analytics, email collection, original-author feedback links and Sparkle updates have been removed. The app still uses the inherited control panel and cursor surface.

## License

MIT. Original work: Copyright (c) 2026 Farza. Ambient changes: Copyright (c) 2026 Jabir O. Mohamed. See `LICENSE`.
