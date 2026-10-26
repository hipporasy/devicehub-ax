import AppKit
import ApplicationServices
import Darwin

func attribute(_ element: AXUIElement, _ name: String) -> String {
    var value: CFTypeRef?
    AXUIElementCopyAttributeValue(element, name as CFString, &value)
    return value.map { "\($0)" } ?? ""
}

func children(_ element: AXUIElement) -> [AXUIElement] {
    var value: CFTypeRef?
    AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value)
    return value as? [AXUIElement] ?? []
}

func parent(_ element: AXUIElement) -> AXUIElement? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &value) == .success,
          let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return (value as! AXUIElement)
}

func actionNames(_ element: AXUIElement) -> [String] {
    var names: CFArray?
    AXUIElementCopyActionNames(element, &names)
    return names as? [String] ?? []
}

func role(_ element: AXUIElement) -> String { attribute(element, kAXRoleAttribute) }
func isEnabled(_ element: AXUIElement) -> Bool { attribute(element, kAXEnabledAttribute) != "0" }
func isSelected(_ element: AXUIElement) -> Bool { attribute(element, kAXSelectedAttribute) == "1" }
func isPressable(_ element: AXUIElement) -> Bool { actionNames(element).contains(kAXPressAction) }

/// The attributes a LABEL is matched against.
func labels(_ element: AXUIElement) -> [String] {
    [kAXTitleAttribute, kAXDescriptionAttribute, "AXIdentifier", kAXHelpAttribute].map { attribute(element, $0) }
}

/// The name a person would read: description first, as SwiftUI and Device Hub put labels there.
func displayLabel(_ element: AXUIElement) -> String {
    [kAXDescriptionAttribute, kAXTitleAttribute, kAXHelpAttribute].map { attribute(element, $0) }.first { !$0.isEmpty } ?? ""
}

func summary(_ element: AXUIElement) -> [String: Any] {
    [
        "role": role(element),
        "label": displayLabel(element),
        "identifier": attribute(element, "AXIdentifier"),
        "value": attribute(element, kAXValueAttribute),
        "selected": isSelected(element),
        "enabled": isEnabled(element),
        "pressable": isPressable(element),
    ]
}

func descendants(of root: AXUIElement, depth: Int = 0, maxDepth: Int = 25) -> [(element: AXUIElement, depth: Int)] {
    var result = [(element: root, depth: depth)]
    guard depth < maxDepth else { return result }
    for child in children(root) { result += descendants(of: child, depth: depth + 1, maxDepth: maxDepth) }
    return result
}

struct Matcher {
    let label: String
    var contains = false
    var roles: [String]?

    func matches(_ element: AXUIElement) -> Bool {
        if let roles {
            let elementRole = role(element)
            guard roles.contains(where: { elementRole.contains($0) }) else { return false }
        }
        let values = labels(element).filter { !$0.isEmpty }
        return contains ? values.contains { $0.localizedCaseInsensitiveContains(label) } : values.contains(label)
    }
}

/// Labels on screen, closest to the one asked for first, so a failed press tells the caller what to try next.
func suggestions(for label: String, among elements: [AXUIElement]) -> [String] {
    var seen = Set<String>()
    let names = elements.map(displayLabel).filter { !$0.isEmpty && seen.insert($0).inserted }
    let target = label.lowercased()
    func distance(_ name: String) -> Int {
        let candidate = name.lowercased()
        if candidate.contains(target) || target.contains(candidate) { return 0 }
        return editDistance(Array(candidate), Array(target))
    }
    return Array(names.map { ($0, distance($0)) }.sorted { $0.1 < $1.1 }.prefix(10).map(\.0))
}

func editDistance(_ first: [Character], _ second: [Character]) -> Int {
    var previous = Array(0...second.count)
    for (row, character) in first.enumerated() {
        var current = [row + 1]
        for (column, other) in second.enumerated() {
            current.append(min(previous[column + 1] + 1, current[column] + 1, previous[column] + (character == other ? 0 : 1)))
        }
        previous = current
    }
    return previous[second.count]
}

/// Roles a person taps on purpose. Device Hub gives every screen element a press action, even static text.
private let interactiveRoles: Set<String> = [
    kAXButtonRole, kAXRadioButtonRole, kAXCheckBoxRole, kAXMenuItemRole, kAXPopUpButtonRole, kAXTextFieldRole, "AXLink", "AXSwitch", "AXToggle",
]

func isInteractive(_ element: AXUIElement) -> Bool { interactiveRoles.contains(role(element)) }

func press(_ element: AXUIElement) throws {
    let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
    guard result == .success else {
        throw Failure(.actionFailed, "press_failed", "Pressing \(role(element)) \"\(displayLabel(element))\" failed with AXError \(result.rawValue).")
    }
}

func requireAccessibility(prompt: Bool = true) throws {
    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
    guard AXIsProcessTrustedWithOptions(options) else {
        throw Failure(
            .accessibilityDenied, "accessibility_denied",
            "This terminal needs Accessibility access.",
            hint: "Ask the user to enable it for this terminal app in System Settings > Privacy & Security > Accessibility, then run the command again."
        )
    }
}

/// Device Hub reports a process identifier of -1 to NSWorkspace, so the process table is searched first.
func processIdentifier(executableName: String) -> pid_t? {
    let count = proc_listallpids(nil, 0)
    guard count > 0 else { return nil }
    var identifiers = [pid_t](repeating: 0, count: Int(count) * 2)
    let filled = proc_listallpids(&identifiers, Int32(identifiers.count * MemoryLayout<pid_t>.size))
    var name = [CChar](repeating: 0, count: 1024)
    for identifier in identifiers.prefix(Int(filled)) where identifier > 0 {
        guard proc_name(identifier, &name, UInt32(name.count)) > 0 else { continue }
        if String(cString: name) == executableName { return identifier }
    }
    return nil
}

func resolveProcessIdentifier(appName: String, processIdentifier requested: pid_t?) throws -> pid_t {
    if let requested { return requested }
    if let identifier = processIdentifier(executableName: appName) { return identifier }
    let match = NSWorkspace.shared.runningApplications.first { application in
        application.processIdentifier > 0
            && (application.localizedName == appName || application.bundleIdentifier == appName)
    }
    guard let match else {
        let hint = appName == deviceHubExecutable ? "Run `open -a DeviceHub` and boot a simulator." : "Open it first, or pass --pid."
        throw Failure(.deviceHubUnavailable, "app_not_running", "No running app named \(appName).", hint: hint)
    }
    return match.processIdentifier
}

func applicationElement(appName: String, processIdentifier: pid_t?) throws -> AXUIElement {
    let application = AXUIElementCreateApplication(try resolveProcessIdentifier(appName: appName, processIdentifier: processIdentifier))
    AXUIElementSetMessagingTimeout(application, 5)
    var value: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(application, kAXRoleAttribute as CFString, &value)
    if result == .cannotComplete {
        throw Failure(
            .deviceHubUnavailable, "app_not_responding",
            "\(appName) is not answering accessibility requests.",
            hint: "Quit and reopen it. For Device Hub, boot the simulator again afterwards."
        )
    }
    return application
}
