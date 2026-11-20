//
//  AmbientApp.swift
//  Ambient
//
//  Menu bar-only companion app. No dock icon, no main window — just an
//  always-available status item in the macOS menu bar. Clicking the icon
//  opens a floating panel with companion voice controls.
//

import SwiftUI

@main
struct AmbientApp: App {
    @NSApplicationDelegateAdaptor(CompanionAppDelegate.self) var appDelegate

    var body: some Scene {
        // The app lives entirely in the menu bar panel managed by the AppDelegate.
        // This empty Settings scene satisfies SwiftUI's requirement for at least
        // one scene but is never shown (LSUIElement=true removes the app menu).
        Settings {
            EmptyView()
        }
    }
}

/// Manages the companion lifecycle: creates the menu bar panel and starts
/// the companion voice pipeline on launch.
@MainActor
final class CompanionAppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarPanelManager: MenuBarPanelManager?
    private var runtime: AmbientRuntime?
    private var companionManager: CompanionManager?

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("🎯 Ambient: Starting...")
        print("🎯 Ambient: Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown")")

        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 0])


        let runtime: AmbientRuntime
        do { runtime = try AmbientRuntime() }
        catch {
            let alert = NSAlert()
            alert.messageText = "Ambient could not start"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        self.runtime = runtime
        let companionManager = CompanionManager(runtime: runtime)
        self.companionManager = companionManager
        menuBarPanelManager = MenuBarPanelManager(companionManager: companionManager)
        companionManager.start()
        // Auto-open the panel if the user still needs to do something:
        // either they haven't onboarded yet, or permissions were revoked.
        if !companionManager.hasCompletedOnboarding || !companionManager.allPermissionsGranted {
            menuBarPanelManager?.showPanelOnLaunch()
        }
        runtime.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        NSLog("Ambient application terminating")
        companionManager?.stop()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard let text = Self.automationText(from: url) else { continue }
            companionManager?.buddyDictationManager.cancelCurrentDictation()
            runtime?.submit(text: text)
        }
    }

    static func automationText(from url: URL) -> String? {
        guard url.scheme?.lowercased() == "ambient", url.host == "ask",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let text = components.queryItems?.first(where: { $0.name == "text" })?.value,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }
}
