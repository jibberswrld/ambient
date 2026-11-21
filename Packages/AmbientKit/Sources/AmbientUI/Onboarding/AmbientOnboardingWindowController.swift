import AppKit
import Observation
import SwiftUI

/// Which onboarding screen the window is showing.
@MainActor
@Observable
final class AmbientOnboardingCoordinator {
    enum Screen {
        case gate(AmbientGateContent)
        case permissions(AmbientPermissionsModel)
        case firstRun(AmbientFirstRunModel)

        /// Identifies the kind of screen, so moving between two gate contents updates in place instead of sliding.
        var kindIdentifier: String {
            switch self {
            case .gate: return "gate"
            case .permissions: return "permissions"
            case .firstRun: return "firstRun"
            }
        }
    }

    var screen: Screen?
    var onGateButtonPressed: ((String) -> Void)?
}

/// Everything inside the onboarding window.
struct AmbientOnboardingRootView: View {
    var coordinator: AmbientOnboardingCoordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            AmbientOnboardingBackdrop()
            if let screen = coordinator.screen {
                screenView(screen)
                    .id(screen.kindIdentifier)
                    .transition(screenTransition)
            }
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.18) : .spring(response: 0.45, dampingFraction: 1.0), value: coordinator.screen?.kindIdentifier)
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private func screenView(_ screen: AmbientOnboardingCoordinator.Screen) -> some View {
        switch screen {
        case .gate(let content):
            AmbientGateScreen(content: content) { actionID in coordinator.onGateButtonPressed?(actionID) }
        case .permissions(let permissionsModel):
            AmbientPermissionsScreen(model: permissionsModel)
        case .firstRun(let firstRunModel):
            AmbientFirstRunScreen(model: firstRunModel)
        }
    }

    /// Screens move forward the way pages turn: in from the right, out to the left, with a touch of blur so the
    /// hand-over reads as one surface changing.
    private var screenTransition: AnyTransition {
        if reduceMotion { return .opacity }
        return .asymmetric(
            insertion: .offset(x: 40).combined(with: .opacity),
            removal: .offset(x: -40).combined(with: .opacity)
        )
    }
}

/// The onboarding window: the sign-in gate, the permissions step and the first-run moment, one after another in
/// the same window.
///
///     let onboarding = AmbientOnboardingWindowController()
///     let pressedActionID = await onboarding.presentGate(AmbientGateContent(
///         title: "Sign in to Ambient", bodyText: "...",
///         buttons: [AmbientGateButton(actionID: "sign-in", label: "Sign in with publik", prominence: .primary)]))
///     onboarding.showPermissions(permissionsModel)
///     onboarding.showFirstRun(firstRunModel)
///     onboarding.close()
@MainActor
public final class AmbientOnboardingWindowController: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let coordinator = AmbientOnboardingCoordinator()
    private var gateContinuation: CheckedContinuation<String?, Never>?
    private var shortcutKeyMonitor: Any?
    private weak var activeFirstRunModel: AmbientFirstRunModel?

    public static let windowSize = CGSize(width: 600, height: 500)

    public override init() {
        window = NSWindow(
            contentRect: CGRect(origin: .zero, size: Self.windowSize),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init()
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "Ambient"
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(srgbRed: 0.070, green: 0.066, blue: 0.062, alpha: 1)
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.delegate = self
        let hostingView = NSHostingView(rootView: AmbientOnboardingRootView(coordinator: coordinator))
        hostingView.sizingOptions = []
        window.contentView = hostingView
        window.center()
        coordinator.onGateButtonPressed = { [weak self] actionID in self?.resolveGate(with: actionID) }
    }

    /// The window, for captures. Do not reconfigure it.
    public var onboardingWindow: NSWindow { window }

    // MARK: Gate

    /// Shows the gate and waits for a button. Returns the button's action ID, or nil when the window is closed
    /// (by the person, or by `close()` once sign-in completes elsewhere). Presenting again answers the previous
    /// call with nil.
    public func presentGate(_ content: AmbientGateContent) async -> String? {
        resolveGate(with: nil)
        show(.gate(content))
        return await withCheckedContinuation { continuation in
            gateContinuation = continuation
        }
    }

    /// Changes what the gate says without answering the pending `presentGate` (for example to show that the
    /// browser is open and Ambient is waiting).
    public func updateGate(_ content: AmbientGateContent) {
        coordinator.screen = .gate(content)
    }

    // MARK: Permissions and first run

    public func showPermissions(_ permissionsModel: AmbientPermissionsModel) {
        resolveGate(with: nil)
        show(.permissions(permissionsModel))
    }

    public func showFirstRun(_ firstRunModel: AmbientFirstRunModel) {
        resolveGate(with: nil)
        activeFirstRunModel = firstRunModel
        show(.firstRun(firstRunModel))
        installShortcutKeyMonitor()
    }

    /// Closes the window. A pending `presentGate` returns nil.
    public func close() {
        window.close()
    }

    // MARK: NSWindowDelegate

    public func windowWillClose(_ notification: Notification) {
        resolveGate(with: nil)
        removeShortcutKeyMonitor()
    }

    // MARK: Private

    private func show(_ screen: AmbientOnboardingCoordinator.Screen) {
        if screen.kindIdentifier != "firstRun" { removeShortcutKeyMonitor() }
        coordinator.screen = screen
        if !window.isVisible {
            NSApp.activate(ignoringOtherApps: true)
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
    }

    private func resolveGate(with actionID: String?) {
        gateContinuation?.resume(returning: actionID)
        gateContinuation = nil
    }

    /// While the first run is open and focused, the window hears the modifier keys itself, so practising works
    /// before Ambient has the accessibility permission its global shortcut needs.
    private func installShortcutKeyMonitor() {
        guard shortcutKeyMonitor == nil else { return }
        shortcutKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, let firstRunModel = self.activeFirstRunModel else { return }
                firstRunModel.isShortcutHeld = AmbientFirstRunModel.modifierFlags(event.modifierFlags, match: firstRunModel.shortcut)
            }
            return event
        }
    }

    private func removeShortcutKeyMonitor() {
        if let shortcutKeyMonitor { NSEvent.removeMonitor(shortcutKeyMonitor) }
        shortcutKeyMonitor = nil
    }
}
