import AmbientContracts
import AppKit
import SwiftUI

/// Everything inside the flow bar panel. The panel is larger than the bar; only the glass surface is drawn and
/// only the glass surface takes clicks.
public struct FlowBarRootView: View {
    var model: FlowBarModel

    public init(model: FlowBarModel) {
        self.model = model
    }

    public var body: some View {
        FlowBarAnchoredLayout(edge: model.dockEdge, anchorPoint: model.barAnchorInPanel, draggedCentre: model.draggedBarCentreInPanel) {
            FlowBarMorphingSurface(model: model)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The glass is always smoked, so the content inside is always drawn for a dark surface.
        .environment(\.colorScheme, .dark)
    }
}

/// The single piece of glass that is the bar. It grows from capsule to card and back as the state changes; the
/// content of each state fades through inside it.
struct FlowBarMorphingSurface: View {
    var model: FlowBarModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let presentation = model.presentation
        let cornerRadius = surfaceCornerRadius(for: presentation)
        let surfaceShape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        FlowBarMorphingContentLayout(currentPresentation: presentation, edge: model.dockEdge) {
            stateContent(for: presentation)
                .layoutValue(key: FlowBarPresentationLayoutKey.self, value: presentation)
                .id(presentation)
                .transition(contentTransition)
        }
        .clipShape(surfaceShape)
        .background(AmbientSmokedGlassBackground(cornerRadius: cornerRadius, isRaisedCard: !presentation.isCapsule))
        .contentShape(surfaceShape)
        .scaleEffect(model.isBeingDragged ? 1.12 : 1)
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }, action: { surfaceFrame in
            model.onSurfaceFrameChanged?(surfaceFrame)
        })
        .gesture(dragToRedock(isEnabled: presentation == .resting || presentation == .hovering))
        // The menu bar icon can be hidden behind the notch or other icons, so the bar itself also offers Quit.
        .contextMenu {
            Button("Open Settings") { model.openSettings() }
            Button(model.availableUpdateVersion.map { "Update to \($0)…" } ?? "Check for Updates…") { model.onCheckForUpdates?() }
            Divider()
            Button("Quit Ambient") { NSApplication.shared.terminate(nil) }
        }
        .animation(AmbientDesign.Motion.surfaceMorph(reduceMotion: reduceMotion), value: presentation)
        .animation(AmbientDesign.Motion.surfaceMorph(reduceMotion: reduceMotion), value: model.dockEdge)
        .animation(AmbientDesign.Motion.surfaceMorph(reduceMotion: reduceMotion), value: model.isShowingToolCallTrail)
        .animation(AmbientDesign.Motion.surfaceMorph(reduceMotion: reduceMotion), value: model.backgroundTasks.count)
        .animation(AmbientDesign.Motion.streamingGrowth(reduceMotion: reduceMotion), value: model.displayedReplyText.count)
        .animation(AmbientDesign.Motion.streamingGrowth(reduceMotion: reduceMotion), value: model.currentActivityLine)
        .animation(AmbientDesign.Motion.dockLanding(reduceMotion: reduceMotion), value: model.isBeingDragged)
    }

    /// Content of one state hands over to the next with a short fade and a touch of blur, so the eye reads one
    /// surface changing rather than two layouts swapping.
    private var contentTransition: AnyTransition {
        if reduceMotion { return .opacity }
        return .asymmetric(
            insertion: .modifier(active: FlowBarContentFadeModifier(progress: 0), identity: FlowBarContentFadeModifier(progress: 1))
                .animation(AmbientDesign.Motion.contentSwap(reduceMotion: false).delay(0.04)),
            removal: .modifier(active: FlowBarContentFadeModifier(progress: 0), identity: FlowBarContentFadeModifier(progress: 1))
                .animation(.easeOut(duration: 0.12))
        )
    }

    private func surfaceCornerRadius(for presentation: FlowBarPresentation) -> CGFloat {
        switch presentation {
        case .resting:
            let thickness = model.backgroundTasks.isEmpty ? AmbientDesign.Metrics.restingThickness : AmbientDesign.Metrics.restingWithTasksThickness
            return thickness / 2
        case .typing:
            return 20
        case .hovering, .listening, .transcribing, .thinking, .working, .taskFinishedNotice:
            return AmbientDesign.Metrics.pillThickness / 2
        case .responding, .reply, .error, .approval, .taskTray:
            return AmbientDesign.Metrics.cardCornerRadius
        }
    }

    @ViewBuilder
    private func stateContent(for presentation: FlowBarPresentation) -> some View {
        let isUpright = model.dockEdge.isVertical && presentation.followsEdgeOrientation
        switch presentation {
        case .resting: FlowBarRestingContent(model: model, isUpright: isUpright)
        case .hovering: FlowBarHoverContent(model: model, isUpright: isUpright)
        case .listening: FlowBarVoiceContent(model: model, mode: .listening, isUpright: isUpright)
        case .transcribing: FlowBarVoiceContent(model: model, mode: .transcribing, isUpright: isUpright)
        case .thinking, .working: FlowBarActivityContent(model: model)
        case .typing: FlowBarTypingContent(model: model)
        case .responding, .reply: FlowBarReplyCard(model: model)
        case .error: FlowBarErrorCard(model: model)
        case .approval: FlowBarApprovalCard(model: model)
        case .taskTray: FlowBarTaskTrayCard(model: model)
        case .taskFinishedNotice: FlowBarTaskFinishedNotice(model: model)
        }
    }

    private func dragToRedock(isEnabled: Bool) -> some Gesture {
        DragGesture(minimumDistance: isEnabled ? 3 : .infinity, coordinateSpace: .global)
            .onChanged { _ in model.onBarDragChanged?() }
            .onEnded { _ in model.onBarDragEnded?() }
    }
}

private struct FlowBarContentFadeModifier: ViewModifier {
    var progress: Double
    func body(content: Content) -> some View {
        content
            .opacity(progress)
            .blur(radius: (1 - progress) * 5)
            .scaleEffect(0.96 + 0.04 * progress)
    }
}

// MARK: - Resting

struct FlowBarRestingContent: View {
    var model: FlowBarModel
    var isUpright: Bool

    var body: some View {
        let visibleTasks = Array(model.backgroundTasks.prefix(3))
        let hiddenTaskCount = model.backgroundTasks.count - visibleTasks.count
        let thickness = visibleTasks.isEmpty ? AmbientDesign.Metrics.restingThickness : AmbientDesign.Metrics.restingWithTasksThickness
        let length = visibleTasks.isEmpty ? AmbientDesign.Metrics.restingLength : max(AmbientDesign.Metrics.restingLength + 6, CGFloat(visibleTasks.count) * 10 + (hiddenTaskCount > 0 ? 18 : 0) + 18)

        Group {
            if visibleTasks.isEmpty {
                Color.clear
            } else {
                let dots = ForEach(visibleTasks) { task in FlowBarTaskStatusDot(status: task.status) }
                let overflowLabel = Text("+\(hiddenTaskCount)").font(.system(size: 9, weight: .semibold).monospacedDigit()).foregroundStyle(AmbientDesign.Palette.onSmokeSecondary)
                if isUpright {
                    VStack(spacing: 5) { dots; if hiddenTaskCount > 0 { overflowLabel } }
                } else {
                    HStack(spacing: 5) { dots; if hiddenTaskCount > 0 { overflowLabel } }
                }
            }
        }
        .frame(width: isUpright ? thickness : length, height: isUpright ? length : thickness)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(visibleTasks.isEmpty ? "Ambient" : "Ambient, \(model.runningBackgroundTaskCount) tasks running")
    }
}

/// One small dot per background task: ember while running, white when done, red when it failed.
struct FlowBarTaskStatusDot: View {
    var status: AmbientBackgroundTask.Status
    var diameter: CGFloat = 5

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isAmbientSnapshotRendering) private var isSnapshotRendering

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: status != .running || reduceMotion || isSnapshotRendering)) { timeline in
            let pulse = (status == .running && !reduceMotion && !isSnapshotRendering)
                ? 0.55 + 0.45 * (0.5 + 0.5 * sin(timeline.date.timeIntervalSinceReferenceDate * 2 * .pi / 1.4))
                : 1
            Circle()
                .fill(color)
                .frame(width: diameter, height: diameter)
                .opacity(pulse)
                .shadow(color: status == .running ? AmbientDesign.Palette.ember.opacity(0.7 * pulse) : .clear, radius: 2.5)
        }
    }

    private var color: Color {
        switch status {
        case .running: return AmbientDesign.Palette.ember
        case .succeeded: return Color.white.opacity(0.88)
        case .failed: return AmbientDesign.Palette.alert
        case .cancelled: return Color.white.opacity(0.35)
        }
    }
}

// MARK: - Hover

struct FlowBarHoverContent: View {
    var model: FlowBarModel
    var isUpright: Bool

    var body: some View {
        Group {
            if isUpright {
                VStack(spacing: 8) {
                    VStack(spacing: 4) {
                        ForEach(model.pushToTalkShortcut.keycapSymbolNames, id: \.self) { symbolName in
                            AmbientKeycap(systemImageName: symbolName)
                        }
                    }
                    .help("Hold \(model.pushToTalkShortcut.spokenName), then talk")
                    if !model.backgroundTasks.isEmpty { FlowBarTasksChip(model: model, isUpright: true) }
                    divider
                    AmbientGlassIconButton(systemImageName: "keyboard", accessibilityLabelText: "Type instead") { model.beginTyping() }
                    AmbientGlassIconButton(systemImageName: "gearshape", accessibilityLabelText: "Settings") { model.openSettings() }
                }
                .padding(.vertical, 8)
                .frame(width: AmbientDesign.Metrics.pillThickness)
            } else {
                HStack(spacing: 8) {
                    HStack(spacing: 3) {
                        ForEach(model.pushToTalkShortcut.keycapSymbolNames, id: \.self) { symbolName in
                            AmbientKeycap(systemImageName: symbolName)
                        }
                    }
                    Text("Hold to talk")
                        .font(AmbientDesign.Typeface.pillLabel)
                        .foregroundStyle(AmbientDesign.Palette.onSmokePrimary)
                        .fixedSize()
                    if !model.backgroundTasks.isEmpty {
                        divider
                        FlowBarTasksChip(model: model, isUpright: false)
                    }
                    divider
                    HStack(spacing: 0) {
                        AmbientGlassIconButton(systemImageName: "keyboard", accessibilityLabelText: "Type instead") { model.beginTyping() }
                        AmbientGlassIconButton(systemImageName: "gearshape", accessibilityLabelText: "Settings") { model.openSettings() }
                    }
                }
                .padding(.leading, 8)
                .padding(.trailing, 5)
                .frame(height: AmbientDesign.Metrics.pillThickness)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.beginTyping() }
    }

    private var divider: some View {
        Rectangle()
            .fill(AmbientDesign.Palette.onSmokeHairline)
            .frame(width: isUpright ? 18 : 1, height: isUpright ? 1 : 16)
    }
}

/// "2 running" with the task dots: opens the background task tray.
struct FlowBarTasksChip: View {
    var model: FlowBarModel
    var isUpright: Bool
    @State private var isHovering = false

    var body: some View {
        Button { model.toggleTaskTray() } label: {
            let dots = ForEach(Array(model.backgroundTasks.prefix(3))) { task in FlowBarTaskStatusDot(status: task.status) }
            Group {
                if isUpright {
                    VStack(spacing: 4) { dots }.padding(.vertical, 7).frame(width: 24)
                } else {
                    HStack(spacing: 6) {
                        HStack(spacing: 3) { dots }
                        Text(summary)
                            .font(.system(size: 12, weight: .medium).monospacedDigit())
                            .foregroundStyle(AmbientDesign.Palette.onSmokePrimary)
                            .fixedSize()
                    }
                    .padding(.horizontal, 9)
                    .frame(height: 24)
                }
            }
            .background(Capsule(style: .continuous).fill(isHovering ? AmbientDesign.Palette.onSmokeFillHover : AmbientDesign.Palette.onSmokeFill))
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(AmbientPressScaleButtonStyle())
        .onHover { hovering in withAnimation(AmbientDesign.Motion.hoverFeedback) { isHovering = hovering } }
        .ambientPointingHandCursor()
        .help("Background tasks")
        .accessibilityLabel("Background tasks, \(summary)")
    }

    private var summary: String {
        let runningCount = model.runningBackgroundTaskCount
        if runningCount > 0 { return "\(runningCount) running" }
        return "\(model.backgroundTasks.count) done"
    }
}

// MARK: - Listening and transcribing

struct FlowBarVoiceContent: View {
    var model: FlowBarModel
    var mode: FlowBarWaveformView.Mode
    var isUpright: Bool

    var body: some View {
        FlowBarWaveformView(model: model, mode: mode, isVertical: isUpright)
            .frame(width: isUpright ? AmbientDesign.Metrics.pillThickness : 104, height: isUpright ? 104 : AmbientDesign.Metrics.pillThickness)
    }
}

// MARK: - Thinking and working

struct FlowBarActivityContent: View {
    var model: FlowBarModel

    var body: some View {
        let isWorking = model.presentation == .working
        let earlierToolCalls = Array(model.toolCallsThisTurn.dropLast())
        VStack(alignment: .leading, spacing: 0) {
            if model.isShowingToolCallTrail && !earlierToolCalls.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(earlierToolCalls) { toolCall in
                        FlowBarToolCallRow(toolCall: toolCall)
                    }
                }
                .padding(.leading, 14)
                .padding(.trailing, 16)
                .padding(.top, 12)
                .padding(.bottom, 4)
                .transition(.opacity)
            }
            HStack(spacing: 8) {
                AmbientEmberIndicator(activity: isWorking ? .working : .thinking)
                AmbientProposalLimit(maximumWidth: 240) {
                    Text(isWorking ? (model.currentActivityLine ?? "Working") : "Thinking")
                        .font(AmbientDesign.Typeface.pillLabel)
                        .foregroundStyle(AmbientDesign.Palette.onSmokePrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .contentTransition(.opacity)
                }
                if isWorking && earlierToolCalls.count > 0 {
                    Text("\(model.toolCallsThisTurn.count) steps")
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(AmbientDesign.Palette.onSmokeTertiary)
                        .fixedSize()
                }
                AmbientGlassIconButton(systemImageName: "xmark", accessibilityLabelText: "Stop", diameter: 22, symbolPointSize: 9.5) { model.cancelCurrentTurn() }
            }
            .padding(.leading, 8)
            .padding(.trailing, 7)
            .frame(height: AmbientDesign.Metrics.pillThickness)
        }
        .fixedSize()
        .contentShape(Rectangle())
        .onHover { isHovering in model.isShowingToolCallTrail = isHovering && isWorking }
    }
}

struct FlowBarToolCallRow: View {
    var toolCall: FlowBarToolCall

    var body: some View {
        HStack(spacing: 8) {
            Group {
                switch toolCall.status {
                case .running: AmbientRunningArc(diameter: 10)
                case .succeeded: Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(AmbientDesign.Palette.onSmokeSecondary)
                case .failed: Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(AmbientDesign.Palette.alert)
                }
            }
            .frame(width: 14)
            Text(toolCall.activityLabel)
                .font(.system(size: 12))
                .foregroundStyle(AmbientDesign.Palette.onSmokeSecondary)
                .lineLimit(1)
        }
    }
}

// MARK: - Typing

struct FlowBarTypingContent: View {
    @Bindable var model: FlowBarModel
    @FocusState private var isTextFieldFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            AmbientEmberIndicator(activity: .idle, diameter: 12)
            TextField("Ask Ambient", text: $model.typedText)
                .textFieldStyle(.plain)
                .font(.system(size: 13.5))
                .foregroundStyle(AmbientDesign.Palette.onSmokePrimary)
                .focused($isTextFieldFocused)
                .onSubmit { model.submitTypedText() }
                .onExitCommand { model.endTyping() }
            let canSend = !model.typedText.trimmingCharacters(in: .whitespaces).isEmpty
            Button { model.submitTypedText() } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 11.5, weight: .bold))
                    .foregroundStyle(canSend ? AmbientDesign.Palette.emberInk : AmbientDesign.Palette.onSmokeTertiary)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(canSend ? AmbientDesign.Palette.ember : AmbientDesign.Palette.onSmokeFill))
            }
            .buttonStyle(AmbientPressScaleButtonStyle(pressedScale: 0.9))
            .disabled(!canSend)
            .ambientPointingHandCursor()
            .accessibilityLabel("Send")
        }
        .padding(.leading, 10)
        .padding(.trailing, 7)
        .frame(width: 380, height: 40)
        .task {
            // The panel becomes key a moment after typing starts; focusing before that is ignored.
            try? await Task.sleep(nanoseconds: 60_000_000)
            isTextFieldFocused = true
        }
    }
}
