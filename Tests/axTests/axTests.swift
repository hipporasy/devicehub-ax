import XCTest
@testable import ax

final class LabelTests: XCTestCase {
    func testEditDistance() {
        XCTAssertEqual(editDistance(Array("pause"), Array("pase")), 1)
        XCTAssertEqual(editDistance(Array("home"), Array("home")), 0)
        XCTAssertEqual(editDistance(Array(""), Array("abc")), 3)
        XCTAssertEqual(editDistance(Array("kitten"), Array("sitting")), 3)
    }

    func testClosestLabelsPutsTyposAndSubstringsFirst() {
        let names = ["Settings", "Start Reading", "Start Focus", "Progress", "Home"]
        XCTAssertEqual(closestLabels(to: "Start Readng", among: names).first, "Start Reading")
        XCTAssertEqual(closestLabels(to: "focus", among: names).first, "Start Focus")
    }

    func testClosestLabelsDropsEmptyAndRepeatedNamesAndKeepsTen() {
        let names = ["", "Home", "Home"] + (1...20).map { "Item \($0)" }
        let result = closestLabels(to: "Home", among: names)
        XCTAssertEqual(result.first, "Home")
        XCTAssertEqual(result.filter { $0 == "Home" }.count, 1)
        XCTAssertFalse(result.contains(""))
        XCTAssertEqual(result.count, 10)
    }
}

final class SimulatorParsingTests: XCTestCase {
    func testRuntimeName() {
        XCTAssertEqual(runtimeName("com.apple.CoreSimulator.SimRuntime.iOS-27-1"), "iOS 27.1")
        XCTAssertEqual(runtimeName("com.apple.CoreSimulator.SimRuntime.watchOS-27-0"), "watchOS 27.0")
        XCTAssertEqual(runtimeName("unknown"), "unknown")
    }

    func testBootedSimulatorsAreDeduplicatedAndFiltered() throws {
        let json = """
        {"devices": {
          "com.apple.CoreSimulator.SimRuntime.iOS-27-1": [
            {"udid": "AAA", "name": "iPhone Duo", "state": "Booted"},
            {"udid": "BBB", "name": "iPhone 17", "state": "Shutdown"}
          ],
          "com.apple.CoreSimulator.SimRuntime.iOS-27-0": [
            {"udid": "AAA", "name": "iPhone Duo", "state": "Booted"}
          ]
        }}
        """
        let simulators = try parseBootedSimulators(Data(json.utf8))
        XCTAssertEqual(simulators.map(\.identifier), ["AAA"])
        XCTAssertEqual(simulators.first?.name, "iPhone Duo")
        XCTAssertEqual(simulators.first?.runtime, "iOS 27.0")
    }

    /// Trimmed from `devicectl device info displays` for an unfolded iPhone Duo on Xcode 27.1.
    let unfoldedDuo = """
    {"result": {
      "orientation": {"currentDeviceOrientation": "landscapeLeft"},
      "displays": [
        {"displayId": 1, "uniqueId": "OUTER", "primary": true, "active": false, "backlightState": "off",
         "bounds": [[0, 0], [1398, 2034]], "currentOrientation": "rot0"},
        {"displayId": 3, "uniqueId": "INNER", "primary": false, "active": true, "backlightState": "activeOn",
         "bounds": [[0, 0], [2007, 2853]], "currentOrientation": "rot270"}
      ]
    }}
    """

    func testDisplayInfoNamesOuterAndInnerDisplays() throws {
        let info = try parseDisplayInfo(Data(unfoldedDuo.utf8))
        XCTAssertEqual(info.orientation, "landscapeLeft")
        XCTAssertEqual(info.displays.map(\.position), ["outer", "inner"])
        let inner = try XCTUnwrap(info.displays.last)
        XCTAssertEqual(inner.identifier, 3)
        XCTAssertEqual(inner.width, 2007)
        XCTAssertEqual(inner.height, 2853)
        XCTAssertTrue(inner.isOn)
        XCTAssertFalse(info.displays[0].isOn)
    }

    func testPoseAndActiveDisplay() throws {
        let displays = try parseDisplayInfo(Data(unfoldedDuo.utf8)).displays
        XCTAssertEqual(ax.pose(of: displays), "unfolded")
        XCTAssertEqual(activeDisplay(displays)?.identifier, 3)

        let single = Array(displays.prefix(1))
        XCTAssertEqual(ax.pose(of: single), "n/a")
    }

    func testSingleDisplayIsMain() throws {
        let json = """
        {"result": {"displays": [{"displayId": 1, "primary": true, "active": true, "backlightState": "activeOn",
          "bounds": [[0, 0], [1320, 2868]], "currentOrientation": "rot0"}]}}
        """
        let info = try parseDisplayInfo(Data(json.utf8))
        XCTAssertEqual(info.displays.map(\.position), ["main"])
        XCTAssertEqual(info.orientation, "")
    }
}

final class DisplayStateTests: XCTestCase {
    /// `devicectl` for a single-screen iPhone 17 on Xcode 27.2: no `active` key and an unknown backlight.
    func testSingleScreenSimulatorWithUnknownStateCountsAsOn() throws {
        let json = """
        {"result": {"backlightState": "unknown", "displays": [{"displayId": 1, "primary": true, "backlightState": "unknown",
          "bounds": [[0, 0], [1206, 2622]], "pointScale": 3, "currentOrientation": "rot0"}]}}
        """
        let display = try XCTUnwrap(parseDisplayInfo(Data(json.utf8)).displays.first)
        XCTAssertNil(display.active)
        XCTAssertTrue(display.isOn)
        XCTAssertEqual(display.pointSize, CGSize(width: 402, height: 874))
        XCTAssertEqual(activeDisplay([display])?.identifier, 1)
    }

    func testAnOffDisplayStaysOff() throws {
        let json = """
        {"result": {"displays": [{"displayId": 1, "primary": true, "active": false, "backlightState": "off",
          "bounds": [[0, 0], [1398, 2034]], "currentOrientation": "rot0"}]}}
        """
        let display = try XCTUnwrap(parseDisplayInfo(Data(json.utf8)).displays.first)
        XCTAssertFalse(display.isOn)
        XCTAssertNil(display.pointSize)
    }

    func testBlackPixelsAreBlackAndOneLightPixelIsNot() {
        var pixels = [UInt8](repeating: 4, count: 16 * 4)
        pixels.withUnsafeBufferPointer { XCTAssertTrue(isBlack($0)) }
        pixels[20] = 200
        pixels.withUnsafeBufferPointer { XCTAssertFalse(isBlack($0)) }
    }

    func testMatchingDisplayGoesByShape() throws {
        let duo = try parseDisplayInfo(Data(SimulatorParsingTests().unfoldedDuo.utf8)).displays
        // The inner display drawn at a smaller scale in the window.
        XCTAssertEqual(matchingDisplay(for: CGSize(width: 669, height: 951), among: duo)?.position, "inner")
        XCTAssertEqual(matchingDisplay(for: CGSize(width: 466, height: 678), among: duo)?.position, "outer")
        XCTAssertNil(matchingDisplay(for: .zero, among: duo))
    }
}

final class ScreenListingTests: XCTestCase {
    func testDeviceFrameScalesIntoDevicePoints() {
        let screen = CGRect(x: 100, y: 50, width: 201, height: 437)
        let element = CGRect(x: 116, y: 377.5, width: 169, height: 22)
        XCTAssertEqual(deviceFrame(element, screen: screen, devicePoints: CGSize(width: 402, height: 874)),
                       CGRect(x: 32, y: 655, width: 338, height: 44))
        XCTAssertEqual(deviceFrame(element, screen: screen, devicePoints: nil), CGRect(x: 16, y: 328, width: 169, height: 22))
    }

    func testCoversScreenFlagsOnlyNearlyWholeScreenFrames() {
        let screen = CGRect(x: 0, y: 0, width: 400, height: 800)
        XCTAssertTrue(coversScreen(screen, screen: screen))
        XCTAssertTrue(coversScreen(CGRect(x: -10, y: 0, width: 420, height: 760), screen: screen))
        XCTAssertFalse(coversScreen(CGRect(x: 0, y: 0, width: 400, height: 44), screen: screen))
        XCTAssertFalse(coversScreen(CGRect(x: 500, y: 0, width: 10, height: 10), screen: screen))
        XCTAssertFalse(coversScreen(screen, screen: .zero))
    }

    func testListingKeepsUnnamedReachableElementsAndDropsUnnamedContainers() {
        func list(_ role: String, label: String = "", value: String = "", interactive: Bool = false, actions: Bool = false, leaf: Bool = false) -> (listed: Bool, unlabeled: Bool) {
            listing(role: role, label: label, identifier: "", value: value, interactive: interactive, hasActions: actions, isLeaf: leaf)
        }
        XCTAssertTrue(list("AXButton", label: "Menu", interactive: true) == (true, false))
        XCTAssertTrue(list("AXButton", interactive: true) == (true, true))
        XCTAssertTrue(list("AXButton", value: "3", interactive: true) == (true, true), "a value is not a name for a control")
        XCTAssertTrue(list("AXStaticText", value: "Hello", leaf: true) == (true, false), "text reads its value")
        XCTAssertTrue(list("AXGroup", actions: true) == (true, true))
        XCTAssertTrue(list("AXImage", leaf: true) == (true, true))
        XCTAssertTrue(list("AXGroup", leaf: true) == (false, false), "an empty container")
        XCTAssertTrue(list("AXGroup") == (false, false))
    }

    func testWindowTitleMatchesTheWholeDeviceName() {
        XCTAssertTrue(windowTitle("iPhone 17 – iOS 27.2", names: "iPhone 17"))
        XCTAssertTrue(windowTitle("iPhone 17", names: "iPhone 17"))
        XCTAssertFalse(windowTitle("iPhone 17e – iOS 27.2", names: "iPhone 17"))
        XCTAssertFalse(windowTitle("iPhone 17 Pro – iOS 27.2", names: "iPhone 17 Pro Max"))
    }

    func testFrameText() {
        XCTAssertEqual(frameText(CGRect(x: 32, y: 655, width: 338, height: 44)), "32,655 338x44")
    }
}
