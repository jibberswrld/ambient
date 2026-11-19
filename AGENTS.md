# Ambient — Agent Instructions

## Overview

Ambient is a macOS menu bar app forked from [Clicky](https://github.com/farzaa/clicky) under the MIT license. Preserve the original copyright in `LICENSE` alongside Ambient's copyright.

The current shell retains Clicky's voice and cursor interface. It has no Dock icon or main window (`LSUIElement=true`). Clicking the status item opens a custom floating control panel. Control+Option captures voice through the inherited transcription layer; a transcript and screenshots go to Claude, and ElevenLabs speaks its response. A transparent cursor overlay can point at elements on connected displays.

`Packages/AmbientKit` is separate work in progress and is **not linked to the app target**. Do not describe its planned functionality as available in the app. Analytics, the email collection gate, feedback links, and automatic updates have been removed.

## Architecture

- SwiftUI with AppKit bridging (`NSStatusItem`, borderless `NSPanel`, `NSHostingView`).
- MVVM-style state via `@StateObject`, `@ObservedObject`, and `@Published`; `@MainActor` with async/await.
- Claude streaming SSE chat and ElevenLabs TTS use an inherited Cloudflare Worker proxy URL. AssemblyAI gets temporary websocket tokens from that proxy; OpenAI and Apple Speech fallback providers remain.
- Proxy URLs are placeholders. This checkout does not include the Worker implementation or live credentials, so voice/AI responses are not configured by the shell build.
- ScreenCaptureKit requires macOS 14.2+. Screenshots are labeled per monitor. Claude's `[POINT:x,y:label:screenN]` tags map screenshot coordinates into the appropriate display and animate the cursor along a bezier path.
- Global push-to-talk uses a listen-only `CGEvent` tap, rather than an AppKit global keyboard monitor, for reliable modifier detection in the background.
- AssemblyAI shares one long-lived `URLSession` across streaming sessions. Do not replace it with per-session invalidation; that can corrupt the connection pool on rapid reconnects.
- The custom menu panel is non-activating and dismisses on outside clicks. The cursor overlay joins all Spaces and does not steal focus. When its persisted visibility preference is disabled, it appears transiently during interactions and fades after inactivity.
- The inherited app delegate registers the app as a login item with `SMAppService`; the user can disable it in System Settings.

## Key Files

All app sources are in `Ambient/`:

| File | Responsibility |
|------|----------------|
| `AmbientApp.swift` | `@main AmbientApp`, empty Settings scene, `CompanionAppDelegate`, panel and voice lifecycle, login-item registration. |
| `CompanionManager.swift` | Central voice state machine, permissions, onboarding, model choice, conversation history, capture → Claude → speech → pointing coordination. |
| `MenuBarPanelManager.swift` | Status item and custom floating panel lifecycle, positioning and dismissal. |
| `CompanionPanelView.swift` | Status, permission controls, Start, model picker, replay and Quit UI. |
| `OverlayWindow.swift` | Transparent multi-display cursor panels, welcome bubble, response display, waveform and pointing animations. |
| `CompanionResponseOverlay.swift` | Response text bubble and waveform view. |
| `CompanionScreenCaptureUtility.swift` | Multi-monitor ScreenCaptureKit screenshots. |
| `BuddyDictationManager.swift` | AVAudioEngine capture, permission checks, keyboard/button dictation and transcript finalization. |
| `BuddyTranscriptionProvider.swift` | Provider protocol and factory; `VoiceTranscriptionProvider` in Info.plist selects AssemblyAI, OpenAI or Apple Speech. |
| `AssemblyAIStreamingTranscriptionProvider.swift` | Temporary token request, AssemblyAI v3 PCM16 websocket streaming and turn finalization. |
| `OpenAIAudioTranscriptionProvider.swift` | Buffers audio and uploads a WAV on release. |
| `AppleSpeechTranscriptionProvider.swift` | Apple Speech fallback. |
| `BuddyAudioConversionSupport.swift` | PCM16 conversion and WAV construction. |
| `GlobalPushToTalkShortcutMonitor.swift` | System-wide listen-only CGEvent tap. |
| `ClaudeAPI.swift`, `OpenAIAPI.swift` | Inherited vision chat clients. |
| `ElevenLabsTTSClient.swift` | Proxy TTS request, AVAudioPlayer playback and playback state. |
| `ElementLocationDetector.swift` | Screenshot element location detection. |
| `DesignSystem.swift` | Existing design tokens and shared view styles. |
| `WindowPositionManager.swift` | Window placement and screen recording/accessibility permission helpers. |
| `AppBundleConfiguration.swift` | Bundle Info.plist configuration reader. |
| `Info.plist`, `Ambient.entitlements` | Menu-only behavior, transcription selection, permission descriptions and entitlements. |

`AmbientTests/` contains permission-routing unit tests; `AmbientUITests/` contains inherited launch/UI smoke tests.

## Build & Run

```bash
./scripts/run.sh
```

Build with `scripts/run.sh`. It uses the shared `Ambient` scheme in `Ambient.xcodeproj`, Debug configuration, team `Z63L6KDQ9K`, and a local **Apple Development** signing identity. Derived data always goes to `build/`; the app is `build/Build/Products/Debug/Ambient.app`. After a successful signed build it quits the running Ambient process and launches the new app. It rejects an ad-hoc or wrong-team signature.

Use the same certificate/team, bundle ID (`com.jabir.ambient`) and app path between builds so macOS privacy grants can remain valid. Verify with `codesign -dv --verbose=4 build/Build/Products/Debug/Ambient.app`: it must report `TeamIdentifier=Z63L6KDQ9K` and an Apple Development authority. First use still needs microphone, accessibility and screen recording/content grants. Signing changes or OS policy may require granting access again.

Open `Ambient.xcodeproj` to inspect the project in Xcode. All configurations use macOS 14.2 and the same team. Test bundle IDs are `com.jabir.ambient.tests` and `com.jabir.ambient.uitests`.

Known inherited concurrency and deprecation warnings are non-blocking; do not fix them as part of shell/integration work.

## Code Style & Conventions

### Variable and Method Naming

IMPORTANT: Follow these naming rules strictly. Clarity is the top priority.

- Be as clear and specific with variable and method names as possible
- **Optimize for clarity over concision.** A developer with zero context on the codebase should immediately understand what a variable or method does just from reading its name
- Use longer names when it improves clarity. Do NOT use single-character variable names
- Example: use `originalQuestionLastAnsweredDate` instead of `originalAnswered`
- When passing props or arguments to functions, keep the same names as the original variable. Do not shorten or abbreviate parameter names. If you have `currentCardData`, pass it as `currentCardData`, not `card` or `cardData`

### Code Clarity

- **Clear is better than clever.** Do not write functionality in fewer lines if it makes the code harder to understand
- Write more lines of code if additional lines improve readability and comprehension
- Make things so clear that someone with zero context would completely understand the variable names, method names, what things do, and why they exist
- When a variable or method name alone cannot fully explain something, add a comment explaining what is happening and why

### Swift/SwiftUI Conventions

- Use SwiftUI for all UI unless a feature is only supported in AppKit (e.g., `NSPanel` for floating windows)
- All UI state updates must be on `@MainActor`
- Use async/await for all asynchronous operations
- Comments should explain "why" not just "what", especially for non-obvious AppKit bridging
- AppKit `NSPanel`/`NSWindow` bridged into SwiftUI via `NSHostingView`
- All buttons must show a pointer cursor on hover
- For any interactive element, explicitly think through its hover behavior (cursor, visual feedback, and whether hover should communicate clickability)

### Do NOT

- Do not add features, refactor code, or make "improvements" beyond what was asked
- Do not add docstrings, comments, or type annotations to code you did not change
- Do not try to fix the known non-blocking warnings (Swift 6 concurrency, deprecated onChange)

## Git Workflow

Use a task-specific worktree and feature branch. Do not modify sibling worktrees or the main checkout. Make concise imperative commits. Never commit credentials or generated `build/` output; never bypass hooks. Keep this document accurate when architecture or build instructions change.
