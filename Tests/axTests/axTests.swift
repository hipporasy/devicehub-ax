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
