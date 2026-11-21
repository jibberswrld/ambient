# Ambient

Ambient is a native macOS menu bar assistant forked from [Clicky](https://github.com/farzaa/clicky) under the [MIT license](LICENSE). Its real pipeline uses publik for sign-in, streamed AI, web search, transcription and speech; Composio for connected apps; and headless Codex/Claude Code processes for background work.

Ambient uses its own smoked-glass flow bar, settings, sign-in gate and onboarding from `AmbientUI`. Drag the bar to any screen edge. It shows listening levels, transcription, tool activity, streaming replies, approvals and background tasks. A waveform menu bar item opens Settings, shows or hides the bar, and quits the app. The inherited Clicky UI and tutorial images have been removed.

## Build and run

Requires macOS 14.2+, Xcode, and an Apple Development identity for team `Z63L6KDQ9K`.

```bash
./scripts/run.sh
```

This builds the shared Ambient scheme in Debug, verifies the team/signature, quits only this worktree's running executable, and launches `build/Build/Products/Debug/Ambient.app`. Keep the bundle ID (`com.jabir.ambient`), identity and build path stable for macOS privacy grants. The script passes caller-supplied `PUBLIK_API_KEY`, `PUBLIK_API_BASE_URL` and `AMBIENT_CONNECTOR_ORIGIN` to the app without persisting them.

Ambient calls `Publik.ensureSignedIn` at launch. This build has no bundled publik app token; the owner must register the app before normal install provisioning can work. For development, supply `PUBLIK_API_KEY` through the script's environment. Missing setup appears in Ambient’s sign-in gate. Keys must never be added to the repository, Info.plist or defaults.

First run shows live microphone, accessibility and screen recording permissions, then shortcut practice and edge selection. Completion is persisted. Hold Control+Option to record; release to transcribe and submit. Accessibility permission enables the global shortcut; microphone permission enables recording. Screen Recording permission is needed only for screen tools. Requests never attach screenshots automatically. Spoken replies default to on (`ambient.spokenRepliesEnabled` in UserDefaults). A new recording or text request cancels the active response and stops its audio.

The permanent text automation entry point requires no microphone:

```bash
open 'ambient://ask?text=What%20is%20two%20plus%20two%3F'
```

Percent-encode text as a URL query value. These requests have the same tools and approvals as voice. Before sign-in completes, only the latest submitted text is queued. `NSLog` reports state, tool names, speech synthesis/playback and background completions; inspect with `log stream --level info --predicate 'process == "Ambient"'`. The launch script also captures stdout/stderr under `build/app-stdout.log` and `build/app-stderr.log`. Treat local logs as conversation data.

## Architecture

- `Ambient/AmbientRuntime.swift` is the single composition root. It owns the credential source, agent session, completion service, speech client, task manager, connector, memory and skills. Settings-facing services are exposed as `AICredentialSource`, `AgentSession`, `TextCompletionService`, `BackgroundTaskStore`, `ConnectorService`, `MemoryStore` and `SkillStore`.
- `AmbientRuntime.state` is the observable `AmbientRuntimeState`: idle, listening with audio level, transcribing, thinking, working with activity, responding with accumulated text, finished with final text, and failed with `AgentFailure`. It also publishes the current user text, reply text and latest background completion.
- `AmbientInteraction` awaits approval cards in the flow bar, opens connector authorization in the default browser, and presents the AmbientUI publik sign-in gate. Cancellation denies a pending approval. `approvalSettings` exposes the persisted ask-first preference, on by default.
- `AmbientScreenToolProvider` supplies `look_at_screen` and `point_at`. Captures exclude Ambient's own windows, are downsized and bounded below the API request limit. Display indices are 1-based; pointing uses the latest capture's pixels with a top-left origin. No clicks or response-tag parsing are involved.
- `AmbientDictationManager` records a temporary 16 kHz mono PCM WAV, meters audio and deletes the temporary file after release/cancel. `AmbientRuntime.submit(recordedWAV:)` sends it through the same publik transcription call before the agent. Apple Speech and the inherited vendor clients/proxy configuration have been removed.
- After each successful agent turn, the runtime enqueues memory learning and synthesizes/plays the reply when enabled. Background task final statuses are logged and published; `backgroundCompletions()` gives each interface subscriber a separate stream.
- `AmbientAppDelegate` forwards raw `AgentEvent`s to `FlowBarModel`, maps input phases and live microphone levels, and feeds `BackgroundTaskStore.updates()` into the task tray. Every intent connects to the same runtime and stores. Task transcripts open in Settings > Activity with that task selected.
- Settings uses the real connector, memory, skill and background stores. General settings persist spoken replies, ask-first and shortcut choice. Docking persists display, edge and position. Open at login uses `SMAppService.mainApp` and is off by default.
- Account reads `GET /wallet` with the runtime credential. It shows the returned handle, optional plan label and returned monthly or prepaid percentage. Missing values are omitted. It never displays money or invents plan/allowance data.
- `AmbientPointerWindowController` shows `AmbientPointerView` at the exact target on the captured display in a transparent, click-through panel, then removes it after four seconds. Nothing follows the cursor or remains on screen at rest except the docked bar.

`Packages/AmbientKit` is linked as a local Swift package. Its subsystem targets depend only on `AmbientContracts`: `AmbientAgent`, `AmbientBackground`, `AmbientConnectors`, `AmbientMemory` and `AmbientUI`. Stores persist under `~/Library/Application Support/Ambient/` (`memories.json`, `skills/`, `tasks/`, `workspaces/`). Publik manages its own credentials separately.

`connector/` is the local/server TypeScript service. Run `npm ci`, then `npm run dev` with `COMPOSIO_API_KEY` in its process environment. It listens on `127.0.0.1:3019`, the Mac client's default origin. It verifies the caller's publik credential and obtains unrestricted Composio Tool Router meta tools. No connector is deployed by this repository setup. See [connector/README.md](connector/README.md) for its API, deployment instructions and tests.

## Tests

```bash
cd Packages/AmbientKit
swift test --scratch-path .build-integration
```

App unit tests:

```bash
xcodebuild -project Ambient.xcodeproj -scheme Ambient -destination 'platform=macOS' \
  -derivedDataPath build -only-testing:AmbientTests test
```

The Debug build also accepts `scripts/run.sh --transcribe-wav /absolute/path/to/recording.wav` to exercise recorded-audio submission without a microphone. This uses the live transcription service and normal agent/speech path. It is a development argument, not a second pipeline.

## License

MIT. Original work: Copyright (c) 2026 Farza. Ambient changes: Copyright (c) 2026 Jabir O. Mohamed. See `LICENSE`.
