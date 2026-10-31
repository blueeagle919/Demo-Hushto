import XCTest

final class ScanFlowUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    private func launch(_ appearance: String = "라이트 모드") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-HushtoUITesting", "-defaultMode", "스캔", "-appearance", appearance]
        app.launch()
        return app
    }
    private func capture(_ app: XCUIApplication) {
        let shutter = app.buttons["무음 촬영"]
        XCTAssertTrue(shutter.waitForExistence(timeout: 15))
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: shutter)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 15), .completed)
        shutter.tap()
        XCTAssertTrue(app.navigationBars["촬영 확인"].waitForExistence(timeout: 20), app.debugDescription)
    }
    private func screenshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    func testScanCaptureReachesReview() {
        let app = launch()
        screenshot(app, "camera-light")
        capture(app)
        screenshot(app, "capture-review-light")
        XCTAssertTrue(app.buttons["사진 보정"].firstMatch.exists)
    }
    func testEditorCropAnd3DRotation() {
        let app = launch()
        capture(app)
        app.buttons["사진 보정"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["사진 보정"].waitForExistence(timeout: 10))
        screenshot(app, "editor-auto-light")
        app.buttons["자르기"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["자르기"].waitForExistence(timeout: 10))
        screenshot(app, "crop-corners-light")
        let corner = app.descendants(matching: .any)["crop.corner.0"].firstMatch
        XCTAssertTrue(corner.exists)
        corner.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: corner.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).withOffset(CGVector(dx: 12, dy: 18)))
        app.buttons["자르기 적용"].tap()
        XCTAssertTrue(app.navigationBars["사진 보정"].waitForExistence(timeout: 10))
        app.buttons["회전"].firstMatch.tap()
        app.buttons["3D 회전"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["3D 회전"].waitForExistence(timeout: 10))
        screenshot(app, "rotation-3d-light")
        XCTAssertEqual(app.sliders.count, 2)
        app.sliders.firstMatch.adjust(toNormalizedSliderPosition: 0.65)
        app.buttons["보정 저장"].tap()
        XCTAssertTrue(app.navigationBars["촬영 확인"].waitForExistence(timeout: 15))
    }
    func testDarkCameraAndEditor() {
        let app = launch("다크 모드")
        screenshot(app, "camera-dark")
        capture(app)
        app.buttons["사진 보정"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["사진 보정"].waitForExistence(timeout: 10))
        screenshot(app, "editor-auto-dark")
    }
}
