import AppKit
import AmbientAgent

/// The interface can replace these two handlers without changing any tool provider.
@MainActor
final class AmbientInteraction: NSObject, PublikGateUI {
    var approvalHandler: (@MainActor (String, String) async -> Bool)?
    var authorizationHandler: (@MainActor (URL) -> Void)?
    private var approvalWindow: NSWindow?
    private var gateWindow: NSWindow?
    private var gateContinuation: CheckedContinuation<String?, Never>?

    func approve(title: String, detail: String) async -> Bool {
        guard !Task.isCancelled else { return false }
        if let approvalHandler { return await approvalHandler(title, detail) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1, height: 1), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Ambient approval"
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        approvalWindow = window
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Deny")
        let result = await withTaskCancellationHandler {
            await alert.beginSheetModal(for: window)
        } onCancel: {
            Task { @MainActor in
                if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .cancel) }
            }
        }
        window.orderOut(nil)
        if approvalWindow === window { approvalWindow = nil }
        return result == .alertFirstButtonReturn && !Task.isCancelled
    }

    func cancelApproval() {
        if let window = approvalWindow, let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .cancel) }
    }

    func authorize(_ url: URL) {
        if let authorizationHandler { authorizationHandler(url) }
        else { NSWorkspace.shared.open(url) }
    }

    nonisolated func open(_ url: URL) { Task { @MainActor in self.authorize(url) } }

    nonisolated func show(_ screen: Publik.Screen) async -> String? {
        await withTaskCancellationHandler {
            await self.presentGate(screen)
        } onCancel: {
            Task { @MainActor in self.finishGate(action: nil) }
        }
    }

    private func presentGate(_ screen: Publik.Screen) async -> String? {
        guard !Task.isCancelled else { return nil }
        finishGate(action: nil)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 240), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = screen.title
        window.isReleasedWhenClosed = false
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        let missingSetup = Publik.appToken.isEmpty && Publik.readCredential() == nil && ProcessInfo.processInfo.environment["PUBLIK_API_KEY"] == nil
        let body = missingSetup
            ? "Ambient has no publik app token yet. For development, launch scripts/run.sh with PUBLIK_API_KEY in its environment. The owner must list Ambient on publik before sign-in can provision this build."
            : screen.body
        let label = NSTextField(wrappingLabelWithString: body + (screen.note.map { "\n\n" + $0 } ?? ""))
        label.font = .systemFont(ofSize: 13)
        stack.addArrangedSubview(label)
        let buttons = NSStackView()
        buttons.spacing = 8
        for (index, button) in screen.buttons.enumerated() {
            let control = NSButton(title: button.label, target: self, action: #selector(gateButtonPressed(_:)))
            control.identifier = NSUserInterfaceItemIdentifier(button.action)
            if index == 0 { control.keyEquivalent = "\r" }
            buttons.addArrangedSubview(control)
        }
        let quit = NSButton(title: "Quit Ambient", target: NSApp, action: #selector(NSApplication.terminate(_:)))
        buttons.addArrangedSubview(quit)
        stack.addArrangedSubview(buttons)
        let content = window.contentView!
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -20)
        ])
        gateWindow = window
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSLog("Ambient sign-in: %@", body)
        return await withCheckedContinuation { gateContinuation = $0 }
    }

    @objc private func gateButtonPressed(_ sender: NSButton) {
        NSLog("Ambient sign-in action: %@", sender.identifier?.rawValue ?? "unknown")
        finishGate(action: sender.identifier?.rawValue)
    }

    private func finishGate(action: String?) {
        gateWindow?.orderOut(nil)
        gateWindow = nil
        let continuation = gateContinuation
        gateContinuation = nil
        continuation?.resume(returning: action)
    }
}
