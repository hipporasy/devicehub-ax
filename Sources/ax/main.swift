import AppKit
import ApplicationServices
import Darwin

let usage = """
Usage:
  ax list [--app NAME | --pid PID] [--role ROLES]
  ax press LABEL [--app NAME | --pid PID] [--role ROLES]
  ax pose closed|partial|open [--app NAME | --pid PID]

Reads or presses accessibility elements in a running macOS app. Defaults to
Xcode's Device Hub, so `ax pose open` unfolds an iPhone Duo simulator.

  list    Print the accessibility tree: role | title | description | identifier | help | value selected enabled
  press   Press the first button or radio button whose title, description,
          identifier or help equals LABEL
  pose    Press Device Hub's Closed, Partially Open or Open button

Options:
  --app NAME    App name or bundle identifier (default: DeviceHub)
  --pid PID     Process identifier, instead of --app
  --role ROLES  Roles to match when pressing, separated by | (default: Button|Radio).
                Use AXRadio to pick an app's tab over a Device Hub button with the same label.
"""

struct Options {
    var command = ""
    var label: String?
    var appName = "DeviceHub"
    var processIdentifier: pid_t?
    var roles = ["Button", "Radio"]
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func parseOptions() -> Options {
    var options = Options()
    var arguments = Array(CommandLine.arguments.dropFirst())
    guard let command = arguments.first else { fail(usage) }
    options.command = command
    arguments.removeFirst()
    while let argument = arguments.first {
        arguments.removeFirst()
        switch argument {
        case "--app":
            guard let value = arguments.first else { fail("--app needs a value") }
            options.appName = value
            arguments.removeFirst()
        case "--pid":
            guard let value = arguments.first, let processIdentifier = pid_t(value) else { fail("--pid needs a number") }
            options.processIdentifier = processIdentifier
            arguments.removeFirst()
        case "--role":
            guard let value = arguments.first else { fail("--role needs a value") }
            options.roles = value.split(separator: "|").map(String.init)
            arguments.removeFirst()
        case "-h", "--help":
            print(usage)
            exit(0)
        default:
            guard options.label == nil else { fail("Unexpected argument: \(argument)\n\n\(usage)") }
            options.label = argument
        }
    }
    return options
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

func resolveProcessIdentifier(_ options: Options) -> pid_t {
    if let processIdentifier = options.processIdentifier { return processIdentifier }
    if let processIdentifier = processIdentifier(executableName: options.appName) { return processIdentifier }
    let match = NSWorkspace.shared.runningApplications.first { application in
        application.processIdentifier > 0
            && (application.localizedName == options.appName || application.bundleIdentifier == options.appName)
    }
    guard let match else { fail("No running app named \(options.appName). Open it first, or pass --pid.") }
    return match.processIdentifier
}

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

func printTree(_ element: AXUIElement, depth: Int) {
    let fields = [
        attribute(element, kAXRoleAttribute),
        attribute(element, kAXTitleAttribute),
        attribute(element, kAXDescriptionAttribute),
        attribute(element, "AXIdentifier"),
        attribute(element, kAXHelpAttribute),
    ]
    let state = [attribute(element, kAXValueAttribute), attribute(element, "AXSelected"), attribute(element, kAXEnabledAttribute)]
    print(String(repeating: "  ", count: depth) + fields.joined(separator: " | ") + " | " + state.joined(separator: " "))
    guard depth < 25 else { return }
    for child in children(element) { printTree(child, depth: depth + 1) }
}

func findElement(in element: AXUIElement, label: String, roles: [String], depth: Int = 0) -> AXUIElement? {
    let role = attribute(element, kAXRoleAttribute)
    let labels = [kAXTitleAttribute, kAXDescriptionAttribute, "AXIdentifier", kAXHelpAttribute].map { attribute(element, $0) }
    if labels.contains(label), roles.contains(where: { role.contains($0) }) {
        return element
    }
    guard depth < 25 else { return nil }
    for child in children(element) {
        if let found = findElement(in: child, label: label, roles: roles, depth: depth + 1) { return found }
    }
    return nil
}

func press(_ label: String, in application: AXUIElement, roles: [String]) {
    guard let element = findElement(in: application, label: label, roles: roles) else {
        fail("Nothing matched \"\(label)\" with roles \(roles.joined(separator: "|")). Run `ax list` to see the labels.")
    }
    let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
    guard result == .success else { fail("Press failed with AXError \(result.rawValue)") }
    print("pressed \(attribute(element, kAXRoleAttribute)) \"\(label)\"")
}

let options = parseOptions()
let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
guard AXIsProcessTrustedWithOptions(prompt) else {
    fail("This terminal needs Accessibility access: System Settings > Privacy & Security > Accessibility.")
}
let application = AXUIElementCreateApplication(resolveProcessIdentifier(options))

switch options.command {
case "list":
    printTree(application, depth: 0)
case "press":
    guard let label = options.label else { fail("press needs a LABEL\n\n\(usage)") }
    press(label, in: application, roles: options.roles)
case "pose":
    let poses = ["closed": "Closed", "partial": "Partially Open", "open": "Open"]
    guard let name = options.label, let label = poses[name.lowercased()] else { fail("pose needs closed, partial or open") }
    press(label, in: application, roles: ["Button"])
case "-h", "--help", "help":
    print(usage)
default:
    fail("Unknown command: \(options.command)\n\n\(usage)")
}
