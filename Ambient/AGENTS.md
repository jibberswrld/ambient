# Ambient app target

Read the repository-root `AGENTS.md` for architecture, build instructions and code conventions.

`AmbientApp.swift` is the app entry point. `CompanionAppDelegate` owns `MenuBarPanelManager` and starts/stops `CompanionManager`. The app has no main window; the control panel and cursor overlay are hosted in AppKit panels. Preserve the inherited voice pipeline until the integration step replaces it deliberately.

Build and launch from the repository root with `./scripts/run.sh`. Do not link `Packages/AmbientKit` as part of shell-only work.
