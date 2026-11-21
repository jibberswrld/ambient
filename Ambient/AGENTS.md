# Ambient app target

Read the repository-root `AGENTS.md` for architecture, build instructions and code conventions.

`AmbientApp.swift` creates one `AmbientRuntime`. After sign-in, `AmbientAppDelegate` creates one `FlowBarModel` and `FlowBarPanelController`, forwards session events directly, and subscribes to the task store. It owns the plain status menu, real-service settings window, permission polling, first run, shortcut and dictation callbacks. Settings Activity selects the requested task transcript.

`AmbientInteraction` presents the AmbientUI publik gate and awaits bar approvals. `AmbientPointerWindowController` draws only an on-demand four-second click-through pointer on the target display. The inherited panel, cursor buddy, response overlay, design system and tutorial assets are deleted. `AmbientDictationManager`, `AmbientScreenCaptureUtility`, `AmbientPermissionHelper` and the global shortcut monitor retain the functional system integration.

Build and launch with `scripts/run.sh`. Develop only in the assigned worktree. Never add credentials to source, defaults, launch arguments or the app bundle; supported development overrides come from the script caller's environment and are passed to LaunchServices with `open --env`.
