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
        /// A freeform line through the points, for drawing shapes and diagrams. Closed joins the last point to the first.
        case path(points: [CGPoint], isClosed: Bool)
        /// Text alone, centred on the point.
        case label(at: CGPoint)
    }

    /// Ink for drawings. Ember is Ambient's own colour and the default; the others are for when the person
    /// asks for a colour or a diagram needs to tell its parts apart.
    public enum Ink: String, Sendable, CaseIterable {
        case ember, red, yellow, green, blue, purple, white, black

        var color: Color {
            switch self {
            case .ember: return AmbientDesign.Palette.ember
            case .red: return Color(red: 1.0, green: 0.27, blue: 0.23)
            case .yellow: return Color(red: 1.0, green: 0.84, blue: 0.04)
            case .green: return Color(red: 0.19, green: 0.82, blue: 0.35)
            case .blue: return Color(red: 0.04, green: 0.52, blue: 1.0)
            case .purple: return Color(red: 0.75, green: 0.35, blue: 0.95)
            case .white: return Color.white
            case .black: return Color(white: 0.08)
            }
        }
    }

    public var shape: Shape
    /// A short caption beside the shape.
    public var text: String?
    public var ink: Ink
    /// Tints the inside of a closed shape with its ink.
    public var isFilled: Bool

    public init(shape: Shape, text: String? = nil, ink: Ink = .ember, isFilled: Bool = false) {
        self.shape = shape
        self.text = text
        self.ink = ink
        self.isFilled = isFilled
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
            let captionCenters = AmbientAnnotationGeometry.captionCenters(for: annotations, in: geometry.size)
            ZStack {
                ForEach(Array(annotations.enumerated()), id: \.offset) { index, annotation in
                    let delay = isStatic ? 0 : Double(index) * Self.stagger
                    let progress: CGFloat = isDrawn || isSnapshotRendering ? 1 : 0
                    let path = AmbientAnnotationGeometry.path(for: annotation.shape)
                    if annotation.isFilled {
                        // The fill washes in as the outline closes.
                        path.fill(annotation.ink.color.opacity(0.3))
                            .opacity(progress)
                            .animation(isStatic ? .easeOut(duration: 0.18) : .easeOut(duration: 0.3).delay(delay + Self.strokeDuration * 0.8), value: isDrawn)
                    }
                    // An under-stroke of the opposite tone keeps the line readable on white pages and bright photos.
                    path
                        .trim(from: 0, to: progress)
                        .stroke(annotation.ink == .black ? Color.white.opacity(0.55) : Color.black.opacity(0.42), style: StrokeStyle(lineWidth: 6.5, lineCap: .round, lineJoin: .round))
                        .animation(strokeAnimation(delay: delay, isStatic: isStatic), value: isDrawn)
                    path
                        .trim(from: 0, to: progress)
                        .stroke(annotation.ink.color, style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round))
                        .shadow(color: annotation.ink.color.opacity(0.55), radius: 5)
                        .animation(strokeAnimation(delay: delay, isStatic: isStatic), value: isDrawn)
                    if let text = annotation.text, !text.isEmpty {
                        let stepNumber = numbersSteps ? annotations[...index].filter { $0.text?.isEmpty == false }.count : nil
                        AmbientAnnotationCaption(text: text, stepNumber: stepNumber)
                            .fixedSize()
                            .position(captionCenters[index] ?? .zero)
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
        case .path(let points, let isClosed):
            path.addLines(points)
            if isClosed { path.closeSubpath() }
        case .label:
            break
        }
        return path
    }

    static func captionHalfSize(text: String, hasStepNumber: Bool, in size: CGSize) -> CGSize {
        // SF Pro Medium at 12.5 averages a little under 7 points a character.
        CGSize(width: min(size.width / 2, (CGFloat(text.count) * 6.9 + (hasStepNumber ? 46 : 22)) / 2), height: 14)
    }

    /// Where every caption sits, in order, nil for an annotation without one. Each takes the first of its
    /// shape's places that does not cover a caption placed before it.
    static func captionCenters(for annotations: [AmbientScreenAnnotation], in size: CGSize) -> [CGPoint?] {
        // The middle of everything drawn, weighted by corners: the bounding box's centre would sit exactly on
        // the long side of a right triangle and could not tell its inside from its outside.
        var corners: [CGPoint] = []
        for annotation in annotations {
            if case .path(let points, _) = annotation.shape { corners += points }
            else {
                let bounds = path(for: annotation.shape).boundingRect
                if !bounds.isNull && !bounds.isEmpty { corners.append(CGPoint(x: bounds.midX, y: bounds.midY)) }
            }
        }
        let figureCentre = corners.isEmpty ? CGPoint(x: size.width / 2, y: size.height / 2)
            : CGPoint(x: corners.map(\.x).reduce(0, +) / CGFloat(corners.count), y: corners.map(\.y).reduce(0, +) / CGFloat(corners.count))
        let numbersSteps = annotations.filter { $0.text?.isEmpty == false }.count > 1
        var placedRects: [CGRect] = []
        return annotations.map { annotation in
            guard let text = annotation.text, !text.isEmpty else { return nil }
            let halfSize = captionHalfSize(text: text, hasStepNumber: numbersSteps, in: size)
            func rect(_ center: CGPoint) -> CGRect {
                CGRect(x: center.x - halfSize.width, y: center.y - halfSize.height, width: halfSize.width * 2, height: halfSize.height * 2).insetBy(dx: -4, dy: -4)
            }
            let places = captionPlaces(for: annotation.shape, halfSize: halfSize, awayFrom: figureCentre, in: size)
            let chosen = places.first { place in !placedRects.contains { $0.intersects(rect(place)) } } ?? places[0]
            placedRects.append(rect(chosen))
            return chosen
        }
    }

    /// The best place for one caption, with nothing else on screen.
    static func captionCenter(for shape: AmbientScreenAnnotation.Shape, text: String, hasStepNumber: Bool, in size: CGSize) -> CGPoint {
        captionPlaces(for: shape, halfSize: captionHalfSize(text: text, hasStepNumber: hasStepNumber, in: size),
                      awayFrom: CGPoint(x: size.width / 2, y: size.height / 2), in: size)[0]
    }

    /// Places for a caption just outside its shape, best first, each clamped so it stays on the display.
    static func captionPlaces(for shape: AmbientScreenAnnotation.Shape, halfSize: CGSize, awayFrom figureCentre: CGPoint, in size: CGSize) -> [CGPoint] {
        let gap: CGFloat = 10
        let halfHeight = halfSize.height
        var places: [CGPoint]
        /// Below the shape, or above it when there is no room below; the other one is the second choice.
        func belowThenAbove(x: CGFloat, top: CGFloat, bottom: CGFloat) -> [CGPoint] {
            let below = CGPoint(x: x, y: bottom + gap + halfHeight), above = CGPoint(x: x, y: top - gap - halfHeight)
            return below.y + halfHeight > size.height ? [above, below] : [below, above]
        }
        switch shape {
        case .arrow(let tail, let tip):
            let length = max(1, hypot(tail.x - tip.x, tail.y - tip.y))
            places = [CGPoint(x: tail.x + (tail.x - tip.x) / length * (gap + halfHeight), y: tail.y + (tail.y - tip.y) / length * (gap + halfHeight))]
        case .circle(let circleCenter, let radius):
            places = belowThenAbove(x: circleCenter.x, top: circleCenter.y - radius, bottom: circleCenter.y + radius)
        case .box(let rect):
            places = belowThenAbove(x: rect.midX, top: rect.minY, bottom: rect.maxY)
        case .underline(let from, let to):
            places = belowThenAbove(x: (from.x + to.x) / 2, top: min(from.y, to.y) - 12, bottom: max(from.y, to.y))
        case .path(let points, _) where points.count == 2:
            // A single stroke is named beside its middle, on the side facing away from the rest of the figure.
            let middle = CGPoint(x: (points[0].x + points[1].x) / 2, y: (points[0].y + points[1].y) / 2)
            let length = max(1, hypot(points[1].x - points[0].x, points[1].y - points[0].y))
            let normal = CGPoint(x: -(points[1].y - points[0].y) / length, y: (points[1].x - points[0].x) / length)
            // Far enough along the normal that the caption's rectangle clears the stroke.
            let distance = gap + abs(normal.x) * halfSize.width + abs(normal.y) * halfHeight
            let sides = [1.0, -1.0].map { CGPoint(x: middle.x + normal.x * distance * $0, y: middle.y + normal.y * distance * $0) }
            places = sides.sorted { hypot($0.x - figureCentre.x, $0.y - figureCentre.y) > hypot($1.x - figureCentre.x, $1.y - figureCentre.y) }
        case .path(let points, _):
            places = belowThenAbove(x: ((points.map(\.x).min() ?? 0) + (points.map(\.x).max() ?? 0)) / 2,
                                    top: points.map(\.y).min() ?? 0, bottom: points.map(\.y).max() ?? 0)
        case .label(let point):
            places = [point]
        }
        return places.map { place in
            CGPoint(x: min(max(place.x, halfSize.width + 6), size.width - halfSize.width - 6),
                    y: min(max(place.y, halfHeight + 6), size.height - halfHeight - 6))
        }
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
