import AppKit
import ApplicationServices
import Darwin

let version = "0.2.0"

let usage = """
Usage: ax <command> [options]

Drives Xcode's Device Hub and the app on the simulator through the accessibility API.

Device:
  doctor                    Check access, Device Hub, its windows and booted simulators
  state                     Device, pose, active display and orientation
  pose closed|partial|open  Fold or unfold an iPhone Duo, then wait until the matching display is on
  rotate [TIMES]            Press Rotate Right, then wait until the orientation changes
  screenshot PATH           Capture the active display with no alpha channel (.jpg or .png)
  controls                  List the Device Hub buttons under the device
  control LABEL             Press one of them, e.g. Home, Screenshot, Record

App on the simulator:
  screen                    List the elements on the device's screen
  tap LABEL                 Press an element on the screen by its label or identifier
  wait LABEL                Wait until an element is on the screen (--gone: until it is not)

Any app:
  list                      Print the whole accessibility tree
  press LABEL               Press the first button or radio button with this label anywhere in the app

Options:
  --json            Print one JSON object; failures print {"ok": false, "error": ..., "hint": ...}
  --device UDID     Simulator UDID or name (default: the only booted simulator)
  --timeout SECS    How long to wait for an element or state (tap, control, press: 2; others: 10)
  --contains        Match labels by case-insensitive substring instead of exactly
  --role ROLES      Only match these roles, separated by |, e.g. AXRadio or Button|Radio
  --display WHICH   screenshot: active (default), inner, outer or a display id
  --no-verify       pose and rotate: do not wait for the device to confirm
  --app NAME        list and press: app name or bundle identifier (default: DeviceHub)
  --pid PID         list and press: process identifier, instead of --app
  --version         Print the version

Exit codes: 0 done, 1 nothing matched, 2 usage, 3 no Accessibility access,
4 Device Hub, window or simulator missing, 5 action failed or not confirmed,
6 simctl or devicectl failed.
"""

struct Options {
    var command = ""
    var arguments: [String] = []
    var appName = deviceHubExecutable
    var processIdentifier: pid_t?
    var roles: [String]?
    var device: String?
    var timeout: Double?
    var display = "active"
    var contains = false
    var gone = false
    var verify = true
}

func parseOptions() throws -> Options {
    var options = Options()
    var arguments = Array(CommandLine.arguments.dropFirst())
    func value(for flag: String) throws -> String {
        guard let value = arguments.first else { throw Failure(.usage, "usage", "\(flag) needs a value") }
        arguments.removeFirst()
        return value
    }
    while let argument = arguments.first {
        arguments.removeFirst()
        switch argument {
        case "--json": jsonOutput = true
        case "--contains": options.contains = true
        case "--gone": options.gone = true
        case "--no-verify": options.verify = false
        case "--app": options.appName = try value(for: argument)
        case "--device": options.device = try value(for: argument)
        case "--display": options.display = try value(for: argument)
        case "--role": options.roles = try value(for: argument).split(separator: "|").map(String.init)
        case "--pid":
            guard let processIdentifier = pid_t(try value(for: argument)) else { throw Failure(.usage, "usage", "--pid needs a number") }
            options.processIdentifier = processIdentifier
        case "--timeout", "--wait":
            guard let timeout = Double(try value(for: argument)), timeout >= 0 else { throw Failure(.usage, "usage", "--timeout needs a number of seconds") }
            options.timeout = timeout
        case "-h", "--help": options.command = "help"
        case "--version": options.command = "version"
        default:
            if argument.hasPrefix("--") { throw Failure(.usage, "usage", "Unknown option \(argument)", hint: "Run `ax --help`.") }
            if options.command.isEmpty { options.command = argument } else { options.arguments.append(argument) }
        }
    }
    return options
}

func requireArgument(_ options: Options, _ name: String) throws -> String {
    guard let argument = options.arguments.first, !argument.isEmpty else {
        throw Failure(.usage, "usage", "\(options.command) needs \(name)", hint: "Run `ax --help`.")
    }
    return argument
}

func notFound(_ matcher: Matcher, in scope: String, among elements: [AXUIElement], timeout: Double) -> Failure {
    let candidates = suggestions(for: matcher.label, among: elements)
    return Failure(
        .notFound, "not_found",
        "Nothing on the \(scope) matched \"\(matcher.label)\"" + (matcher.roles.map { " with roles \($0.joined(separator: "|"))" } ?? "") + " within \(timeout) s.",
        hint: candidates.isEmpty ? "Run `ax \(scope == "screen" ? "screen" : "list")` to see what is there." : "Labels there include: " + candidates.map { "\"\($0)\"" }.joined(separator: ", "),
        details: ["candidates": candidates]
    )
}

/// Waits for a pressable, enabled element that `matcher` accepts among `candidates()`, then presses it.
/// With `unique`, buttons and tabs win over static text, and two different elements matching is an error rather than a guess.
func pressFirst(_ matcher: Matcher, in scope: String, timeout: Double, unique: Bool = false, candidates: () throws -> [AXUIElement]) throws -> AXUIElement {
    var lastCandidates: [AXUIElement] = []
    var disabledMatch: AXUIElement?
    var ambiguous: [AXUIElement] = []
    let found: AXUIElement? = try poll(timeout: timeout) {
        lastCandidates = try candidates().filter(isPressable)
        var matches = lastCandidates.filter(matcher.matches)
        disabledMatch = matches.first
        if unique {
            if matches.contains(where: isInteractive) { matches = matches.filter(isInteractive) }
            var seen = Set<String>()
            ambiguous = matches.filter { seen.insert(role($0) + "\u{1F}" + displayLabel($0)).inserted }
            if ambiguous.count > 1 { return nil }
        }
        return matches.first(where: isEnabled)
    }
    if found == nil, ambiguous.count > 1 {
        throw Failure(
            .usage, "ambiguous",
            "\(ambiguous.count) different elements match \"\(matcher.label)\": " + ambiguous.map { "\(role($0)) \"\(displayLabel($0))\"" }.joined(separator: ", ") + ".",
            hint: "Use the exact label, or narrow it with --role (e.g. --role AXRadio for a tab).",
            details: ["matches": ambiguous.map(summary)]
        )
    }
    guard let found else {
        if let disabledMatch {
            throw Failure(.actionFailed, "disabled", "\(role(disabledMatch)) \"\(displayLabel(disabledMatch))\" is disabled.", details: ["element": summary(disabledMatch)])
        }
        throw notFound(matcher, in: scope, among: lastCandidates, timeout: timeout)
    }
    try press(found)
    return found
}

func matcher(_ options: Options, label: String) -> Matcher {
    Matcher(label: label, contains: options.contains, roles: options.roles)
}

struct DeviceHubSession {
    let application: AXUIElement
    let simulator: Simulator?
    let simulatorRequested: Bool

    init(_ options: Options) throws {
        try requireAccessibility()
        application = try applicationElement(appName: deviceHubExecutable, processIdentifier: nil)
        simulator = try resolveSimulator(options.device)
        simulatorRequested = options.device != nil
    }

    func window() throws -> DeviceWindow {
        try chooseWindow(in: application, simulator: simulator, simulatorRequested: simulatorRequested)
    }

    func control(_ label: String) throws -> AXUIElement {
        let window = try window()
        guard let button = window.controls.first(where: { labels($0).contains(label) }) else {
            throw Failure(
                .notFound, "not_found", "The \(window.title) window has no \(label) button.",
                hint: "Buttons there: " + window.controls.map(displayLabel).joined(separator: ", ") + ". Poses only exist on foldable devices such as iPhone Duo.",
                details: ["candidates": window.controls.map(displayLabel)]
            )
        }
        return button
    }
}

// MARK: - Commands

func runList(_ options: Options) throws {
    try requireAccessibility()
    let application = try applicationElement(appName: options.appName, processIdentifier: options.processIdentifier)
    let nodes = descendants(of: application).filter { node in
        options.roles.map { roles in roles.contains { role(node.element).contains($0) } } ?? true
    }
    if jsonOutput {
        emit(["elements": nodes.map { node -> [String: Any] in
            var entry = summary(node.element)
            entry["depth"] = node.depth
            entry["title"] = attribute(node.element, kAXTitleAttribute)
            entry["description"] = attribute(node.element, kAXDescriptionAttribute)
            entry["help"] = attribute(node.element, kAXHelpAttribute)
            return entry
        }], text: "")
        return
    }
    for node in nodes {
        let element = node.element
        let fields = [role(element), attribute(element, kAXTitleAttribute), attribute(element, kAXDescriptionAttribute), attribute(element, "AXIdentifier"), attribute(element, kAXHelpAttribute)]
        let state = [attribute(element, kAXValueAttribute), attribute(element, kAXSelectedAttribute), attribute(element, kAXEnabledAttribute)]
        print(String(repeating: "  ", count: node.depth) + fields.joined(separator: " | ") + " | " + state.joined(separator: " "))
    }
}

func runPress(_ options: Options) throws {
    let label = try requireArgument(options, "a LABEL")
    try requireAccessibility()
    let application = try applicationElement(appName: options.appName, processIdentifier: options.processIdentifier)
    var rule = matcher(options, label: label)
    rule.roles = options.roles ?? ["Button", "Radio"]
    let timeout = options.timeout ?? 2
    let element = try pressFirst(rule, in: options.appName == deviceHubExecutable ? "Device Hub" : options.appName, timeout: timeout) {
        descendants(of: application).map(\.element)
    }
    emit(["pressed": summary(element)], text: "pressed \(role(element)) \"\(label)\"")
}

func runTap(_ options: Options) throws {
    let label = try requireArgument(options, "a LABEL")
    let session = try DeviceHubSession(options)
    var window: DeviceWindow?
    let element = try pressFirst(matcher(options, label: label), in: "screen", timeout: options.timeout ?? 2, unique: true) {
        window = try session.window()
        return window!.screenElements
    }
    emit(["pressed": summary(element), "window": window?.dictionary ?? [:]], text: "tapped \(role(element)) \"\(displayLabel(element))\"")
}

func runWait(_ options: Options) throws {
    let label = try requireArgument(options, "a LABEL")
    let session = try DeviceHubSession(options)
    let rule = matcher(options, label: label)
    let timeout = options.timeout ?? 10
    var lastElements: [AXUIElement] = []
    let result: [String: Any]? = try poll(timeout: timeout) {
        lastElements = try session.window().screenElements
        let match = lastElements.first(where: rule.matches)
        if options.gone { return match == nil ? ["gone": true] : nil }
        return match.map { ["found": summary($0)] }
    }
    guard let result else {
        if options.gone {
            throw Failure(.actionFailed, "still_present", "\"\(label)\" is still on the screen after \(timeout) s.")
        }
        throw notFound(rule, in: "screen", among: lastElements, timeout: timeout)
    }
    emit(result, text: options.gone ? "\"\(label)\" is gone" : "found \"\(label)\"")
}

func runScreen(_ options: Options) throws {
    let window = try DeviceHubSession(options).window()
    let elements = window.screenElements.filter { element in
        options.roles.map { roles in roles.contains { role(element).contains($0) } } ?? true
    }
    guard !elements.isEmpty || !jsonOutput else {
        emit(["window": window.dictionary, "elements": []], text: "")
        return
    }
    if elements.isEmpty {
        warn("The screen tree is empty. Wait for the app to finish launching, or bring the Device Hub window forward.")
    }
    emit(["window": window.dictionary, "elements": elements.map(summary)], text: elements.map { element in
        var flags: [String] = []
        if isSelected(element) { flags.append("selected") }
        if !isEnabled(element) { flags.append("disabled") }
        return [role(element), displayLabel(element), attribute(element, "AXIdentifier"), attribute(element, kAXValueAttribute), flags.joined(separator: ",")].joined(separator: " | ")
    }.joined(separator: "\n"))
}

func runControls(_ options: Options) throws {
    let window = try DeviceHubSession(options).window()
    let names = window.controls.map(displayLabel)
    emit(["window": window.dictionary, "controls": names], text: names.joined(separator: "\n"))
}

func runControl(_ options: Options) throws {
    let label = try requireArgument(options, "a LABEL")
    let session = try DeviceHubSession(options)
    let button = try poll(timeout: options.timeout ?? 2) { try? session.control(label) } ?? session.control(label)
    try press(button)
    emit(["pressed": summary(button)], text: "pressed \"\(displayLabel(button))\"")
}

func activeDisplay(_ list: [Display]) -> Display? {
    list.first(where: \.isOn) ?? list.first(where: \.active)
}

func runPose(_ options: Options) throws {
    let poses = ["closed": "Closed", "partial": "Partially Open", "open": "Open"]
    let name = try requireArgument(options, "closed, partial or open").lowercased()
    guard let label = poses[name] else { throw Failure(.usage, "usage", "pose needs closed, partial or open") }
    let session = try DeviceHubSession(options)
    try press(try session.control(label))

    guard options.verify else {
        emit(["pose": name, "verified": false], text: "pressed \(label)")
        return
    }
    guard let simulator = session.simulator else {
        warn("Several simulators are booted, so the pose was not confirmed. Pass --device to confirm it.")
        emit(["pose": name, "verified": false], text: "pressed \(label) (not confirmed)")
        return
    }
    let position = name == "closed" ? "outer" : "inner"
    let timeout = options.timeout ?? 10
    let reached: [Display]? = try poll(timeout: timeout) {
        let list = try displays(of: simulator)
        return list.first(where: { $0.position == position })?.isOn == true ? list : nil
    }
    guard let reached, let display = reached.first(where: { $0.position == position }) else {
        throw Failure(
            .actionFailed, "pose_not_confirmed",
            "Pressed \(label), but the \(position) display did not turn on within \(timeout) s.",
            hint: "Run `ax state` to see the displays. Keep the Device Hub window on screen."
        )
    }
    // The newly active display needs a moment before screenshots stop coming out black.
    Thread.sleep(forTimeInterval: 1)
    emit(["pose": name, "verified": true, "device": simulator.dictionary, "activeDisplay": display.dictionary],
         text: "pose \(name): \(position) display \(display.identifier) is on")
}

func runRotate(_ options: Options) throws {
    guard let times = Int(options.arguments.first ?? "1"), times > 0 else { throw Failure(.usage, "usage", "rotate takes a positive number of quarter turns") }
    let session = try DeviceHubSession(options)
    let button = try session.control("Rotate Right")
    guard options.verify, let simulator = session.simulator else {
        for turn in 0..<times {
            if turn > 0 { Thread.sleep(forTimeInterval: 0.6) }
            try press(button)
        }
        emit(["turns": times, "verified": false], text: "pressed Rotate Right \(times)×")
        return
    }
    // Each quarter turn is confirmed before the next press. Device Hub sometimes drops a press
    // while a pose change settles, so an unconfirmed press is retried once.
    let before = try displayInfo(of: simulator).orientation
    var current = before
    let timeout = options.timeout ?? 10
    for _ in 0..<times {
        var changed: String?
        for _ in 0..<2 where changed == nil {
            try press(button)
            changed = try poll(timeout: timeout / 2) {
                let orientation = try displayInfo(of: simulator).orientation
                return orientation != current ? orientation : nil
            }
        }
        guard let changed else {
            throw Failure(.actionFailed, "rotation_not_confirmed", "Pressed Rotate Right twice, but the device stayed \(current) for \(timeout) s.",
                          hint: "Run `ax state`. Keep the Device Hub window on screen.")
        }
        current = changed
    }
    let active = activeDisplay(try displays(of: simulator))
    emit(["turns": times, "verified": true, "orientation": current, "activeDisplay": active?.dictionary ?? NSNull()],
         text: "rotated \(times)×: \(before) to \(current)")
}

func pose(of list: [Display]) -> String {
    guard list.count > 1 else { return "n/a" }
    if list.first(where: { $0.position == "outer" })?.isOn == true { return "closed" }
    if list.first(where: { $0.position == "inner" })?.isOn == true { return "unfolded" }
    return "off"
}

func runState(_ options: Options) throws {
    let simulator = try requireSimulator(options.device)
    let (list, orientation) = try displayInfo(of: simulator)
    var payload: [String: Any] = [
        "device": simulator.dictionary,
        "foldable": list.count > 1,
        "pose": pose(of: list),
        "orientation": orientation,
        "displays": list.map(\.dictionary),
        "activeDisplay": activeDisplay(list)?.dictionary ?? NSNull(),
    ]
    if AXIsProcessTrusted(),
       let application = try? applicationElement(appName: deviceHubExecutable, processIdentifier: nil),
       let window = try? chooseWindow(in: application, simulator: simulator, simulatorRequested: true) {
        payload["window"] = window.dictionary
    }
    let lines = ["\(simulator.name) \(simulator.runtime) \(simulator.identifier)", "pose: \(pose(of: list))", "orientation: \(orientation)"]
        + list.map { "display \($0.identifier) \($0.position): \($0.width)x\($0.height) \($0.orientation) \($0.isOn ? "on" : "off")" }
    emit(payload, text: lines.joined(separator: "\n"))
}

func runScreenshot(_ options: Options) throws {
    let path = try requireArgument(options, "a PATH")
    let simulator = try requireSimulator(options.device)
    let list = try displays(of: simulator)
    let display: Display?
    switch options.display {
    case "active": display = activeDisplay(list) ?? list.first(where: \.primary)
    case "inner", "outer", "main": display = list.first { $0.position == options.display }
    default: display = Int(options.display).flatMap { id in list.first { $0.identifier == id } }
    }
    guard let display else {
        throw Failure(.usage, "unknown_display", "No \(options.display) display on \(simulator.name).", details: ["displays": list.map(\.dictionary)])
    }
    var payload: [String: Any] = [:]
    if !display.isOn {
        let warning = "Display \(display.identifier) (\(display.position)) is off, so the image is probably black."
        warn(warning)
        payload["warning"] = warning
    }
    let destination = URL(fileURLWithPath: path)
    let size = try screenshot(simulator, display: display, to: destination)
    payload.merge(["path": destination.standardizedFileURL.path, "width": size.width, "height": size.height, "display": display.dictionary, "device": simulator.dictionary]) { $1 }
    emit(payload, text: "wrote \(destination.path) (\(size.width)x\(size.height), \(display.position) display)")
}

func runDoctor() throws {
    var checks: [[String: Any]] = []
    var exitCode = ExitCode.success
    func check(_ name: String, _ ok: Bool, _ detail: String, fix: String? = nil, code: ExitCode = .deviceHubUnavailable) {
        var entry: [String: Any] = ["name": name, "ok": ok, "detail": detail]
        if let fix, !ok { entry["fix"] = fix }
        checks.append(entry)
        if !ok, exitCode == .success { exitCode = code }
    }

    let xcode = (try? xcrun(["xcodebuild", "-version"])).map { String(decoding: $0, as: UTF8.self).replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces) }
    check("xcode", xcode != nil, xcode ?? "xcodebuild not found", fix: "Install Xcode 27.1 or later and run `xcode-select -s /Applications/Xcode.app`.")

    let trusted = AXIsProcessTrusted()
    check("accessibility", trusted, trusted ? "granted" : "not granted to this terminal",
          fix: "Ask the user to enable this terminal app in System Settings > Privacy & Security > Accessibility.", code: .accessibilityDenied)

    let deviceHub = processIdentifier(executableName: deviceHubExecutable)
    check("devicehub", deviceHub != nil, deviceHub.map { "running, pid \($0)" } ?? "not running", fix: "Run `open -a DeviceHub`.")

    if trusted, deviceHub != nil, let application = try? applicationElement(appName: deviceHubExecutable, processIdentifier: nil) {
        let windows = deviceWindows(in: application)
        check("windows", !windows.isEmpty, windows.isEmpty ? "no visible device window" : windows.map { "\($0.title) [\($0.deviceIdentifier ?? "sidebar hidden")]" }.joined(separator: "; "),
              fix: noWindowHint)
    }

    let booted = (try? bootedSimulators()) ?? []
    check("simulators", !booted.isEmpty, booted.isEmpty ? "none booted" : booted.map { "\($0.name) \($0.runtime) \($0.identifier)" }.joined(separator: "; "),
          fix: "Boot one with `xcrun simctl boot <udid>` or from Device Hub.")

    if jsonOutput {
        print(jsonString(["ok": exitCode == .success, "version": version, "checks": checks]))
    } else {
        for entry in checks {
            let ok = entry["ok"] as? Bool ?? false
            print("\(ok ? "ok  " : "FAIL") \(entry["name"]!): \(entry["detail"]!)" + ((entry["fix"] as? String).map { "\n     fix: \($0)" } ?? ""))
        }
    }
    exit(exitCode.rawValue)
}

func run(_ options: Options) throws {
    switch options.command {
    case "list": try runList(options)
    case "press": try runPress(options)
    case "tap": try runTap(options)
    case "wait": try runWait(options)
    case "screen": try runScreen(options)
    case "controls": try runControls(options)
    case "control": try runControl(options)
    case "pose": try runPose(options)
    case "rotate": try runRotate(options)
    case "state": try runState(options)
    case "screenshot": try runScreenshot(options)
    case "doctor": try runDoctor()
    case "version": emit(["version": version], text: version)
    case "help": print(usage)
    case "": throw Failure(.usage, "usage", usage)
    default: throw Failure(.usage, "usage", "Unknown command: \(options.command)", hint: "Run `ax --help`.")
    }
}

do {
    try run(try parseOptions())
} catch let failure as Failure {
    finish(with: failure)
} catch {
    finish(with: Failure(.actionFailed, "unexpected", "\(error)"))
}
