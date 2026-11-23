import ApplicationServices
import Foundation

let deviceHubExecutable = "DeviceHub"

/// A Device Hub window showing a device: the buttons under it, and the device's own accessibility tree.
struct DeviceWindow {
    let element: AXUIElement
    let title: String
    /// The UDID of the device selected in the window's sidebar, when the sidebar is showing.
    let deviceIdentifier: String?
    /// The group holding Home, Screenshot, Rotate Right, the pose buttons and the screen.
    let controlsGroup: AXUIElement

    var controls: [AXUIElement] { children(controlsGroup).filter { role($0) == kAXButtonRole } }
    var screenRoots: [AXUIElement] { children(controlsGroup).filter { role($0) != kAXButtonRole } }

    /// The elements `ax screen` lists, each with the screen it is on. Device Hub can expose the same screen twice,
    /// so repeats are dropped, and so are unnamed containers. An unnamed element a person can reach stays, flagged.
    var screenEntries: [ScreenElement] {
        var seen = Set<String>()
        return screenRoots.flatMap { root -> [ScreenElement] in
            let rootFrame = frame(root)
            return descendants(of: root).dropFirst().compactMap { node -> ScreenElement? in
                let element = node.element
                let elementRole = role(element), label = displayLabel(element)
                let identifier = attribute(element, "AXIdentifier"), value = attribute(element, kAXValueAttribute)
                // VoiceOver reads a text field's placeholder as its name when it has no label.
                let name = label.isEmpty && textRoles.contains(elementRole) ? attribute(element, "AXPlaceholderValue") : label
                let decision = listing(
                    role: elementRole, label: name, identifier: identifier, value: value,
                    interactive: interactiveRoles.contains(elementRole), hasActions: !customActions(element).isEmpty,
                    isLeaf: children(element).isEmpty
                )
                guard decision.listed else { return nil }
                var key = [elementRole, label, identifier, value]
                // Unnamed elements are told apart by where they sit on their screen.
                let elementFrame = frame(element)
                if decision.unlabeled, let elementFrame, let rootFrame {
                    key.append("\(deviceFrame(elementFrame, screen: rootFrame, devicePoints: nil))")
                }
                guard seen.insert(key.joined(separator: "\u{1F}")).inserted else { return nil }
                return ScreenElement(element: element, root: root, rootFrame: rootFrame, frame: elementFrame, unlabeled: decision.unlabeled)
            }
        }
    }

    /// The elements on the device's screens, as `ax screen` lists them.
    var screenElements: [AXUIElement] { screenEntries.map(\.element) }

    var dictionary: [String: Any] { ["title": title, "device": deviceIdentifier ?? NSNull()] }
}

/// An element on the device's screen, with the screen it sits on.
struct ScreenElement {
    let element: AXUIElement
    let root: AXUIElement
    let rootFrame: CGRect?
    let frame: CGRect?
    let unlabeled: Bool
}

private let deviceRowPrefix = "TableRow.Device."

func deviceWindows(in application: AXUIElement) -> [DeviceWindow] {
    children(application).filter { role($0) == kAXWindowRole }.compactMap { window in
        let nodes = descendants(of: window).map(\.element)
        guard let screenshotButton = nodes.first(where: { role($0) == kAXButtonRole && attribute($0, kAXDescriptionAttribute) == "Screenshot" }),
              let controlsGroup = parent(screenshotButton) else { return nil }
        let selectedRow = nodes.first { role($0) == kAXRowRole && isSelected($0) }
        let deviceIdentifier = selectedRow.flatMap { row in
            descendants(of: row).lazy.map { attribute($0.element, "AXIdentifier") }.first { $0.hasPrefix(deviceRowPrefix) }
        }.map { String($0.dropFirst(deviceRowPrefix.count)) }
        return DeviceWindow(element: window, title: attribute(window, kAXTitleAttribute), deviceIdentifier: deviceIdentifier, controlsGroup: controlsGroup)
    }
}

let noWindowHint = "Run `open -a DeviceHub`, select the simulator and keep its window on screen. A minimised window, a window on another Space, or a locked Mac hides it from accessibility."

/// Picks the window for `simulator`, or the only window when no simulator was named. A simulator named with
/// --device that no window shows is selected in a window's sidebar first.
func chooseWindow(in application: AXUIElement, simulator: Simulator?, simulatorRequested: Bool) throws -> DeviceWindow {
    let windows = deviceWindows(in: application)
    if let simulator {
        if let match = windows.first(where: { $0.deviceIdentifier == simulator.identifier }) { return match }
        let byName = windows.filter { $0.deviceIdentifier == nil && windowTitle($0.title, names: simulator.name) }
        if byName.count == 1 { return byName[0] }
        if simulatorRequested { return try select(simulator, in: application) }
    }
    guard !windows.isEmpty else {
        throw Failure(.deviceHubUnavailable, "no_device_window", "Device Hub has no visible device window.", hint: noWindowHint)
    }
    if windows.count == 1 { return windows[0] }
    throw Failure(
        .usage, "ambiguous_window",
        "Device Hub has \(windows.count) device windows open.",
        hint: "Pass --device with a UDID from `ax state` or `xcrun simctl list devices booted`.",
        details: ["windows": windows.map(\.dictionary)]
    )
}

/// True when a window title such as "iPhone 17 – iOS 27.2" names this device: the name, then the runtime.
/// "iPhone 17" does not name the "iPhone 17e – iOS 27.2" window.
func windowTitle(_ title: String, names device: String) -> Bool {
    guard title.hasPrefix(device) else { return false }
    let rest = title.dropFirst(device.count)
    return rest.isEmpty || rest.hasPrefix(" ")
}

/// The sidebar row of the device with this UDID, in any Device Hub window that shows its sidebar.
func deviceRows(in application: AXUIElement, identifier: String) -> [(window: AXUIElement, row: AXUIElement)] {
    children(application).filter { role($0) == kAXWindowRole }.flatMap { window in
        descendants(of: window).map(\.element).filter { element in
            role(element) == kAXRowRole
                && descendants(of: element, maxDepth: 3).contains { attribute($0.element, "AXIdentifier") == deviceRowPrefix + identifier }
        }.map { (window, $0) }
    }
}

/// Selects `simulator` in a Device Hub window's sidebar, then waits until that window shows its screen.
/// A window already showing a device is preferred, so its controls and screen are the ones that change.
func select(_ simulator: Simulator, in application: AXUIElement, timeout: Double = 8) throws -> DeviceWindow {
    let rows = deviceRows(in: application, identifier: simulator.identifier)
    let deviceWindowElements = deviceWindows(in: application).map(\.element)
    guard let target = rows.first(where: { row in deviceWindowElements.contains { CFEqual($0, row.window) } }) ?? rows.first else {
        throw Failure(
            .deviceHubUnavailable, "no_device_row",
            "No Device Hub sidebar lists \(simulator.name) (\(simulator.identifier)).",
            hint: "Show the sidebar (View > Show Sidebar) in a Device Hub window. " + noWindowHint
        )
    }
    if attribute(target.row, kAXSelectedAttribute) != "1" {
        var result = AXUIElementSetAttributeValue(target.row, kAXSelectedAttribute as CFString, kCFBooleanTrue)
        if result != .success, let outline = parent(target.row) {
            result = AXUIElementSetAttributeValue(outline, kAXSelectedRowsAttribute as CFString, [target.row] as CFArray)
        }
        guard result == .success else {
            throw Failure(.actionFailed, "select_failed", "Selecting \(simulator.name) in Device Hub's sidebar failed with AXError \(result.rawValue).", hint: "Click it in the sidebar, then run the command again.")
        }
    }
    let shown: DeviceWindow? = poll(timeout: timeout) {
        deviceWindows(in: application).first { $0.deviceIdentifier == simulator.identifier && !$0.screenRoots.isEmpty }
    }
    guard let shown else {
        throw Failure(
            .actionFailed, "select_not_confirmed",
            "Selected \(simulator.name) in Device Hub's sidebar, but its screen did not show within \(timeout) s.",
            hint: "Check that it is booted (`xcrun simctl list devices booted`) and that the Device Hub window is on screen."
        )
    }
    return shown
}
