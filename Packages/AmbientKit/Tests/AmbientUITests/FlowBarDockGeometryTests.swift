import XCTest
@testable import AmbientUI

final class FlowBarDockGeometryTests: XCTestCase {
    /// A 1512x945 visible frame sitting above a 37-point Dock, like a 14-inch MacBook Pro.
    private let visibleFrame = CGRect(x: 0, y: 37, width: 1512, height: 908)

    func testNearestEdgePicksTheClosestSide() {
        XCTAssertEqual(FlowBarDockGeometry.nearestEdge(to: CGPoint(x: 700, y: 60), within: visibleFrame), .bottom)
        XCTAssertEqual(FlowBarDockGeometry.nearestEdge(to: CGPoint(x: 700, y: 930), within: visibleFrame), .top)
        XCTAssertEqual(FlowBarDockGeometry.nearestEdge(to: CGPoint(x: 20, y: 500), within: visibleFrame), .left)
        XCTAssertEqual(FlowBarDockGeometry.nearestEdge(to: CGPoint(x: 1500, y: 500), within: visibleFrame), .right)
    }

    func testNearestEdgeClampsPointsOutsideTheFrame() {
        // Released over the Dock (below the visible frame): lands on the bottom edge.
        XCTAssertEqual(FlowBarDockGeometry.nearestEdge(to: CGPoint(x: 700, y: 5), within: visibleFrame), .bottom)
        // Released far off to the right of this display.
        XCTAssertEqual(FlowBarDockGeometry.nearestEdge(to: CGPoint(x: 2400, y: 500), within: visibleFrame), .right)
    }

    func testPositionAlongEdgeSnapsToCentre() {
        let centreX = visibleFrame.midX
        let nearCentre = FlowBarDockGeometry.positionAlongEdge(for: CGPoint(x: centreX + 20, y: 60), on: .bottom, within: visibleFrame, endMargin: 40)
        XCTAssertEqual(nearCentre, 0.5)
        let outsideSnap = FlowBarDockGeometry.positionAlongEdge(for: CGPoint(x: centreX + 60, y: 60), on: .bottom, within: visibleFrame, endMargin: 40)
        XCTAssertGreaterThan(outsideSnap, 0.5)
    }

    func testPositionAlongEdgeIsClampedToTheUsableRange() {
        let farLeft = FlowBarDockGeometry.positionAlongEdge(for: CGPoint(x: -300, y: 60), on: .bottom, within: visibleFrame, endMargin: 40)
        let farRight = FlowBarDockGeometry.positionAlongEdge(for: CGPoint(x: 5000, y: 60), on: .bottom, within: visibleFrame, endMargin: 40)
        XCTAssertEqual(farLeft, 0)
        XCTAssertEqual(farRight, 1)
    }

    func testVerticalEdgesMeasureAlongY() {
        let lowOnLeftEdge = FlowBarDockGeometry.positionAlongEdge(for: CGPoint(x: 10, y: 37 + 40), on: .left, within: visibleFrame, endMargin: 40)
        XCTAssertEqual(lowOnLeftEdge, 0, accuracy: 0.0001)
    }

    func testAnchorPointRoundTripsWithPosition() {
        for edge in FlowBarDockEdge.allCases {
            let anchor = FlowBarDockGeometry.anchorPoint(for: edge, positionAlongEdge: 0.27, within: visibleFrame, endMargin: 40, insetFromEdge: 8)
            let recoveredPosition = FlowBarDockGeometry.positionAlongEdge(for: anchor, on: edge, within: visibleFrame, endMargin: 40)
            XCTAssertEqual(recoveredPosition, 0.27, accuracy: 0.0001, "edge \(edge)")
        }
    }

    func testAnchorPointSitsInsideTheVisibleFrameByTheInset() {
        let bottomAnchor = FlowBarDockGeometry.anchorPoint(for: .bottom, positionAlongEdge: 0.5, within: visibleFrame, endMargin: 40, insetFromEdge: 8)
        XCTAssertEqual(bottomAnchor, CGPoint(x: visibleFrame.midX, y: 45))
        let rightAnchor = FlowBarDockGeometry.anchorPoint(for: .right, positionAlongEdge: 0.5, within: visibleFrame, endMargin: 40, insetFromEdge: 8)
        XCTAssertEqual(rightAnchor, CGPoint(x: 1504, y: visibleFrame.midY))
    }

    func testProjectionCarriesAFlickTowardTheEdgeItWasThrownAt() {
        // Released nearer the bottom but flicked hard to the right.
        let releasePoint = CGPoint(x: 1100, y: 200)
        let projected = FlowBarDockGeometry.projectedRestingPoint(from: releasePoint, velocity: CGVector(dx: 4000, dy: 0))
        XCTAssertEqual(FlowBarDockGeometry.nearestEdge(to: releasePoint, within: visibleFrame), .bottom)
        XCTAssertEqual(FlowBarDockGeometry.nearestEdge(to: projected, within: visibleFrame), .right)
    }

    func testProjectionWithoutVelocityStaysPut() {
        let releasePoint = CGPoint(x: 300, y: 300)
        XCTAssertEqual(FlowBarDockGeometry.projectedRestingPoint(from: releasePoint, velocity: .zero), releasePoint)
    }

    func testPanelFrameStaysInsideTheVisibleFrameNearACorner() {
        let anchorNearLeftEnd = CGPoint(x: 40, y: 45)
        let panelFrame = FlowBarDockGeometry.panelFrame(anchorPoint: anchorNearLeftEnd, edge: .bottom, panelSize: CGSize(width: 500, height: 560), within: visibleFrame)
        XCTAssertEqual(panelFrame.minX, 0)
        XCTAssertEqual(panelFrame.minY, visibleFrame.minY)
        let anchorOnRightEdge = CGPoint(x: 1504, y: 900)
        let rightPanel = FlowBarDockGeometry.panelFrame(anchorPoint: anchorOnRightEdge, edge: .right, panelSize: CGSize(width: 470, height: 600), within: visibleFrame)
        XCTAssertEqual(rightPanel.maxX, visibleFrame.maxX)
        XCTAssertEqual(rightPanel.maxY, visibleFrame.maxY)
    }

    func testPanelContentConversionRoundTrips() {
        let panelFrame = CGRect(x: 500, y: 37, width: 500, height: 560)
        let screenPoint = CGPoint(x: 756, y: 45)
        let contentPoint = FlowBarDockGeometry.pointInPanelContent(screenPoint, panelFrame: panelFrame)
        XCTAssertEqual(contentPoint, CGPoint(x: 256, y: 552))
        let contentRect = CGRect(x: 237, y: 544, width: 38, height: 8)
        let screenRect = FlowBarDockGeometry.screenRect(fromPanelContentRect: contentRect, panelFrame: panelFrame)
        XCTAssertEqual(screenRect, CGRect(x: 737, y: 45, width: 38, height: 8))
    }

    func testSavedDisplayIsFoundOrFallsBackToMain() {
        let placementOnSecondDisplay = FlowBarDockPlacement(displayIdentifier: "B", edge: .left, positionAlongEdge: 0.2)
        XCTAssertEqual(FlowBarDockGeometry.indexOfDisplay(for: placementOnSecondDisplay, displayIdentifiers: ["A", "B"], mainDisplayIndex: 0), 1)
        // The second display was unplugged.
        XCTAssertEqual(FlowBarDockGeometry.indexOfDisplay(for: placementOnSecondDisplay, displayIdentifiers: ["A"], mainDisplayIndex: 0), 0)
        XCTAssertNil(FlowBarDockGeometry.indexOfDisplay(for: placementOnSecondDisplay, displayIdentifiers: [], mainDisplayIndex: 0))
    }

    func testDisplayContainingAPointFallsBackToTheNearest() {
        let displayFrames = [CGRect(x: 0, y: 0, width: 1512, height: 982), CGRect(x: 1512, y: 0, width: 2560, height: 1440)]
        XCTAssertEqual(FlowBarDockGeometry.indexOfDisplay(containing: CGPoint(x: 2000, y: 700), displayFrames: displayFrames), 1)
        // In the gap above the shorter display.
        XCTAssertEqual(FlowBarDockGeometry.indexOfDisplay(containing: CGPoint(x: 1000, y: 1300), displayFrames: displayFrames), 0)
    }
}

final class FlowBarPlacementStoreTests: XCTestCase {
    func testPlacementSurvivesASaveAndLoad() throws {
        let suiteName = "AmbientUITests.\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let store = FlowBarPlacementStore(userDefaults: userDefaults)
        XCTAssertNil(store.loadPlacement())
        let placement = FlowBarDockPlacement(displayIdentifier: "37D8832A-2D66-02CA-B9F7-8F30A301B230", edge: .right, positionAlongEdge: 0.73)
        store.savePlacement(placement)
        XCTAssertEqual(FlowBarPlacementStore(userDefaults: userDefaults).loadPlacement(), placement)
    }

    func testCorruptStoredDataIsIgnored() throws {
        let suiteName = "AmbientUITests.\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        userDefaults.set(Data("not json".utf8), forKey: "ambient.flowBar.dockPlacement")
        XCTAssertNil(FlowBarPlacementStore(userDefaults: userDefaults).loadPlacement())
    }
}
