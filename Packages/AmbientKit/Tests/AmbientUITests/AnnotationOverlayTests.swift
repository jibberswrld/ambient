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
            AmbientScreenAnnotation(shape: .label(at: CGPoint(x: 660, y: 500)), text: "Link settings live here")
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
