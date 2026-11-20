# Ambient

Ambient is a native macOS menu bar assistant forked from [Clicky](https://github.com/farzaa/clicky) under the [MIT license](LICENSE). Its real pipeline uses publik for sign-in, streamed AI, web search, transcription and speech; Composio for connected apps; and headless Codex/Claude Code processes for background work.

The app still shows the inherited control panel and cursor overlay. `AmbientUI` is a placeholder and is not imported by the app. The flow bar, settings and replacement onboarding are not integrated.

## Build and run

Requires macOS 14.2+, Xcode, and an Apple Development identity for team `Z63L6KDQ9K`.

```bash
./scripts/run.sh
```

This builds the shared Ambient scheme in Debug, verifies the team/signature, quits only this worktree's running executable, and launches `build/Build/Products/Debug/Ambient.app`. Keep the bundle ID (`com.jabir.ambient`), identity and build path stable for macOS privacy grants. The script passes caller-supplied `PUBLIK_API_KEY`, `PUBLIK_API_BASE_URL` and `AMBIENT_CONNECTOR_ORIGIN` to the app without persisting them.

Ambient calls `Publik.ensureSignedIn` at launch. This build has no bundled publik app token; the owner must register the app before normal install provisioning can work. For development, supply `PUBLIK_API_KEY` through the script's environment. Missing setup appears in a plain sign-in window. Keys must never be added to the repository, Info.plist or defaults.

Hold Control+Option to record; release to transcribe and submit. Accessibility permission enables the global shortcut; microphone permission enables recording. Screen Recording permission is needed only for screen tools. Requests never attach screenshots automatically. Spoken replies default to on (`ambient.spokenRepliesEnabled` in UserDefaults). A new recording or text request cancels the active response and stops its audio.

The permanent text automation entry point requires no microphone:

```bash
open 'ambient://ask?text=What%20is%20two%20plus%20two%3F'
```

Percent-encode text as a URL query value. These requests have the same tools and approvals as voice. Before sign-in completes, only the latest submitted text is queued. `NSLog` reports state, tool names, speech synthesis/playback and background completions; inspect with `log stream --level info --predicate 'process == "Ambient"'`. The launch script also captures stdout/stderr under `build/app-stdout.log` and `build/app-stderr.log`. Treat local logs as conversation data.

## Architecture

- `Ambient/AmbientRuntime.swift` is the single composition root. It owns the credential source, agent session, completion service, speech client, task manager, connector, memory and skills. Settings-facing services are exposed as `AICredentialSource`, `AgentSession`, `TextCompletionService`, `BackgroundTaskStore`, `ConnectorService`, `MemoryStore` and `SkillStore`.
- `AmbientRuntime.state` is the observable `AmbientRuntimeState`: idle, listening with audio level, transcribing, thinking, working with activity, responding with accumulated text, finished with final text, and failed with `AgentFailure`. It also publishes the current user text, reply text and latest background completion.
- `AmbientInteraction` is the small main-actor interface seam. Replace `approvalHandler` and `authorizationHandler` when the interface is ready. Today approval uses an NSAlert sheet, authorization opens the default browser, and `PublikGateUI` uses a plain native window. `approvalSettings` exposes the background provider's persisted ask-first preference.
- `AmbientScreenToolProvider` supplies `look_at_screen` and `point_at`. Captures exclude Ambient's own windows, are downsized and bounded below the API request limit. Display indices are 1-based; pointing uses the latest capture's pixels with a top-left origin. No clicks or response-tag parsing are involved.
- `BuddyDictationManager` records a temporary 16 kHz mono PCM WAV, meters audio and deletes the temporary file after release/cancel. `AmbientRuntime.submit(recordedWAV:)` sends it through the same publik transcription call before the agent. Apple Speech and the inherited vendor clients/proxy configuration have been removed.
- After each successful agent turn, the runtime enqueues memory learning and synthesizes/plays the reply when enabled. Background task final statuses are logged and published; `backgroundCompletions()` gives each interface subscriber a separate stream.
- `CompanionManager` adapts state and permissions to the existing panel and pointing overlay. The inherited intro video remains, but its automatic screen/model demo was removed. The app no longer automatically registers itself as a login item.

`Packages/AmbientKit` is linked as a local Swift package. Its subsystem targets depend only on `AmbientContracts`: `AmbientAgent`, `AmbientBackground`, `AmbientConnectors`, `AmbientMemory` and the unused `AmbientUI` placeholder. Stores persist under `~/Library/Application Support/Ambient/` (`memories.json`, `skills/`, `tasks/`, `workspaces/`). Publik manages its own credentials separately.

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
