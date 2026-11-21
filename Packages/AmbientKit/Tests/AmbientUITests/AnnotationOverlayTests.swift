import AppKit
import SwiftUI
import XCTest
@testable import AmbientUI

@MainActor
final class AnnotationOverlayTests: XCTestCase {
    func testCaptionsStayOnTheDisplay() {
        let size = CGSize(width: 800, height: 500)
        let nearCorner = AmbientAnnotationGeometry.captionCenter(for: .circle(center: CGPoint(x: 790, y: 490), radius: 20), text: "Click the Share button", hasStepNumber: true, in: size)
        XCTAssertLessThan(nearCorner.y, 470, "A caption with no room below its shape goes above it.")
        XCTAssertLessThanOrEqual(nearCorner.x, 800 - 22 * 6.9 / 2)
        let arrow = AmbientAnnotationGeometry.captionCenter(for: .arrow(tail: CGPoint(x: 300, y: 300), tip: CGPoint(x: 400, y: 300)), text: "Here", hasStepNumber: false, in: size)
        XCTAssertLessThan(arrow.x, 300, "An arrow's caption sits beyond its tail, away from the target.")
    }

    func testEveryShapeRenders() throws {
        let size = CGSize(width: 900, height: 560)
        let annotations = [
            AmbientScreenAnnotation(shape: .box(CGRect(x: 610, y: 60, width: 150, height: 36)), text: "Click Share"),
            AmbientScreenAnnotation(shape: .arrow(tail: CGPoint(x: 330, y: 330), tip: CGPoint(x: 470, y: 248)), text: "Then pick a person"),
            AmbientScreenAnnotation(shape: .circle(center: CGPoint(x: 160, y: 420), radius: 30), text: "Send"),
            AmbientScreenAnnotation(shape: .underline(from: CGPoint(x: 560, y: 430), to: CGPoint(x: 760, y: 430))),
            AmbientScreenAnnotation(shape: .label(at: CGPoint(x: 660, y: 500)), text: "Link settings live here"),
            AmbientScreenAnnotation(shape: .path(points: [CGPoint(x: 60, y: 250), CGPoint(x: 60, y: 90), CGPoint(x: 260, y: 250)], isClosed: true), text: "Right triangle", ink: .red, isFilled: true),
            AmbientScreenAnnotation(shape: .path(points: [CGPoint(x: 60, y: 232), CGPoint(x: 78, y: 232), CGPoint(x: 78, y: 250)], isClosed: false), ink: .white)
        ]
        for (name, white) in [("light", 0.97), ("dark", 0.12)] {
            let backdrop = NSImage(size: size, flipped: false) { rect in
                NSColor(white: white, alpha: 1).setFill(); rect.fill(); return true
            }
            let image = try XCTUnwrap(AmbientSnapshotRenderer.renderOverBackdrop(AmbientAnnotationOverlayView(annotations: annotations), canvasSize: size, backdrop: backdrop))
            let data = try XCTUnwrap(AmbientSnapshotRenderer.pngData(from: image))
            XCTAssertGreaterThan(data.count, 10_000)
            if let directory = ProcessInfo.processInfo.environment["AMBIENT_CAPTURE_DIRECTORY"] {
                try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("drawing-\(name).png"))
            }
        }
    }
}

extension AnnotationOverlayTests {
    /// The drawing the live app produced for "show me how to draw a right triangle", stroke by stroke.
    func testSketchRendersWithCaptionsBesideTheirStrokes() throws {
        let size = CGSize(width: 900, height: 560)
        let corner = CGPoint(x: 300, y: 430), top = CGPoint(x: 300, y: 150), end = CGPoint(x: 600, y: 430)
        let annotations = [
            AmbientScreenAnnotation(shape: .path(points: [corner, end], isClosed: false), text: "Draw a horizontal base", ink: .yellow),
            AmbientScreenAnnotation(shape: .path(points: [corner, top], isClosed: false), text: "Draw a vertical side", ink: .blue),
            AmbientScreenAnnotation(shape: .path(points: [top, end], isClosed: false), text: "Connect the ends", ink: .green),
            AmbientScreenAnnotation(shape: .path(points: [CGPoint(x: 300, y: 405), CGPoint(x: 325, y: 405), CGPoint(x: 325, y: 430)], isClosed: false), ink: .white)
        ]
        let centers = AmbientAnnotationGeometry.captionCenters(for: annotations, in: size).compactMap { $0 }
        XCTAssertEqual(centers.count, 3)
        XCTAssertGreaterThan(centers[0].y, 430, "The base is named below itself, outside the triangle.")
        XCTAssertLessThan(centers[1].x, 300, "The vertical side is named to its left, outside the triangle.")
        XCTAssertGreaterThan(centers[2].x, 450, "The hypotenuse is named on its outer side.")
        XCTAssertLessThan(centers[2].y, 290)
        let backdrop = NSImage(size: size, flipped: false) { rect in NSColor(white: 0.97, alpha: 1).setFill(); rect.fill(); return true }
        let image = try XCTUnwrap(AmbientSnapshotRenderer.renderOverBackdrop(AmbientAnnotationOverlayView(annotations: annotations), canvasSize: size, backdrop: backdrop))
        if let directory = ProcessInfo.processInfo.environment["AMBIENT_CAPTURE_DIRECTORY"] {
            try XCTUnwrap(AmbientSnapshotRenderer.pngData(from: image)).write(to: URL(fileURLWithPath: directory).appendingPathComponent("sketch-light.png"))
        }
    }
}
