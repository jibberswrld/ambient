import AppKit
import SwiftUI

// The coach card: a small piece of the same smoked glass as the bar, floating away from it. It teaches one real
// action at a time and its status line says what is actually happening.

enum AmbientTourMetrics {
    static let cardWidth: CGFloat = 340
    static let contentWidth: CGFloat = cardWidth - AmbientDesign.Metrics.cardPadding * 2
    /// A quiet capsule button draws its label inset by its own padding; pulling it out by that much lines the text
    /// up with the card's content edge.
    static let quietButtonOpticalInset: CGFloat = 10
}

/// The whole coach: a lesson, or the closing cheat sheet.
public struct AmbientTourCoachCard: View {
    var model: AmbientTourModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(model: AmbientTourModel) {
        self.model = model
    }

    public var body: some View {
        ZStack(alignment: .topLeading) {
            switch model.step {
            case .lesson(let lesson):
                AmbientTourLessonContent(model: model, lesson: lesson)
                    .id(lesson)
                    .transition(stepTransition)
            case .finished:
                AmbientTourFinishContent(model: model)
                    .transition(stepTransition)
            }
        }
        .padding(AmbientDesign.Metrics.cardPadding)
        .frame(width: AmbientTourMetrics.cardWidth, alignment: .topLeading)
        // Content is clipped so a lesson sliding out never shows past the glass; the glass itself is not clipped,
        // because it draws its own shadow.
        .clipShape(RoundedRectangle(cornerRadius: AmbientDesign.Metrics.cardCornerRadius, style: .continuous))
        .background(AmbientSmokedGlassBackground(cornerRadius: AmbientDesign.Metrics.cardCornerRadius, isRaisedCard: true))
        .contentShape(RoundedRectangle(cornerRadius: AmbientDesign.Metrics.cardCornerRadius, style: .continuous))
        .animation(AmbientDesign.Motion.surfaceMorph(reduceMotion: reduceMotion), value: model.step)
        .animation(AmbientDesign.Motion.surfaceMorph(reduceMotion: reduceMotion), value: model.isCurrentLessonComplete)
        .animation(AmbientDesign.Motion.contentSwap(reduceMotion: reduceMotion), value: model.status)
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Ambient tour")
    }

    /// The next lesson arrives from the trailing side and the previous one leaves toward the leading side, like a
    /// page turning. Reduce Motion keeps only the fade.
    private var stepTransition: AnyTransition {
        if reduceMotion { return .opacity }
        return .asymmetric(
            insertion: .offset(x: 18).combined(with: .opacity),
            removal: .offset(x: -18).combined(with: .opacity)
        )
    }
}

// MARK: - Lesson

struct AmbientTourLessonContent: View {
    var model: AmbientTourModel
    var lesson: AmbientTourLesson

    var body: some View {
        let status = model.status
        VStack(alignment: .leading, spacing: 0) {
            AmbientTourHeader(model: model, lesson: lesson)
                .padding(.bottom, 12)
            Text(lesson.title)
                .font(.system(size: 15, weight: .semibold))
                .tracking(-0.2)
                .foregroundStyle(AmbientDesign.Palette.onSmokePrimary)
                .padding(.bottom, 4)
            Text(model.completionNote ?? lesson.bodyText(shortcut: model.shortcut))
                .font(.system(size: 12.5))
                .lineSpacing(2)
                .foregroundStyle(AmbientDesign.Palette.onSmokeSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .id(model.isCurrentLessonComplete)
                .transition(.opacity)
            if !model.isCurrentLessonComplete {
                demonstration
                    .padding(.top, 12)
                    .transition(.opacity)
            }
            AmbientTourStatusRow(status: status) {
                trailingControl(status: status)
            }
            .padding(.top, 14)
        }
        .frame(width: AmbientTourMetrics.contentWidth, alignment: .leading)
    }

    @ViewBuilder
    private var demonstration: some View {
        if let phrase = lesson.suggestedPhrase {
            AmbientTourPhraseBlock(
                shortcut: model.shortcut,
                isShortcutHeld: model.isShortcutHeld,
                leadIn: lesson == .talk ? "Hold and say anything, like" : "Hold and say",
                phrase: phrase
            )
        } else if lesson == .placeBar {
            AmbientTourEdgeDiagram(dockEdge: model.dockEdge)
        }
    }

    /// The one control beside the status line: Next once the lesson is done, the fix for a problem, or the
    /// lesson's own action. Next is the only ember button while it shows.
    @ViewBuilder
    private func trailingControl(status: AmbientTourStatus) -> some View {
        if model.isCurrentLessonComplete {
            AmbientCapsuleButton(title: "Next", prominence: .primary, isCompact: true) { model.advanceToNextStep() }
                .keyboardShortcut(.defaultAction)
                .transition(.opacity.combined(with: .scale(scale: 0.94)))
        } else if let action = status.action {
            AmbientCapsuleButton(title: Self.actionTitle(action), systemImageName: Self.actionSymbol(action), prominence: .secondary, isCompact: true) {
                model.performStatusAction(action)
            }
        } else if lesson == .connectApps {
            AmbientCapsuleButton(title: "Open Connectors", systemImageName: "arrow.up.right", prominence: model.hasOpenedConnectors ? .secondary : .primary, isCompact: true) {
                model.openConnectors()
            }
        } else if lesson == .placeBar {
            AmbientCapsuleButton(title: lesson.skipTitle, prominence: .secondary, isCompact: true) { model.skipCurrentLesson() }
        }
    }

    static func actionTitle(_ action: AmbientTourStatus.Action) -> String {
        switch action {
        case .fixPermission(_, let permissionStatus): return permissionStatus == .notYetAsked ? "Allow" : "Open Settings"
        case .tryAgain: return "Try again"
        }
    }

    static func actionSymbol(_ action: AmbientTourStatus.Action) -> String? {
        switch action {
        case .fixPermission(_, let permissionStatus): return permissionStatus == .notYetAsked ? nil : "arrow.up.right"
        case .tryAgain: return "arrow.counterclockwise"
        }
    }
}

/// The step indicator, "2 of 5", and the quiet way out.
struct AmbientTourHeader: View {
    var model: AmbientTourModel
    var lesson: AmbientTourLesson

    var body: some View {
        HStack(spacing: 9) {
            AmbientTourProgressSegments(completedCount: lesson.rawValue + (model.isCurrentLessonComplete ? 1 : 0), currentIndex: lesson.rawValue)
            Text("\(lesson.number) of \(AmbientTourLesson.allCases.count)")
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(AmbientDesign.Palette.onSmokeTertiary)
            Spacer(minLength: 8)
            HStack(spacing: 0) {
                // The last lesson's way past is its own answer ("It's fine here") beside the status line.
                if lesson != .placeBar && !model.isCurrentLessonComplete {
                    AmbientCapsuleButton(title: lesson.skipTitle, prominence: .quiet, isCompact: true) { model.skipCurrentLesson() }
                        .transition(.opacity)
                }
                AmbientCapsuleButton(title: "End tour", prominence: .quiet, isCompact: true) { model.endTour() }
            }
            .padding(.trailing, -AmbientTourMetrics.quietButtonOpticalInset)
        }
        .frame(height: 26)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Step \(lesson.number) of \(AmbientTourLesson.allCases.count)")
    }
}

/// One short segment per lesson: ember when done, bright for the current one, faint for the rest.
struct AmbientTourProgressSegments: View {
    var completedCount: Int
    var currentIndex: Int?

    var body: some View {
        HStack(spacing: 3) {
            ForEach(AmbientTourLesson.allCases, id: \.self) { lesson in
                Capsule(style: .continuous)
                    .fill(fill(for: lesson.rawValue))
                    .frame(width: 14, height: 3)
            }
        }
        .accessibilityHidden(true)
    }

    private func fill(for index: Int) -> Color {
        if index < completedCount { return AmbientDesign.Palette.ember }
        if index == currentIndex { return Color.white.opacity(0.62) }
        return Color.white.opacity(0.14)
    }
}

/// What to say, shown as words to speak, with the real keycaps lighting up while they are held.
struct AmbientTourPhraseBlock: View {
    var shortcut: AmbientPushToTalkShortcut
    var isShortcutHeld: Bool
    var leadIn: String
    var phrase: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 4) {
                ForEach(shortcut.keycapSymbolNames, id: \.self) { symbolName in
                    AmbientKeycap(systemImageName: symbolName, size: 18, isPressed: isShortcutHeld)
                }
                Text(leadIn)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(AmbientDesign.Palette.onSmokeTertiary)
                    .padding(.leading, 4)
            }
            .animation(.easeOut(duration: 0.1), value: isShortcutHeld)
            Text("\u{201C}\(phrase)\u{201D}")
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(AmbientDesign.Palette.onSmokePrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: AmbientDesign.Metrics.nestedCornerRadius, style: .continuous).fill(Color.white.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: AmbientDesign.Metrics.nestedCornerRadius, style: .continuous).strokeBorder(AmbientDesign.Palette.onSmokeHairline, lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Hold \(shortcut.spokenName) and say: \(phrase)")
    }
}

/// A miniature screen with the bar on its real edge, so the lesson shows where the bar is now.
struct AmbientTourEdgeDiagram: View {
    var dockEdge: FlowBarDockEdge

    var body: some View {
        HStack(spacing: 12) {
            AmbientEdgePicker(selectedEdge: .constant(dockEdge), isCompact: true)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            Text("Drag the bar itself. Let go and it settles on the nearest edge.")
                .font(.system(size: 11.5))
                .lineSpacing(1.5)
                .foregroundStyle(AmbientDesign.Palette.onSmokeSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: AmbientDesign.Metrics.nestedCornerRadius, style: .continuous).fill(Color.white.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: AmbientDesign.Metrics.nestedCornerRadius, style: .continuous).strokeBorder(AmbientDesign.Palette.onSmokeHairline, lineWidth: 1))
    }
}

// MARK: - Status line

/// The live line: an indicator for the kind of moment, the words, and at most one control beside them.
struct AmbientTourStatusRow<TrailingControl: View>: View {
    var status: AmbientTourStatus
    @ViewBuilder var trailingControl: TrailingControl

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            AmbientTourStatusIndicator(tone: status.tone)
                .frame(width: 16, height: 16)
            Text(status.text)
                .font(.system(size: 12, weight: status.tone == .waiting ? .regular : .medium))
                .lineSpacing(1.5)
                .foregroundStyle(status.tone == .waiting ? AmbientDesign.Palette.onSmokeSecondary : AmbientDesign.Palette.onSmokePrimary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .id(status.text)
                .transition(.opacity)
                .accessibilityAddTraits(.updatesFrequently)
            trailingControl
        }
        .frame(minHeight: 26)
        .padding(.top, 12)
        .overlay(alignment: .top) {
            Rectangle().fill(AmbientDesign.Palette.onSmokeHairline).frame(height: 1)
        }
    }
}

struct AmbientTourStatusIndicator: View {
    var tone: AmbientTourStatus.Tone

    var body: some View {
        switch tone {
        case .waiting:
            Circle()
                .strokeBorder(AmbientDesign.Palette.onSmokeTertiary, lineWidth: 1.25)
                .frame(width: 8, height: 8)
        case .listening:
            AmbientEmberIndicator(activity: .thinking, diameter: 12)
        case .working:
            AmbientEmberIndicator(activity: .working, diameter: 11)
        case .nudge:
            Image(systemName: "arrow.turn.down.right")
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(AmbientDesign.Palette.onSmokeSecondary)
        case .problem:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AmbientDesign.Palette.alert)
        case .done:
            AmbientTourDoneMark()
        }
    }
}

/// The small ember confirmation when a lesson is done: the check settles in while a ring of light spreads from it
/// and fades. Reduce Motion keeps the check and drops the movement.
struct AmbientTourDoneMark: View {
    @State private var hasSettled = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isAmbientSnapshotRendering) private var isSnapshotRendering

    var body: some View {
        let isStill = reduceMotion || isSnapshotRendering
        ZStack {
            if !isStill {
                Circle()
                    .stroke(AmbientDesign.Palette.ember, lineWidth: 1.5)
                    .frame(width: 15, height: 15)
                    .scaleEffect(hasSettled ? 2.1 : 1)
                    .opacity(hasSettled ? 0 : 0.7)
            }
            Circle()
                .fill(AmbientDesign.Palette.ember)
                .frame(width: 15, height: 15)
                .shadow(color: AmbientDesign.Palette.ember.opacity(0.6), radius: 4)
            Image(systemName: "checkmark")
                .font(.system(size: 8, weight: .heavy))
                .foregroundStyle(AmbientDesign.Palette.emberInk)
        }
        .scaleEffect(isStill || hasSettled ? 1 : 0.55)
        .opacity(isStill || hasSettled ? 1 : 0)
        .onAppear {
            guard !isStill else { return }
            withAnimation(.spring(response: 0.34, dampingFraction: 1.0)) { hasSettled = true }
        }
        .accessibilityLabel("Done")
    }
}

// MARK: - Finish

/// The last card doubles as a cheat sheet, so the person leaves with the short version in front of them.
struct AmbientTourFinishContent: View {
    var model: AmbientTourModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                AmbientTourProgressSegments(completedCount: AmbientTourLesson.allCases.count, currentIndex: nil)
                Text("Done")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(AmbientDesign.Palette.onSmokeTertiary)
                Spacer(minLength: 0)
            }
            .frame(height: 26)
            .padding(.bottom, 12)
            Text("You're set")
                .font(.system(size: 15, weight: .semibold))
                .tracking(-0.2)
                .foregroundStyle(AmbientDesign.Palette.onSmokePrimary)
                .padding(.bottom, 4)
            Text("Here is the short version, for when you need it.")
                .font(.system(size: 12.5))
                .foregroundStyle(AmbientDesign.Palette.onSmokeSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 12)

            VStack(alignment: .leading, spacing: 0) {
                cheatSheetRow {
                    HStack(spacing: 3) {
                        ForEach(model.shortcut.keycapSymbolNames, id: \.self) { symbolName in
                            AmbientKeycap(systemImageName: symbolName, size: 18)
                        }
                    }
                } text: { "Hold to talk, let go to send." }
                cheatSheetDivider
                cheatSheetRow {
                    // The resting bar itself, so "the bar" has a picture.
                    Capsule(style: .continuous)
                        .fill(Color.white.opacity(0.22))
                        .overlay(Capsule(style: .continuous).strokeBorder(Color.white.opacity(0.32), lineWidth: 0.75))
                        .frame(width: 22, height: 6)
                } text: { "Click the bar to type instead." }
                cheatSheetDivider
                cheatSheetRow { cheatSheetSymbol("waveform") } text: { "Settings and Replay the tour are in the menu bar." }
            }
            .background(RoundedRectangle(cornerRadius: AmbientDesign.Metrics.nestedCornerRadius, style: .continuous).fill(Color.white.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: AmbientDesign.Metrics.nestedCornerRadius, style: .continuous).strokeBorder(AmbientDesign.Palette.onSmokeHairline, lineWidth: 1))

            Text("Things to try")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(AmbientDesign.Palette.onSmokeTertiary)
                .padding(.top, 14)
                .padding(.bottom, 6)
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Self.exampleRequests, id: \.self) { exampleRequest in
                    Text("\u{201C}\(exampleRequest)\u{201D}")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(AmbientDesign.Palette.onSmokePrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack {
                Spacer(minLength: 0)
                AmbientCapsuleButton(title: "Done", prominence: .primary, isCompact: true) { model.endTour() }
                    .keyboardShortcut(.defaultAction)
            }
            .frame(height: 26)
            .padding(.top, 16)
        }
        .frame(width: AmbientTourMetrics.contentWidth, alignment: .leading)
    }

    static let exampleRequests = [
        "What's on my calendar tomorrow?",
        "Draw how to turn on Do Not Disturb.",
        "Start an agent to compare three standing desks.",
    ]

    private func cheatSheetRow<Leading: View>(@ViewBuilder leading: () -> Leading, text: () -> String) -> some View {
        HStack(spacing: 10) {
            leading()
                .frame(width: 44, alignment: .leading)
            Text(text())
                .font(.system(size: 12.5))
                .foregroundStyle(AmbientDesign.Palette.onSmokePrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 38)
    }

    private var cheatSheetDivider: some View {
        Rectangle().fill(AmbientDesign.Palette.onSmokeHairline).frame(height: 1).padding(.leading, 66)
    }

    private func cheatSheetSymbol(_ symbolName: String) -> some View {
        Image(systemName: symbolName)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(AmbientDesign.Palette.onSmokeSecondary)
            .frame(width: 22, alignment: .center)
    }
}
