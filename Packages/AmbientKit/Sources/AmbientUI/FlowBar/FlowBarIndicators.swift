import SwiftUI

// MARK: - Waveform

/// The live voice waveform. Each bar follows the real microphone level through its own envelope, so loud syllables
/// lift the centre first and silence settles the bars to dots. Nothing here loops on its own: with no sound the bars
/// rest.
struct FlowBarWaveformView: View {
    enum Mode { case listening, transcribing }

    var model: FlowBarModel
    var mode: Mode
    var isVertical: Bool

    @State private var dynamics = FlowBarWaveformDynamics(barCount: 13)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isAmbientSnapshotRendering) private var isSnapshotRendering

    static let barThickness: CGFloat = 2.5
    static let barSpacing: CGFloat = 2.5
    static let barMaximumLength: CGFloat = 20

    static var totalLength: CGFloat {
        CGFloat(13) * barThickness + CGFloat(12) * barSpacing
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: isSnapshotRendering)) { timeline in
            Canvas { context, canvasSize in
                let barLengths = dynamics.advance(
                    to: timeline.date,
                    inputLevel: model.audioLevel,
                    isTranscribing: mode == .transcribing,
                    reduceMotion: reduceMotion,
                    settlesInstantly: isSnapshotRendering
                )
                drawGlow(in: &context, canvasSize: canvasSize)
                drawBars(barLengths, in: &context, canvasSize: canvasSize)
            }
        }
        .frame(width: isVertical ? 28 : Self.totalLength + 16, height: isVertical ? Self.totalLength + 16 : 28)
        .accessibilityLabel(mode == .listening ? "Listening" : "Transcribing")
    }

    /// A warm glow behind the bars that brightens with the voice: the ember responding to being spoken to.
    private func drawGlow(in context: inout GraphicsContext, canvasSize: CGSize) {
        // Kept faint: ember at high alpha over smoke turns muddy brown. The glow is a hint of warmth, not a blob.
        let glowStrength = mode == .transcribing ? 0.06 : 0.05 + 0.22 * dynamics.smoothedLevel
        let centre = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
        let glowRadius = min(canvasSize.width, canvasSize.height) * 0.9
        let glowRect = CGRect(x: centre.x - glowRadius * 1.6, y: centre.y - glowRadius, width: glowRadius * 3.2, height: glowRadius * 2)
        context.fill(
            Ellipse().path(in: glowRect),
            with: .radialGradient(
                Gradient(colors: [AmbientDesign.Palette.ember.opacity(glowStrength), AmbientDesign.Palette.ember.opacity(0)]),
                center: centre,
                startRadius: 0,
                endRadius: glowRadius
            )
        )
    }

    private func drawBars(_ normalizedLengths: [Double], in context: inout GraphicsContext, canvasSize: CGSize) {
        let barCount = normalizedLengths.count
        let stackLength = CGFloat(barCount) * Self.barThickness + CGFloat(barCount - 1) * Self.barSpacing
        let stackStart = ((isVertical ? canvasSize.height : canvasSize.width) - stackLength) / 2
        for (barIndex, normalizedLength) in normalizedLengths.enumerated() {
            let barLength = max(Self.barThickness, CGFloat(normalizedLength) * Self.barMaximumLength)
            let positionAlongStack = stackStart + CGFloat(barIndex) * (Self.barThickness + Self.barSpacing)
            let barRect: CGRect
            if isVertical {
                barRect = CGRect(x: (canvasSize.width - barLength) / 2, y: positionAlongStack, width: barLength, height: Self.barThickness)
            } else {
                barRect = CGRect(x: positionAlongStack, y: (canvasSize.height - barLength) / 2, width: Self.barThickness, height: barLength)
            }
            // Louder bars run warmer, so the centre of a loud word glows ember.
            let warmth = min(1, normalizedLength * 1.3)
            let barColor = Color(
                red: 1.0,
                green: 0.97 - 0.27 * warmth,
                blue: 0.93 - 0.55 * warmth
            )
            context.fill(Capsule(style: .continuous).path(in: barRect), with: .color(barColor.opacity(0.94)))
        }
    }
}

/// The per-bar physics of the waveform: attack quickly, release slowly, like a VU meter.
final class FlowBarWaveformDynamics {
    private(set) var barLengths: [Double]
    private(set) var smoothedLevel: Double = 0
    private var lastUpdateDate: Date?
    private let centreEmphasis: [Double]
    private let wobbleFrequencies: [Double]
    private let wobblePhases: [Double]

    /// Bars at rest show as dots of this normalized length.
    static let restingLength = 0.12

    init(barCount: Int) {
        barLengths = Array(repeating: Self.restingLength, count: barCount)
        let centreIndex = Double(barCount - 1) / 2
        // The centre bars carry the voice; the outer bars are quieter echoes of it.
        centreEmphasis = (0..<barCount).map { barIndex in
            let distanceFromCentre = abs(Double(barIndex) - centreIndex) / max(centreIndex, 1)
            return 1 - 0.62 * distanceFromCentre * distanceFromCentre
        }
        // Fixed, uneven frequencies so neighbouring bars never move in lockstep.
        wobbleFrequencies = (0..<barCount).map { barIndex in 5.3 + Double((barIndex * 7) % 5) * 1.17 }
        wobblePhases = (0..<barCount).map { barIndex in Double(barIndex) * 1.91 }
    }

    func advance(to date: Date, inputLevel: Double, isTranscribing: Bool, reduceMotion: Bool, settlesInstantly: Bool) -> [Double] {
        let elapsedSeconds = lastUpdateDate.map { min(date.timeIntervalSince($0), 0.1) } ?? (1.0 / 60.0)
        lastUpdateDate = date
        let time = date.timeIntervalSinceReferenceDate

        // Lift quiet speech so normal talking fills the bars without shouting.
        let perceivedLevel = pow(min(max(inputLevel, 0), 1), 0.6)
        smoothedLevel = settlesInstantly ? perceivedLevel : follow(current: smoothedLevel, target: perceivedLevel, elapsedSeconds: elapsedSeconds, attackSeconds: 0.04, releaseSeconds: 0.16)

        for barIndex in barLengths.indices {
            let targetLength: Double
            if isTranscribing {
                // The voice has stopped: a single bright swell sweeps across the dots while the words are read back,
                // so "working on what you said" looks different from "listening to silence".
                let sweepPeriod = 0.9
                let sweepPosition = reduceMotion ? 0.5 : (time / sweepPeriod).truncatingRemainder(dividingBy: 1) * 1.4 - 0.2
                let barPosition = Double(barIndex) / Double(max(barLengths.count - 1, 1))
                let distanceFromSweep = (barPosition - sweepPosition) / 0.14
                let swell = exp(-distanceFromSweep * distanceFromSweep)
                targetLength = Self.restingLength + 0.34 * swell
            } else {
                let variation = reduceMotion ? 1 : 0.62 + 0.38 * (0.5 + 0.5 * sin(time * wobbleFrequencies[barIndex] + wobblePhases[barIndex]))
                let drive = min(1, smoothedLevel * centreEmphasis[barIndex] * variation * 1.35)
                targetLength = Self.restingLength + (1 - Self.restingLength) * drive
            }
            barLengths[barIndex] = settlesInstantly
                ? targetLength
                : follow(current: barLengths[barIndex], target: targetLength, elapsedSeconds: elapsedSeconds, attackSeconds: 0.05, releaseSeconds: 0.13)
        }
        return barLengths
    }

    /// Exponential approach toward `target`, faster when rising than when falling.
    private func follow(current: Double, target: Double, elapsedSeconds: Double, attackSeconds: Double, releaseSeconds: Double) -> Double {
        let timeConstant = target > current ? attackSeconds : releaseSeconds
        let blend = 1 - exp(-elapsedSeconds / timeConstant)
        return current + (target - current) * blend
    }
}

// MARK: - Ember

/// Ambient's presence: a small ember. It breathes while thinking and gains a slow orbit while working with tools.
struct AmbientEmberIndicator: View {
    enum Activity { case thinking, working, idle }
    var activity: Activity
    var diameter: CGFloat = 16

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isAmbientSnapshotRendering) private var isSnapshotRendering

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: reduceMotion || isSnapshotRendering || activity == .idle)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            let isAnimating = !(reduceMotion || isSnapshotRendering)
            // One breath every 1.6 seconds: calm, but well away from the slow 0.2 Hz range that can unsettle people.
            let breath = isAnimating ? 0.5 + 0.5 * sin(time * (2 * .pi / 1.6)) : 0.75
            let orbitAngle = isAnimating ? Angle.degrees((time * 300).truncatingRemainder(dividingBy: 360)) : .degrees(-90)
            ZStack {
                Circle()
                    .fill(AmbientDesign.Palette.ember.opacity(0.20 + 0.18 * breath))
                    .frame(width: diameter, height: diameter)
                    .blur(radius: 3)
                if activity == .working {
                    Circle()
                        .trim(from: 0, to: 0.3)
                        .stroke(AmbientDesign.Palette.ember, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                        .frame(width: diameter, height: diameter)
                        .rotationEffect(orbitAngle)
                    Circle()
                        .stroke(AmbientDesign.Palette.ember.opacity(0.18), lineWidth: 1.6)
                        .frame(width: diameter, height: diameter)
                }
                Circle()
                    .fill(RadialGradient(colors: [AmbientDesign.Palette.emberCore, AmbientDesign.Palette.ember], center: .center, startRadius: 0, endRadius: diameter * 0.24))
                    .frame(width: diameter * 0.44, height: diameter * 0.44)
                    .scaleEffect(activity == .thinking ? 0.86 + 0.14 * breath : 1)
                    .shadow(color: AmbientDesign.Palette.ember.opacity(0.85), radius: 3)
            }
        }
        .frame(width: diameter + 4, height: diameter + 4)
        .accessibilityHidden(true)
    }
}

/// A small spinning arc for a running background task, drawn in the ember.
struct AmbientRunningArc: View {
    var diameter: CGFloat = 12
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isAmbientSnapshotRendering) private var isSnapshotRendering

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: reduceMotion || isSnapshotRendering)) { timeline in
            let isAnimating = !(reduceMotion || isSnapshotRendering)
            let angle = isAnimating ? (timeline.date.timeIntervalSinceReferenceDate * 360).truncatingRemainder(dividingBy: 360) : 0
            ZStack {
                Circle().stroke(AmbientDesign.Palette.ember.opacity(0.22), lineWidth: 1.5)
                Circle()
                    .trim(from: 0, to: 0.28)
                    .stroke(AmbientDesign.Palette.ember, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .rotationEffect(.degrees(angle - 90))
            }
            .frame(width: diameter, height: diameter)
        }
        .accessibilityLabel("Running")
    }
}
