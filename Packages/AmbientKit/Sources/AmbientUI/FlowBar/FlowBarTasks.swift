import AmbientContracts
import SwiftUI

/// SwiftUI declares its own `BackgroundTask`; this name keeps the contract's type unambiguous in view code.
typealias AmbientBackgroundTask = AmbientContracts.BackgroundTask

/// "0:42", "12:05", "1:02:09".
enum AmbientElapsedTimeFormatter {
    static func string(from startDate: Date, to endDate: Date) -> String {
        let totalSeconds = max(0, Int(endDate.timeIntervalSince(startDate)))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, seconds) }
        return String(format: "%d:%02d", minutes, seconds)
    }
}

extension AmbientBackgroundTask.Kind {
    var displayName: String {
        switch self {
        case .codexAgent: return "Codex"
        case .claudeAgent: return "Claude Code"
        case .shellCommand: return "Command"
        case .ambientAgent: return "Ambient"
        }
    }
}

// MARK: - Tray

/// The background task tray: one row per task with what it is doing now, and results for finished ones.
struct FlowBarTaskTrayCard: View {
    var model: FlowBarModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Background")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AmbientDesign.Palette.onSmokePrimary)
                Text(summary)
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(AmbientDesign.Palette.onSmokeTertiary)
                Spacer(minLength: 8)
                AmbientGlassIconButton(systemImageName: collapseSymbolName, accessibilityLabelText: "Close", diameter: 24, symbolPointSize: 10) { model.collapseTaskTray() }
            }
            .padding(.leading, 2)
            AmbientProposalLimit(maximumHeight: 330) {
                ViewThatFits(in: .vertical) {
                    rows
                    ScrollView(.vertical) { rows.padding(.bottom, 10) }
                        .mask(AmbientScrollEdgeFade(fadesTopEdge: false, fadesBottomEdge: true))
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .frame(width: 364)
    }

    private var rows: some View {
        VStack(spacing: 2) {
            ForEach(model.backgroundTasks) { task in
                FlowBarTaskRow(model: model, backgroundTask: task)
            }
        }
    }

    private var summary: String {
        let runningCount = model.runningBackgroundTaskCount
        let finishedCount = model.backgroundTasks.count - runningCount
        switch (runningCount, finishedCount) {
        case (0, _): return "\(finishedCount) finished"
        case (_, 0): return "\(runningCount) running"
        default: return "\(runningCount) running, \(finishedCount) finished"
        }
    }

    /// The collapse arrow points back toward the edge the tray grew from.
    private var collapseSymbolName: String {
        switch model.dockEdge {
        case .bottom: return "chevron.down"
        case .top: return "chevron.up"
        case .left: return "chevron.left"
        case .right: return "chevron.right"
        }
    }
}

struct FlowBarTaskRow: View {
    var model: FlowBarModel
    var backgroundTask: AmbientBackgroundTask
    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            statusGlyph
                .frame(width: 16, height: 16)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(backgroundTask.title)
                        .font(AmbientDesign.Typeface.rowTitle)
                        .foregroundStyle(AmbientDesign.Palette.onSmokePrimary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    elapsedLabel
                }
                Text(detailText)
                    .font(AmbientDesign.Typeface.rowDetail)
                    .foregroundStyle(backgroundTask.status == .failed ? AmbientDesign.Palette.alert.opacity(0.9) : AmbientDesign.Palette.onSmokeSecondary)
                    .lineLimit(backgroundTask.status == .running ? 1 : 3)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
                Text(sourceLine)
                    .font(.system(size: 11))
                    .foregroundStyle(AmbientDesign.Palette.onSmokeTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if backgroundTask.status != .running {
                    HStack(spacing: 4) {
                        AmbientCapsuleButton(title: "Transcript", systemImageName: "text.alignleft", prominence: .secondary, isCompact: true) {
                            model.openBackgroundTaskTranscript(backgroundTask.id)
                        }
                        AmbientCapsuleButton(title: "Dismiss", prominence: .quiet, isCompact: true) {
                            model.dismissBackgroundTask(backgroundTask.id)
                        }
                    }
                    .padding(.top, 5)
                    .padding(.leading, -2)
                }
            }
            if backgroundTask.status == .running {
                AmbientGlassIconButton(systemImageName: "xmark", accessibilityLabelText: "Stop task", diameter: 22, symbolPointSize: 9) {
                    model.cancelBackgroundTask(backgroundTask.id)
                }
                .opacity(isHovering ? 1 : 0)
                .padding(.top, -3)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(isHovering ? AmbientDesign.Palette.onSmokeFill : .clear))
        .onHover { hovering in withAnimation(AmbientDesign.Motion.hoverFeedback) { isHovering = hovering } }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var statusGlyph: some View {
        switch backgroundTask.status {
        case .running:
            AmbientRunningArc(diameter: 13)
        case .succeeded:
            Image(systemName: "checkmark.circle.fill").font(.system(size: 14)).foregroundStyle(Color.white.opacity(0.88))
        case .failed:
            Image(systemName: "exclamationmark.circle.fill").font(.system(size: 14)).foregroundStyle(AmbientDesign.Palette.alert)
        case .cancelled:
            Image(systemName: "minus.circle.fill").font(.system(size: 14)).foregroundStyle(Color.white.opacity(0.4))
        }
    }

    private var elapsedLabel: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            Text(AmbientElapsedTimeFormatter.string(from: backgroundTask.startedAt, to: backgroundTask.finishedAt ?? timeline.date))
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(AmbientDesign.Palette.onSmokeTertiary)
        }
    }

    private var detailText: String {
        switch backgroundTask.status {
        case .running: return backgroundTask.latestActivity
        case .succeeded: return backgroundTask.result.map(Self.plainText) ?? backgroundTask.latestActivity
        case .failed: return backgroundTask.result.map(Self.plainText) ?? "It stopped with an error."
        case .cancelled: return "Stopped."
        }
    }

    /// Agents answer in markdown. The row has room for a few plain lines, so links and emphasis
    /// are reduced to their words instead of showing raw brackets and asterisks.
    private static func plainText(fromMarkdown markdownText: String) -> String {
        String(AmbientLightMarkdownParser.inlineAttributedText(markdownText).characters)
    }

    private var sourceLine: String {
        guard let workingDirectory = backgroundTask.workingDirectory else { return backgroundTask.kind.displayName }
        let homePath = FileManager.default.homeDirectoryForCurrentUser.path
        let shortenedDirectory = workingDirectory.hasPrefix(homePath) ? "~" + workingDirectory.dropFirst(homePath.count) : workingDirectory
        return "\(backgroundTask.kind.displayName) in \(shortenedDirectory)"
    }
}

// MARK: - Finished notice

/// A task finished while the bar was resting: the bar briefly opens into a pill that says so.
struct FlowBarTaskFinishedNotice: View {
    var model: FlowBarModel

    var body: some View {
        let finishedTask = model.recentlyFinishedTask
        let didSucceed = finishedTask?.status == .succeeded
        Button { model.toggleTaskTray() } label: {
            HStack(spacing: 8) {
                ZStack {
                    Circle().fill(didSucceed ? AmbientDesign.Palette.ember : AmbientDesign.Palette.alert)
                    Image(systemName: didSucceed ? "checkmark" : "exclamationmark")
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(AmbientDesign.Palette.emberInk)
                }
                .frame(width: 18, height: 18)
                .shadow(color: (didSucceed ? AmbientDesign.Palette.ember : AmbientDesign.Palette.alert).opacity(0.6), radius: 5)
                AmbientProposalLimit(maximumWidth: 230) {
                    Text(noticeText(for: finishedTask))
                        .font(AmbientDesign.Typeface.pillLabel)
                        .foregroundStyle(AmbientDesign.Palette.onSmokePrimary)
                        .lineLimit(1)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(AmbientDesign.Palette.onSmokeTertiary)
            }
            .padding(.leading, 9)
            .padding(.trailing, 13)
            .frame(height: AmbientDesign.Metrics.pillThickness)
            .contentShape(Rectangle())
        }
        .buttonStyle(AmbientPressScaleButtonStyle(pressedScale: 0.98))
        .ambientPointingHandCursor()
        .fixedSize()
    }

    private func noticeText(for finishedTask: AmbientBackgroundTask?) -> String {
        guard let finishedTask else { return "Task finished" }
        switch finishedTask.status {
        case .succeeded: return "Done: \(finishedTask.title)"
        case .failed: return "Failed: \(finishedTask.title)"
        case .cancelled: return "Stopped: \(finishedTask.title)"
        case .running: return finishedTask.title
        }
    }
}
