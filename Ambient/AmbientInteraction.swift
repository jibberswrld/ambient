import AppKit
import AmbientAgent
import AmbientUI

@MainActor
final class AmbientInteraction: NSObject, PublikGateUI {
    let onboardingController = AmbientOnboardingWindowController()
    var approvalHandler: (@MainActor (String, String) async -> Bool)?
    var cancelApprovalHandler: (() -> Void)?

    func approve(title: String, detail: String) async -> Bool {
        guard !Task.isCancelled, let approvalHandler else { return false }
        return await approvalHandler(title, detail) && !Task.isCancelled
    }

    func closeGate() { onboardingController.close() }

    func cancelApproval() { cancelApprovalHandler?() }
    func authorize(_ url: URL) { NSWorkspace.shared.open(url) }
    nonisolated func open(_ url: URL) { Task { @MainActor in self.authorize(url) } }

    nonisolated func show(_ screen: Publik.Screen) async -> String? {
        await withTaskCancellationHandler {
            guard !Task.isCancelled else { return nil }
            return await self.presentGate(screen)
        } onCancel: {
            Task { @MainActor in self.onboardingController.close() }
        }
    }

    private func presentGate(_ screen: Publik.Screen) async -> String? {
        let missingSetup = Publik.appToken.isEmpty && Publik.readCredential() == nil && ProcessInfo.processInfo.environment["PUBLIK_API_KEY"] == nil
        let body = missingSetup
            ? "Ambient needs a publik app token. For development, launch scripts/run.sh with PUBLIK_API_KEY in its environment."
            : screen.body
        return await onboardingController.presentGate(AmbientGateContent(
            title: screen.title, bodyText: body, note: screen.note, isWaiting: screen.note != nil,
            buttons: screen.buttons.enumerated().map { index, button in
                AmbientGateButton(actionID: button.action, label: button.label, prominence: index == 0 ? .primary : .secondary)
            }
        ))
    }
}
