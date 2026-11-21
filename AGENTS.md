# Ambient — Agent Instructions

## Overview

Ambient is a macOS menu bar app forked from [Clicky](https://github.com/farzaa/clicky) under the MIT license. Preserve the original copyright in `LICENSE` alongside Ambient's copyright.

The app target links the local `Packages/AmbientKit` library. Its pipeline is Control+Option → temporary PCM WAV → `PublikSpeechClient.transcribe` → `AmbientAgentSession` with tools → memory learning and optional publik speech playback. The inherited vendor clients, Cloudflare Worker endpoints and pointing-tag parser have been removed.

The app imports `AmbientUI`. `AmbientAppDelegate` owns the live flow bar, settings, permissions, first-run window, status menu, shortcut and transient pointer. No inherited Clicky presentation remains.

## Architecture

- `AmbientRuntime` is the sole composition root, owning the credential source, session, completion/speech clients, background manager, memory/skill stores, connector and tool providers. Its settings-facing stores/services use contract protocol types.
- `AmbientRuntimeState` is the single observable conversation state: idle, listening(audioLevel), transcribing, thinking, working(activityLabel), responding(text), finished(finalText), failed(AgentFailure). The app forwards input phases and live microphone levels to `FlowBarModel`; session events reach the model directly through `onAgentEvent`. There is one agent pipeline.
- `AmbientInteraction` is the main-actor approval/authorization seam. Approvals await `FlowBarModel.requestApproval`, cancellation denies pending requests, and connector authorization opens the default browser. `PublikGateUI` presents `AmbientOnboardingWindowController`. Missing approval handlers deny by default.
- `Publik.ensureSignedIn` runs at launch. There is no bundled app token yet. Development uses `PUBLIK_API_KEY`; missing setup is explicit. Never persist development overrides. The launch script forwards `PUBLIK_API_KEY`, `PUBLIK_API_BASE_URL`, `AMBIENT_CONNECTOR_ORIGIN` through LaunchServices.
- `AmbientScreenToolProvider` supplies optional `look_at_screen`, `point_at` and `draw_on_screen` tools. `draw_on_screen` takes arrows, circles, boxes, underlines and captions in latest-capture pixels and shows them with `AmbientAnnotationOverlayView`, drawn in order and numbered when several have captions. No screenshots accompany ordinary requests. Captures exclude Ambient windows and use a bounded JPEG budget. Pointing maps 1-based display indices and latest-capture pixel coordinates (top-left origin) to AppKit screen coordinates.
- `AmbientDictationManager` records 16 kHz mono PCM WAV and live levels, up to 90 seconds. It removes its own temporary recording after completion/cancellation.
- A new push-to-talk press or text submission cancels the turn, stops playback and clears any drawing. `ambient.spokenRepliesEnabled` defaults to true. Replies are spoken sentence by sentence as they stream: each sentence is synthesized when it completes and played in order. Successful turns start `MemoryStore.learn` in its own task, never ahead of the reply or its speech.
- The bar's conversation runs on `publik-smart` with `reasoning_effort` low. Measured on 2026-11-21 it is the quickest model publik serves to first token (about 1 s; `publik-fast` 1.1 s, `publik-balanced` 2–3.5 s), so there is no faster tier to switch to. Recordings are transcribed on this Mac by `AmbientLocalTranscriber` (Apple Speech, on-device only, about 0.3–0.5 s once warm) and fall back to publik `gpt-4o-mini-transcribe` (about 1.5 s) when on-device recognition is unavailable, not permitted, empty or slower than four seconds.
- `spawn_agent` starts Ambient's own agent unless the person asks for Codex or Claude Code by name. Ambient's agent (`BackgroundTaskManager.spawnInProcessAgent`) is a second `AmbientAgentSession` on the person's publik account with high reasoning effort. It has web search, connectors, memory, skills and `AgentWorkspaceToolProvider`: a zsh tool run under `sandbox-exec` that can write only in the agent's working directory, temp folders and a few caches. It has no screen access and cannot spawn. It cannot be resumed and does not survive a relaunch. `codex` and `claude` kinds run the person's own headless CLIs.
- Background task completions are logged, published as `latestBackgroundCompletion`, and available as independent `backgroundCompletions()` streams. Agent processes are headless; no Terminal/Codex window is opened.
- `Packages/AmbientKit/Sources/AmbientContracts/Contracts.swift` is the subsystem agreement. Each subsystem depends only on that target. The app imports AmbientAgent, AmbientBackground, AmbientConnectors, AmbientMemory, AmbientContracts and AmbientUI.
- `connector/` contains the undeployed TypeScript service. Local default: `http://127.0.0.1:3019`. Its Composio key exists only in the service environment. Tool Router owns discovery, schemas, authorization and execution; do not add per-app adapters/catalogs. Read its README before changing it.
- Stores live under `~/Library/Application Support/Ambient/`. Never overwrite corrupt store files with empty data. The runtime reports initialization failures.
- `ambient://ask?text=...` is the permanent URL automation hook, routed through the same agent path and approvals. Before sign-in, the latest request is queued. Debug-only `--transcribe-wav` exercises the actual transcription path without a microphone.
- `NSLog` records local state, tool names, speech synthesis/playback and final background statuses. These logs contain conversation text; do not add credentials or raw tool payloads.
- `FlowBarPanelController` persists full placement with `FlowBarPlacementStore`. Settings receives the real connector, memory, skill and task stores. The Activity page can select the exact task requested from the tray.
- Settings persists spoken replies, background approval and shortcut choice. Login registration uses `SMAppService.mainApp` only when explicitly switched on, off by default. `GET /wallet` supplies optional handle, plan label and percentage remaining; no currency amounts or inferred allowance appear.
- Onboarding checks microphone, accessibility and screen recording live, exposes system grant actions, then teaches the shortcut and edge choice. Completion uses `ambient.onboardingCompleted`. Revoked permissions reopen the permissions step.
- `AmbientPointerWindowController` creates a click-through transparent panel on the captured display for `point_at` (`AmbientPointerView`, removed after four seconds) or `draw_on_screen` (`AmbientAnnotationOverlayView`, removed after 45 seconds or at the next request). It holds one thing at a time. No cursor follower or welcome bubble exists.
- The template waveform status menu provides Open Settings, Show / Hide Bar, and Quit Ambient. Command-comma also opens Settings.

`AmbientTests/` covers permission routing, URL decoding and wallet mapping; `AmbientUITests/` retains inherited launch smoke tests. Run package and app tests after integration changes, and launch/interact with the signed app to verify actual behavior.

## Build & Run

```bash
./scripts/run.sh
```

Build with `scripts/run.sh`. It uses the shared `Ambient` scheme in `Ambient.xcodeproj`, Debug configuration, team `Z63L6KDQ9K`, and a local **Apple Development** signing identity. Derived data always goes to `build/`; the app is `build/Build/Products/Debug/Ambient.app`. After a successful signed build it quits only this worktree’s running Ambient executable and launches the new app. It rejects an ad-hoc or wrong-team signature.

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
