import SwiftUI

/// One thing Ambient draws on the screen to show the person where something is or what to do next.
/// Coordinates are in the overlay's own points, origin at the top-left.
public struct AmbientScreenAnnotation: Sendable, Equatable {
    public enum Shape: Sendable, Equatable {
        /// An arrow whose head lands on `tip`.
        case arrow(tail: CGPoint, tip: CGPoint)
        case circle(center: CGPoint, radius: CGFloat)
        case box(CGRect)
        case underline(from: CGPoint, to: CGPoint)
        /// Text alone, centred on the point.
        case label(at: CGPoint)
    }

    public var shape: Shape
    /// A short caption beside the shape.
    public var text: String?

    public init(shape: Shape, text: String? = nil) {
        self.shape = shape
        self.text = text
    }
}

/// Ambient drawing on the screen: each annotation is stroked in ember, one after another, as if drawn by hand,
/// and its caption rises in when the stroke lands. Several captions are numbered so they read as steps.
///
/// Fill a click-through overlay window that covers one display:
///
///     AmbientAnnotationOverlayView(annotations: annotations)
///         .frame(width: displayFrame.width, height: displayFrame.height)
public struct AmbientAnnotationOverlayView: View {
    var annotations: [AmbientScreenAnnotation]

    @State private var isDrawn = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isAmbientSnapshotRendering) private var isSnapshotRendering

    /// Seconds between one annotation starting and the next.
    static let stagger = 0.42
    static let strokeDuration = 0.46

    public init(annotations: [AmbientScreenAnnotation]) {
        self.annotations = annotations
    }

    public var body: some View {
        GeometryReader { geometry in
            let isStatic = reduceMotion || isSnapshotRendering
            let numbersSteps = annotations.filter { $0.text?.isEmpty == false }.count > 1
            ZStack {
                ForEach(Array(annotations.enumerated()), id: \.offset) { index, annotation in
                    let delay = isStatic ? 0 : Double(index) * Self.stagger
                    let progress: CGFloat = isDrawn || isSnapshotRendering ? 1 : 0
                    let path = AmbientAnnotationGeometry.path(for: annotation.shape)
                    // A dark under-stroke keeps the ember line readable on white pages and bright photos.
                    path
                        .trim(from: 0, to: progress)
                        .stroke(Color.black.opacity(0.42), style: StrokeStyle(lineWidth: 6.5, lineCap: .round, lineJoin: .round))
                        .animation(strokeAnimation(delay: delay, isStatic: isStatic), value: isDrawn)
                    path
                        .trim(from: 0, to: progress)
                        .stroke(AmbientDesign.Palette.ember, style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round))
                        .shadow(color: AmbientDesign.Palette.ember.opacity(0.55), radius: 5)
                        .animation(strokeAnimation(delay: delay, isStatic: isStatic), value: isDrawn)
                    if let text = annotation.text, !text.isEmpty {
                        let stepNumber = numbersSteps ? annotations[...index].filter { $0.text?.isEmpty == false }.count : nil
                        AmbientAnnotationCaption(text: text, stepNumber: stepNumber)
                            .fixedSize()
                            .position(AmbientAnnotationGeometry.captionCenter(for: annotation.shape, text: text, hasStepNumber: stepNumber != nil, in: geometry.size))
                            .opacity(progress)
                            .offset(y: isDrawn || isStatic ? 0 : 5)
                            .animation(isStatic ? .easeOut(duration: 0.18) : .spring(response: 0.3, dampingFraction: 0.9).delay(delay + Self.strokeDuration * 0.7), value: isDrawn)
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(annotations.compactMap(\.text).joined(separator: ". "))
        .onAppear { isDrawn = true }
    }

    private func strokeAnimation(delay: Double, isStatic: Bool) -> Animation {
        isStatic ? .easeOut(duration: 0.18) : .easeInOut(duration: Self.strokeDuration).delay(delay)
    }
}

enum AmbientAnnotationGeometry {
    static func path(for shape: AmbientScreenAnnotation.Shape) -> Path {
        var path = Path()
        switch shape {
        case .arrow(let tail, let tip):
            let dx = tip.x - tail.x, dy = tip.y - tail.y
            let length = max(1, hypot(dx, dy))
            // A slight bow, so it reads as drawn rather than ruled.
            let bow = min(26, length * 0.14)
            let control = CGPoint(x: (tail.x + tip.x) / 2 - dy / length * bow, y: (tail.y + tip.y) / 2 + dx / length * bow)
            path.move(to: tail)
            path.addQuadCurve(to: tip, control: control)
            // The head follows the curve's direction where it lands.
            let heading = atan2(tip.y - control.y, tip.x - control.x)
            let headLength = min(17, max(9, length * 0.3))
            for side in [-1.0, 1.0] {
                let angle = heading + .pi + side * 0.46
                path.move(to: tip)
                path.addLine(to: CGPoint(x: tip.x + cos(angle) * headLength, y: tip.y + sin(angle) * headLength))
            }
        case .circle(let center, let radius):
            // Starts at the top-left and overshoots slightly, the way a hand closes a circle.
            path.addArc(center: center, radius: radius, startAngle: .degrees(-130), endAngle: .degrees(246), clockwise: false)
        case .box(let rect):
            path.addRoundedRect(in: rect, cornerSize: CGSize(width: 7, height: 7))
        case .underline(let from, let to):
            path.move(to: from)
            path.addLine(to: to)
        case .label:
            break
        }
        return path
    }

    /// Where the caption sits: just outside its shape, flipped and clamped so it stays on the display.
    static func captionCenter(for shape: AmbientScreenAnnotation.Shape, text: String, hasStepNumber: Bool, in size: CGSize) -> CGPoint {
        let halfHeight: CGFloat = 14
        let gap: CGFloat = 10
        var center: CGPoint
        switch shape {
        case .arrow(let tail, let tip):
            let length = max(1, hypot(tail.x - tip.x, tail.y - tip.y))
            center = CGPoint(x: tail.x + (tail.x - tip.x) / length * (gap + halfHeight), y: tail.y + (tail.y - tip.y) / length * (gap + halfHeight))
        case .circle(let circleCenter, let radius):
            let below = circleCenter.y + radius + gap + halfHeight
            center = CGPoint(x: circleCenter.x, y: below + halfHeight > size.height ? circleCenter.y - radius - gap - halfHeight : below)
        case .box(let rect):
            let below = rect.maxY + gap + halfHeight
            center = CGPoint(x: rect.midX, y: below + halfHeight > size.height ? rect.minY - gap - halfHeight : below)
        case .underline(let from, let to):
            let below = max(from.y, to.y) + gap + halfHeight
            center = CGPoint(x: (from.x + to.x) / 2, y: below + halfHeight > size.height ? min(from.y, to.y) - gap - halfHeight - 12 : below)
        case .label(let point):
            center = point
        }
        // SF Pro Medium at 12.5 averages a little under 7 points a character.
        let halfWidth = min(size.width / 2, (CGFloat(text.count) * 6.9 + (hasStepNumber ? 46 : 22)) / 2)
        center.x = min(max(center.x, halfWidth + 6), size.width - halfWidth - 6)
        center.y = min(max(center.y, halfHeight + 6), size.height - halfHeight - 6)
        return center
    }
}

/// A caption on the same smoked glass as the bar, with its step number in an ember disc.
private struct AmbientAnnotationCaption: View {
    var text: String
    var stepNumber: Int?

    var body: some View {
        HStack(spacing: 7) {
            if let stepNumber {
                Text("\(stepNumber)")
                    .font(.system(size: 11, weight: .bold).monospacedDigit())
                    .foregroundStyle(AmbientDesign.Palette.emberInk)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(AmbientDesign.Palette.ember))
            }
            Text(text)
                .font(AmbientDesign.Typeface.pillLabel)
                .foregroundStyle(AmbientDesign.Palette.onSmokePrimary)
                .lineLimit(1)
        }
        .padding(.leading, stepNumber == nil ? 11 : 5)
        .padding(.trailing, 11)
        .frame(height: 28)
        .background(AmbientSmokedGlassBackground(cornerRadius: 14, isRaisedCard: false))
        .environment(\.colorScheme, .dark)
    }
}
