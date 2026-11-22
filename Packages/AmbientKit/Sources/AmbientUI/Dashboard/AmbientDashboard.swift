import AmbientContracts
import AppKit
import SwiftUI

@MainActor
public final class AmbientDashboardWindowController: NSWindowController, NSWindowDelegate {
    private let model: FlowBarModel
    private let onReturnToBar: () -> Void
    private var keyMonitor: Any?
    private var isHoldingSpace = false

    public init(model: FlowBarModel, onReturnToBar: @escaping () -> Void) {
        self.model = model
        self.onReturnToBar = onReturnToBar
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 680),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Ambient"
        window.minSize = NSSize(width: 680, height: 520)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("AmbientDashboard")
        window.appearance = NSAppearance(named: .darkAqua)
        super.init(window: window)
        window.delegate = self
        window.contentView = NSHostingView(rootView: AmbientDashboardView(model: model, onReturnToBar: { [weak self] in
            self?.close()
        }))
        if !window.setFrameUsingName("AmbientDashboard") { window.center() }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self, self.window?.isKeyWindow == true, event.keyCode == 49,
                  event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                  !(self.window?.firstResponder is NSTextView) else { return event }
            if event.type == .keyDown {
                if !event.isARepeat, !self.isHoldingSpace {
                    self.isHoldingSpace = true
                    self.model.onStartListening?()
                }
            } else if self.isHoldingSpace {
                self.isHoldingSpace = false
                self.model.onFinishListening?()
            }
            return nil
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public func show() {
        model.isDashboardVisible = true
        NSApp.setActivationPolicy(.regular)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    public func windowWillClose(_ notification: Notification) {
        finishHoldingSpace()
        if model.turnPhase == .listening { model.onFinishListening?() }
        model.isDashboardVisible = false
        NSApp.setActivationPolicy(.accessory)
        onReturnToBar()
    }

    public func windowDidMiniaturize(_ notification: Notification) { finishHoldingSpace(); model.isDashboardVisible = false }
    public func windowDidDeminiaturize(_ notification: Notification) { model.isDashboardVisible = true }
    public func windowDidResignKey(_ notification: Notification) { finishHoldingSpace() }

    private func finishHoldingSpace() {
        guard isHoldingSpace else { return }
        isHoldingSpace = false
        model.onFinishListening?()
    }

    deinit { if let keyMonitor { NSEvent.removeMonitor(keyMonitor) } }
}

public struct AmbientDashboardView: View {
    private var model: FlowBarModel
    private var onReturnToBar: () -> Void
    @State private var showsTyping = false
    @State private var typedRequest = ""
    @FocusState private var isTypingFocused: Bool

    public init(model: FlowBarModel, onReturnToBar: @escaping () -> Void = {}) {
        self.model = model
        self.onReturnToBar = onReturnToBar
    }

    public var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(spacing: 0) {
                HStack {
                    Text("Ambient").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Button("Return to bar", systemImage: "rectangle.bottomthird.inset.filled", action: onReturnToBar)
                        .buttonStyle(.borderless)
                        .ambientPointingHandCursor()
                }.padding(20)
                ScrollView {
                    VStack(spacing: 20) {
                        PresenceView(phase: presencePhase, diameter: model.turnPhase == .idle ? 260 : 190)
                            .environment(\.windowIsVisible, model.isDashboardVisible)
                            .accessibilityHidden(true)
                        Text(statusText).font(.system(size: 22, weight: .medium))
                            .accessibilityAddTraits(.updatesFrequently)
                        if model.turnPhase == .idle {
                            Text("Talk through an idea. Ask about your screen. Hand off a task.")
                                .foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }
                        if !model.lastRequestText.isEmpty, model.turnPhase != .listening {
                            Text("“\(model.lastRequestText)”").font(.system(size: 14))
                                .foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        if !model.toolCallsThisTurn.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(model.toolCallsThisTurn) { call in
                                    HStack(spacing: 10) {
                                        if call.status == .running { ProgressView().controlSize(.small) }
                                        else { Image(systemName: call.status == .succeeded ? "checkmark" : "exclamationmark.circle") }
                                        Text(call.activityLabel)
                                    }.foregroundStyle(call.status == .failed ? Color.red : Color.secondary)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if model.pendingApproval != nil {
                            FlowBarApprovalCard(model: model)
                                .background(AmbientSmokedGlassBackground(cornerRadius: 16, isRaisedCard: true))
                                .environment(\.colorScheme, .dark)
                        }
                        if !model.displayedReplyText.isEmpty {
                            AmbientLightMarkdownView(markdownText: model.displayedReplyText)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .environment(\.openURL, OpenURLAction { model.onOpenURL($0); return .handled })
                        }
                        if let notice = model.currentErrorNotice {
                            VStack(alignment: .leading, spacing: 10) {
                                Label(notice.message, systemImage: "exclamationmark.circle").foregroundStyle(.red)
                                if let link = notice.link { Button(link.title) { model.followErrorLink(link) } }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }.frame(maxWidth: 520).padding(.horizontal, 32).padding(.bottom, 24)
                        .frame(maxWidth: .infinity)
                }
                footer
            }
        }
        .font(.system(size: 13))
        .background(AmbientDesign.Palette.windowBackground)
        .environment(\.colorScheme, .dark)
        .onExitCommand {
            if showsTyping { showsTyping = false }
            else { model.cancelCurrentTurn() }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("YOUR WORKSPACE").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                .padding(.top, 24).padding(.bottom, 8)
            sectionButton("Connected apps", symbol: "point.3.connected.trianglepath.dotted", section: .connectors)
            sectionButton("Memory", symbol: "brain.head.profile", section: .memory)
            sectionButton("Skills", symbol: "puzzlepiece.extension", section: .skills)
            Divider().padding(.vertical, 8)
            HStack {
                Text("Background agents").fontWeight(.medium)
                Spacer()
                if model.runningBackgroundTaskCount > 0 { Text("\(model.runningBackgroundTaskCount)").foregroundStyle(.secondary) }
            }
            if model.backgroundTasks.isEmpty {
                Text("Longer jobs appear here while you keep working.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(3)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(model.backgroundTasks) { task in
                            Button { model.onOpenBackgroundTaskTranscript?(task.id) } label: {
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: task.status == .running ? "circle.dotted" : (task.status == .succeeded ? "checkmark.circle" : "exclamationmark.circle"))
                                    Text(task.title).lineLimit(3).multilineTextAlignment(.leading)
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
                            }.buttonStyle(.borderless).ambientPointingHandCursor()
                        }
                    }
                }
            }
            Spacer(minLength: 0)
            sectionButton("Settings", symbol: "gearshape", section: .general)
        }.padding(.horizontal, 18).padding(.bottom, 20).frame(width: 200)
            .background(AmbientDesign.Palette.sidebarBackground)
    }

    private func sectionButton(_ title: String, symbol: String, section: AmbientSettingsSection) -> some View {
        Button { model.onOpenDashboardSection?(section) } label: {
            Label(title, systemImage: symbol).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 5)
        }.buttonStyle(.borderless).ambientPointingHandCursor()
    }

    private var footer: some View {
        VStack(spacing: 12) {
            Divider()
            if showsTyping {
                HStack {
                    TextField("Ask Ambient", text: $typedRequest).textFieldStyle(.roundedBorder)
                        .focused($isTypingFocused).onSubmit { sendTypedRequest() }
                    Button("Send", action: sendTypedRequest).keyboardShortcut(.return, modifiers: .command)
                }.padding(.horizontal, 24)
            }
            HStack(spacing: 16) {
                Button {
                    if model.turnPhase == .listening { model.onFinishListening?() }
                    else { model.onStartListening?() }
                } label: {
                    Label(model.turnPhase == .listening ? "Finish talking" : "Talk to Ambient",
                          systemImage: model.turnPhase == .listening ? "stop.fill" : "mic.fill")
                }.buttonStyle(.borderedProminent).tint(AmbientDesign.Palette.ember)
                Text("or hold Space").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                if isBusy { Button("Stop") { model.cancelCurrentTurn() }.keyboardShortcut(".", modifiers: .command) }
                Button("Type instead", systemImage: "keyboard") { showsTyping = true; isTypingFocused = true }
                    .buttonStyle(.borderless).keyboardShortcut("l", modifiers: .command)
            }.ambientPointingHandCursor().padding(.horizontal, 24).padding(.bottom, 18)
        }
    }

    private func sendTypedRequest() {
        let text = typedRequest.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        typedRequest = ""
        showsTyping = false
        model.onSubmitTypedText?(text)
    }

    private var isBusy: Bool {
        switch model.turnPhase {
        case .idle, .replyFinished, .error: return false
        default: return true
        }
    }

    private var statusText: String {
        if model.pendingApproval != nil { return "Your approval is needed" }
        switch model.turnPhase {
        case .idle: return "What’s on your mind?"
        case .listening: return "Listening to you"
        case .transcribing: return "Getting your words"
        case .thinking: return "Thinking it through"
        case .working: return model.currentActivityLine ?? "Working on it"
        case .responding: return "Here’s what I found"
        case .replyFinished: return "Ready when you are"
        case .error: return "Let’s try that again"
        }
    }

    private var presencePhase: PresencePhase {
        switch model.turnPhase {
        case .idle, .replyFinished, .error: return .idle
        case .listening: return .listening(level: model.audioLevel)
        case .transcribing: return .transcribing
        case .thinking: return .thinking
        case .working: return .working(activityLabel: model.currentActivityLine ?? "Working")
        case .responding: return .responding
        }
    }
}
