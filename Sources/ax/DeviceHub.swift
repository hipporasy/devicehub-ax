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

    /// Every named element on the device's screens. Device Hub can expose the same screen twice, so repeats are dropped,
    /// and so are unnamed containers.
    var screenElements: [AXUIElement] {
        var seen = Set<String>()
        return screenRoots.flatMap { descendants(of: $0).dropFirst().map(\.element) }.filter { element in
            let fields = [displayLabel(element), attribute(element, "AXIdentifier"), attribute(element, kAXValueAttribute)]
            guard fields.contains(where: { !$0.isEmpty }) else { return false }
            return seen.insert(([role(element)] + fields).joined(separator: "\u{1F}")).inserted
        }
    }

    var dictionary: [String: Any] { ["title": title, "device": deviceIdentifier ?? NSNull()] }
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

/// Picks the window for `simulator`, or the only window when no simulator was named.
func chooseWindow(in application: AXUIElement, simulator: Simulator?, simulatorRequested: Bool) throws -> DeviceWindow {
    let windows = deviceWindows(in: application)
    guard !windows.isEmpty else {
        throw Failure(.deviceHubUnavailable, "no_device_window", "Device Hub has no visible device window.", hint: noWindowHint)
    }
    if let simulator {
        if let match = windows.first(where: { $0.deviceIdentifier == simulator.identifier }) { return match }
        let byName = windows.filter { $0.title.hasPrefix(simulator.name) }
        if byName.count == 1 { return byName[0] }
        if simulatorRequested {
            throw Failure(
                .deviceHubUnavailable, "no_device_window",
                "No Device Hub window shows \(simulator.name) (\(simulator.identifier)).",
                hint: "Select it in a Device Hub window's sidebar. " + noWindowHint,
                details: ["windows": windows.map(\.dictionary)]
            )
        }
    }
    if windows.count == 1 { return windows[0] }
    throw Failure(
        .usage, "ambiguous_window",
        "Device Hub has \(windows.count) device windows open.",
        hint: "Pass --device with a UDID from `ax state` or `xcrun simctl list devices booted`.",
        details: ["windows": windows.map(\.dictionary)]
    )
}
