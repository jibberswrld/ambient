import SwiftUI

/// Whether the main window can currently be seen. The presence stops drawing when it cannot.
private struct WindowIsVisibleKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var windowIsVisible: Bool {
        get { self[WindowIsVisibleKey.self] }
        set { self[WindowIsVisibleKey.self] = newValue }
    }
}

/// The presence: a molten ember sphere inside a ring of fine threads. It is the thing you talk to, so it has to read
/// as something alive: at rest the sphere's interior drifts slowly and the ring is a still circle; listening, the
/// threads ripple with the real microphone level; thinking and working, a comet of light orbits the ring (two while
/// a tool runs); speaking, the threads move with the real playback level in a calmer, symmetric wave.
///
/// Drawn with Canvas in a TimelineView. It renders at 24 fps at rest, 60 fps when active, and not at all while the
/// window is hidden or a still capture is being taken.
struct PresenceView: View {
    var phase: PresencePhase
    var diameter: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isAmbientSnapshotRendering) private var isCaptureRendering
    @Environment(\.windowIsVisible) private var windowIsVisible
    /// A reference held across frames: the smoothed values the drawing eases toward. Mutated while drawing, which
    /// is why it is a plain class and not observable state.
    @State private var envelope = PresenceEnvelope()

    var body: some View {
        let targets = PresenceTargets(phase: phase, reduceMotion: reduceMotion)
        TimelineView(.animation(minimumInterval: phase.isBusy ? 1.0 / 60 : 1.0 / 24, paused: isPaused)) { timeline in
            Canvas { graphics, canvasSize in
                let seconds = isCaptureRendering ? 12.4 : timeline.date.timeIntervalSinceReferenceDate
                envelope.advance(toward: targets, atSeconds: seconds, settlesInstantly: isCaptureRendering)
                PresenceDrawing.draw(in: &graphics, canvasSize: canvasSize, envelope: envelope,
                                     seconds: seconds, breathes: !reduceMotion)
            }
        }
        .frame(width: diameter, height: diameter)
        .accessibilityElement()
        .accessibilityLabel(Self.accessibilityDescription(for: phase))
    }

    private var isPaused: Bool {
        if isCaptureRendering || !windowIsVisible { return true }
        // With Reduce Motion, a resting presence is a still image.
        if reduceMotion, !phase.isBusy { return true }
        return false
    }

    static func accessibilityDescription(for phase: PresencePhase) -> String {
        switch phase {
        case .signedOut: return "Ambient is waiting for sign-in"
        case .idle: return "Ambient is ready"
        case .listening: return "Ambient is listening"
        case .transcribing: return "Ambient is transcribing"
        case .thinking: return "Ambient is thinking"
        case .working(let activityLabel): return "Ambient is working: \(activityLabel)"
        case .responding: return "Ambient is answering"
        case .speaking: return "Ambient is speaking"
        }
    }
}

/// What each phase asks of the drawing. Every value is 0…1 unless it says otherwise.
struct PresenceTargets: Equatable {
    /// How far the ticks reach out from the dial.
    var tickReach: Double
    /// How much of the ember the ticks take on.
    var tickHeat: Double
    /// Brightness and size of the core.
    var coreHeat: Double
    /// Strength of the light sweeping the dial.
    var sweepStrength: Double
    /// Sweep speed in radians per second.
    var sweepSpeed: Double
    /// 0: one sweep. 1: two opposite sweeps, meaning a tool is running.
    var secondSweep: Double
    /// 0: listening's irregular pattern. 1: speaking's symmetric wave.
    var speakingShape: Double
    /// 0: normal colour. 1: drained, while signed out.
    var drain: Double

    init(phase: PresencePhase, reduceMotion: Bool) {
        let sweepSpeedScale = reduceMotion ? 0.0 : 1.0
        switch phase {
        case .signedOut:
            self.init(tickReach: 0, tickHeat: 0, coreHeat: 0.25, sweepStrength: 0.45, sweepSpeed: 0.9 * sweepSpeedScale, secondSweep: 0, speakingShape: 0, drain: 1)
        case .idle:
            self.init(tickReach: 0.03, tickHeat: 0.06, coreHeat: 0.66, sweepStrength: 0, sweepSpeed: 0.4, secondSweep: 0, speakingShape: 0, drain: 0)
        case .listening(let level):
            self.init(tickReach: 0.12 + 0.88 * level, tickHeat: 0.55 + 0.45 * level, coreHeat: 0.78 + 0.22 * level, sweepStrength: 0, sweepSpeed: 0.4, secondSweep: 0, speakingShape: 0, drain: 0)
        case .transcribing:
            self.init(tickReach: 0.06, tickHeat: 0.3, coreHeat: 0.7, sweepStrength: 0.95, sweepSpeed: 7.5 * sweepSpeedScale, secondSweep: 0, speakingShape: 0, drain: 0)
        case .thinking:
            self.init(tickReach: 0.05, tickHeat: 0.18, coreHeat: 0.72, sweepStrength: 0.85, sweepSpeed: 2.8 * sweepSpeedScale, secondSweep: 0, speakingShape: 0, drain: 0)
        case .working:
            self.init(tickReach: 0.08, tickHeat: 0.24, coreHeat: 0.76, sweepStrength: 1, sweepSpeed: 4.4 * sweepSpeedScale, secondSweep: 1, speakingShape: 0, drain: 0)
        case .responding:
            self.init(tickReach: 0.05, tickHeat: 0.2, coreHeat: 0.82, sweepStrength: 0.4, sweepSpeed: 1.6 * sweepSpeedScale, secondSweep: 0, speakingShape: 1, drain: 0)
        case .speaking(let level):
            self.init(tickReach: 0.1 + 0.7 * level, tickHeat: 0.4 + 0.45 * level, coreHeat: 0.76 + 0.24 * level, sweepStrength: 0, sweepSpeed: 0.4, secondSweep: 0, speakingShape: 1, drain: 0)
        }
    }

    init(tickReach: Double, tickHeat: Double, coreHeat: Double, sweepStrength: Double, sweepSpeed: Double, secondSweep: Double, speakingShape: Double, drain: Double) {
        self.tickReach = tickReach
        self.tickHeat = tickHeat
        self.coreHeat = coreHeat
        self.sweepStrength = sweepStrength
        self.sweepSpeed = sweepSpeed
        self.secondSweep = secondSweep
        self.speakingShape = speakingShape
        self.drain = drain
    }
}

/// The values the drawing actually uses, eased toward the targets every frame. Easing is exponential (critically
/// damped), so a phase change mid-motion continues from where the dial is instead of jumping.
final class PresenceEnvelope {
    private(set) var current = PresenceTargets(tickReach: 0, tickHeat: 0, coreHeat: 0.5, sweepStrength: 0, sweepSpeed: 0, secondSweep: 0, speakingShape: 0, drain: 0)
    /// Where the sweep's head is, in radians. Integrated from the speed so speed changes never make it jump.
    private(set) var sweepAngle: Double = -.pi / 2
    /// How far the sphere's interior has flowed. Integrated, so it speeds up with heat without ever jumping.
    private(set) var plasmaPhase: Double = 0
    private var lastSeconds: Double?

    func advance(toward targets: PresenceTargets, atSeconds seconds: Double, settlesInstantly: Bool) {
        guard !settlesInstantly else {
            current = targets
            sweepAngle = -.pi / 2 + 2.2
            plasmaPhase = 3.7
            lastSeconds = seconds
            return
        }
        // A long gap (the window was hidden) settles at once rather than animating stale history.
        let elapsed = min(max(seconds - (lastSeconds ?? seconds), 0), 0.25)
        lastSeconds = seconds
        func ease(_ value: Double, toward target: Double, timeConstant: Double) -> Double {
            value + (target - value) * (1 - exp(-elapsed / timeConstant))
        }
        // Reach rises fast (a syllable lands now) and falls slower, like a level meter's ballistics.
        let reachTimeConstant = targets.tickReach > current.tickReach ? 0.05 : 0.16
        current.tickReach = ease(current.tickReach, toward: targets.tickReach, timeConstant: reachTimeConstant)
        current.tickHeat = ease(current.tickHeat, toward: targets.tickHeat, timeConstant: 0.14)
        current.coreHeat = ease(current.coreHeat, toward: targets.coreHeat, timeConstant: 0.12)
        current.sweepStrength = ease(current.sweepStrength, toward: targets.sweepStrength, timeConstant: 0.22)
        current.sweepSpeed = ease(current.sweepSpeed, toward: targets.sweepSpeed, timeConstant: 0.35)
        current.secondSweep = ease(current.secondSweep, toward: targets.secondSweep, timeConstant: 0.25)
        current.speakingShape = ease(current.speakingShape, toward: targets.speakingShape, timeConstant: 0.3)
        current.drain = ease(current.drain, toward: targets.drain, timeConstant: 0.3)
        sweepAngle = (sweepAngle + current.sweepSpeed * elapsed).truncatingRemainder(dividingBy: 2 * .pi)
        plasmaPhase += elapsed * (0.35 + 1.1 * current.coreHeat + 2.4 * current.tickReach + 0.9 * current.sweepStrength)
    }
}

enum PresenceDrawing {
    private typealias Colour = (red: Double, green: Double, blue: Double)

    static func draw(in graphics: inout GraphicsContext, canvasSize: CGSize, envelope: PresenceEnvelope, seconds: Double, breathes: Bool) {
        let values = envelope.current
        let radius = min(canvasSize.width, canvasSize.height) / 2
        let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
        let isSmall = radius < 30
        let breathing = breathes ? sin(seconds * 2 * .pi / 5.2) : 0
        let drained = values.drain
        let heat = values.coreHeat
        let reach = values.tickReach

        // While signed out everything cools toward grey.
        func tone(_ colour: Colour, grey: Double = 0.42) -> Color {
            Color(red: colour.red + (grey - colour.red) * drained, green: colour.green + (grey - colour.green) * drained, blue: colour.blue + (grey - colour.blue) * drained)
        }
        func circle(_ circleRadius: CGFloat, around point: CGPoint) -> Path {
            Path(ellipseIn: CGRect(x: point.x - circleRadius, y: point.y - circleRadius, width: circleRadius * 2, height: circleRadius * 2))
        }
        let ember: Colour = (1.0, 0.584, 0.290)
        let gold: Colour = (1.0, 0.86, 0.62)
        let deepRed: Colour = (0.93, 0.27, 0.10)

        // The halo: the only light that leaves the object, and only as much as the sphere is lit.
        let haloOpacity = (0.10 + 0.20 * heat + 0.10 * reach) * (1 - 0.8 * drained)
        graphics.fill(circle(radius, around: center), with: .radialGradient(
            Gradient(stops: [.init(color: tone(ember).opacity(haloOpacity), location: 0), .init(color: tone(ember).opacity(haloOpacity * 0.35), location: 0.55), .init(color: .clear, location: 1)]),
            center: center, startRadius: radius * 0.25, endRadius: radius))

        // The ring: a still guide circle, and threads that leave it as far as the voice pushes them.
        let ringRadius = radius * (isSmall ? 0.74 : 0.62)
        let ringLineWidth = max(1.0, radius * (isSmall ? 0.06 : 0.011))
        graphics.stroke(circle(ringRadius, around: center), with: .color(tone((1.0, 0.86, 0.74), grey: 0.7).opacity(0.16 + 0.10 * heat)), lineWidth: max(0.75, ringLineWidth * 0.6))

        let threadCount = isSmall ? 1 : 3
        let threadAmplitude = radius * (isSmall ? 0.22 : 0.30) * reach
        let ringWarmth = min(1, values.tickHeat) * (1 - drained)
        // At rest the ring is only the guide circle; threads appear once there is a voice to move them.
        if reach > 0.06 {
            graphics.drawLayer { layer in
                layer.blendMode = .plusLighter
                for threadIndex in 0..<threadCount {
                    let threadOffset = Double(threadIndex) * 1.9
                    var threadPath = Path()
                    let sampleCount = isSmall ? 64 : 160
                    for sampleIndex in 0...sampleCount {
                        let angle = Double(sampleIndex) / Double(sampleCount) * 2 * .pi
                        // Listening is irregular, like a voice; speaking is a calm wave with three crests.
                        let listeningWave = 0.5 * sin(angle * 3 + seconds * 2.3 + threadOffset)
                            + 0.3 * sin(angle * 5 - seconds * 3.7 + threadOffset * 2)
                            + 0.2 * sin(angle * 9 + seconds * 6.1 - threadOffset)
                        let speakingWave = sin(angle * 3 + seconds * 3.4 + threadOffset * 0.5)
                        let wave = listeningWave * (1 - values.speakingShape) + speakingWave * values.speakingShape
                        let threadRadius = ringRadius + threadAmplitude * (0.42 + 0.58 * wave) * (1 - 0.22 * Double(threadIndex))
                        let point = CGPoint(x: center.x + cos(angle) * threadRadius, y: center.y + sin(angle) * threadRadius)
                        if sampleIndex == 0 { threadPath.move(to: point) } else { threadPath.addLine(to: point) }
                    }
                    threadPath.closeSubpath()
                    let threadColour = Color(red: 1, green: 1 - (1 - ember.green) * ringWarmth, blue: 1 - (1 - ember.blue) * ringWarmth)
                    let threadOpacity = (0.30 + 0.60 * values.tickHeat) * (threadIndex == 0 ? 1 : 0.45)
                    layer.stroke(threadPath, with: .color(threadColour.opacity(threadOpacity)),
                                 style: StrokeStyle(lineWidth: ringLineWidth * (threadIndex == 0 ? 1.5 : 1), lineJoin: .round))
                }
            }
        }

        // The comet: thinking is one light orbiting the ring, working is two opposite ones.
        if values.sweepStrength > 0.01 {
            let cometLineWidth = max(1.6, radius * (isSmall ? 0.09 : 0.026))
            graphics.drawLayer { layer in
                layer.blendMode = .plusLighter
                for cometIndex in 0..<2 {
                    let cometStrength = values.sweepStrength * (cometIndex == 0 ? 1 : values.secondSweep)
                    guard cometStrength > 0.01 else { continue }
                    let head = envelope.sweepAngle + Double(cometIndex) * .pi
                    let segmentCount = 28
                    let tailLength = 1.9
                    for segmentIndex in 0..<segmentCount {
                        let nearFraction = Double(segmentIndex) / Double(segmentCount)
                        let farFraction = Double(segmentIndex + 1) / Double(segmentCount)
                        var segment = Path()
                        segment.addArc(center: center, radius: ringRadius, startAngle: .radians(head - nearFraction * tailLength),
                                       endAngle: .radians(head - farFraction * tailLength), clockwise: true)
                        let fade = pow(1 - nearFraction, 2.2)
                        layer.stroke(segment, with: .color(tone(nearFraction < 0.15 ? gold : ember).opacity(cometStrength * fade)),
                                     style: StrokeStyle(lineWidth: cometLineWidth * (0.35 + 0.65 * fade), lineCap: .round))
                    }
                    let headPoint = CGPoint(x: center.x + cos(head) * ringRadius, y: center.y + sin(head) * ringRadius)
                    layer.fill(circle(cometLineWidth * 2.6, around: headPoint), with: .radialGradient(
                        Gradient(colors: [tone(gold).opacity(0.75 * cometStrength), .clear]), center: headPoint, startRadius: 0, endRadius: cometLineWidth * 2.6))
                }
            }
        }

        // The sphere: a dark glass body with molten light moving inside it.
        let sphereRadius = radius * (isSmall ? 0.52 : 0.44) * (0.94 + 0.05 * heat + 0.02 * breathing * (1 - values.sweepStrength) + 0.05 * reach)
        let spherePath = circle(sphereRadius, around: center)
        graphics.fill(spherePath, with: .radialGradient(
            Gradient(colors: [tone((0.30, 0.12, 0.05), grey: 0.2), tone((0.08, 0.045, 0.035), grey: 0.08)]),
            center: CGPoint(x: center.x - sphereRadius * 0.2, y: center.y - sphereRadius * 0.25), startRadius: 0, endRadius: sphereRadius * 1.1))

        let flow = envelope.plasmaPhase
        let plasmaBrightness = (0.50 + 0.50 * heat) * (1 - 0.55 * drained)
        // Each blob: colour, size, orbit size, and how fast it moves on each axis. The uneven speeds keep the
        // pattern from visibly repeating.
        let blobs: [(colour: Colour, size: Double, orbit: Double, horizontalSpeed: Double, verticalSpeed: Double, offset: Double)] = [
            (deepRed, 0.95, 0.42, 0.61, 0.47, 0.0),
            (ember, 0.80, 0.48, -0.43, 0.71, 2.1),
            (ember, 0.62, 0.40, 0.83, -0.37, 4.0),
            (gold, 0.50, 0.30, -0.71, -0.59, 5.3)
        ]
        graphics.drawLayer { layer in
            layer.clip(to: spherePath)
            layer.blendMode = .plusLighter
            layer.addFilter(.blur(radius: sphereRadius * 0.16))
            for blob in blobs {
                let blobCenter = CGPoint(x: center.x + cos(flow * blob.horizontalSpeed + blob.offset) * sphereRadius * blob.orbit,
                                         y: center.y + sin(flow * blob.verticalSpeed + blob.offset * 1.7) * sphereRadius * blob.orbit)
                let blobRadius = sphereRadius * blob.size * 0.62
                layer.fill(circle(blobRadius, around: blobCenter), with: .radialGradient(
                    Gradient(colors: [tone(blob.colour).opacity(0.85 * plasmaBrightness), tone(blob.colour).opacity(0)]),
                    center: blobCenter, startRadius: 0, endRadius: blobRadius))
            }
            // The hot heart swells with the voice.
            let heartRadius = sphereRadius * (0.50 + 0.30 * reach + 0.10 * heat)
            layer.fill(circle(heartRadius, around: center), with: .radialGradient(
                Gradient(colors: [tone(gold).opacity((0.45 + 0.50 * heat) * (1 - 0.6 * drained)), .clear]),
                center: CGPoint(x: center.x + sphereRadius * 0.08, y: center.y + sphereRadius * 0.10), startRadius: 0, endRadius: heartRadius))
        }

        // Glass: the edge falls into shadow, the rim catches light from above, and a soft highlight sits top-left.
        graphics.fill(spherePath, with: .radialGradient(
            Gradient(stops: [.init(color: .clear, location: 0.68), .init(color: .black.opacity(0.42), location: 1)]),
            center: center, startRadius: 0, endRadius: sphereRadius))
        graphics.stroke(circle(sphereRadius - max(0.4, radius * 0.004), around: center), with: .linearGradient(
            Gradient(colors: [.white.opacity(0.55 - 0.2 * drained), tone(ember).opacity(0.18), tone(ember).opacity(0.38)]),
            startPoint: CGPoint(x: center.x - sphereRadius * 0.4, y: center.y - sphereRadius),
            endPoint: CGPoint(x: center.x + sphereRadius * 0.4, y: center.y + sphereRadius)),
            lineWidth: max(0.8, radius * 0.010))
        if !isSmall {
            let highlightCenter = CGPoint(x: center.x - sphereRadius * 0.34, y: center.y - sphereRadius * 0.46)
            graphics.drawLayer { layer in
                layer.addFilter(.blur(radius: sphereRadius * 0.07))
                layer.fill(Path(ellipseIn: CGRect(x: highlightCenter.x - sphereRadius * 0.24, y: highlightCenter.y - sphereRadius * 0.13,
                                                  width: sphereRadius * 0.48, height: sphereRadius * 0.26))
                    .applying(CGAffineTransform(translationX: -highlightCenter.x, y: -highlightCenter.y))
                    .applying(CGAffineTransform(rotationAngle: -0.6))
                    .applying(CGAffineTransform(translationX: highlightCenter.x, y: highlightCenter.y)),
                           with: .color(.white.opacity(0.22 + 0.12 * heat)))
            }
        }
    }
}

enum PresencePhase: Equatable {
    case signedOut
    case idle
    /// `level` is 0…1, already shaped for display.
    case listening(level: Double)
    case transcribing
    case thinking
    case working(activityLabel: String)
    case responding
    /// `level` is 0…1 from the audio player's meter.
    case speaking(level: Double)

    var isBusy: Bool {
        switch self {
        case .signedOut, .idle: return false
        default: return true
        }
    }
}
