# Ambient app target

Read the repository-root `AGENTS.md` for architecture, build instructions and code conventions.

`AmbientApp.swift` creates one `AmbientRuntime` and the temporary `CompanionManager` panel/overlay adapter. Runtime state, contract-typed stores/services, and `AmbientInteraction` are the seams for the later interface integration. The app links the local AmbientKit package without importing AmbientUI.

Build and launch with `scripts/run.sh`. Develop only in the assigned worktree. Never add credentials to source, defaults, launch arguments or the app bundle; supported development overrides come from the script caller's environment and are passed to LaunchServices with `open --env`.
