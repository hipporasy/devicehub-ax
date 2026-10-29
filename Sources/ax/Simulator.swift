import ApplicationServices
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct Simulator {
    let identifier: String
    let name: String
    let runtime: String

    var dictionary: [String: Any] { ["udid": identifier, "name": name, "runtime": runtime] }
}

struct Display {
    let identifier: Int
    let uniqueIdentifier: String
    let primary: Bool
    let active: Bool
    let backlight: String
    let width: Int
    let height: Int
    let orientation: String
    /// "outer" and "inner" on a foldable device, "main" otherwise.
    var position = "main"

    var isOn: Bool { active && backlight == "activeOn" }

    var dictionary: [String: Any] {
        [
            "id": identifier, "uniqueId": uniqueIdentifier, "position": position, "primary": primary,
            "active": active, "backlight": backlight, "width": width, "height": height, "orientation": orientation,
        ]
    }
}

/// Runs `xcrun` and returns its standard output, or throws with its standard error.
func xcrun(_ arguments: [String]) throws -> Data {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = arguments
    let output = Pipe()
    let errorFile = FileManager.default.temporaryDirectory.appendingPathComponent("ax-\(UUID().uuidString).log")
    FileManager.default.createFile(atPath: errorFile.path, contents: nil)
    defer { try? FileManager.default.removeItem(at: errorFile) }
    process.standardOutput = output
    process.standardError = try FileHandle(forWritingTo: errorFile)
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        let message = (try? String(contentsOf: errorFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        throw Failure(.simulatorToolFailed, "simulator_tool_failed", "`xcrun \(arguments.prefix(3).joined(separator: " "))` failed: \(message)")
    }
    return data
}

func bootedSimulators() throws -> [Simulator] {
    try parseBootedSimulators(try xcrun(["simctl", "list", "devices", "booted", "-j"]))
}

/// Parses `simctl list devices booted -j`. A device listed under two runtimes appears once.
func parseBootedSimulators(_ data: Data) throws -> [Simulator] {
    let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    let runtimes = root?["devices"] as? [String: [[String: Any]]] ?? [:]
    var seen = Set<String>()
    return runtimes.sorted { $0.key < $1.key }.flatMap { runtime, devices in
        devices.compactMap { device -> Simulator? in
            guard let identifier = device["udid"] as? String, device["state"] as? String == "Booted",
                  seen.insert(identifier).inserted else { return nil }
            return Simulator(identifier: identifier, name: device["name"] as? String ?? "", runtime: runtimeName(runtime))
        }
    }
}

/// "com.apple.CoreSimulator.SimRuntime.iOS-27-1" becomes "iOS 27.1".
func runtimeName(_ identifier: String) -> String {
    let parts = (identifier.components(separatedBy: ".").last ?? identifier).components(separatedBy: "-")
    guard let platform = parts.first, parts.count > 1 else { return identifier }
    return platform + " " + parts.dropFirst().joined(separator: ".")
}

/// The simulator named by --device (a UDID, a name or "booted"), else the only booted one,
/// else the one shown in Device Hub's only device window.
/// Returns nil when nothing was requested and the choice is not obvious.
func resolveSimulator(_ requested: String?, application: AXUIElement? = nil) throws -> Simulator? {
    let booted = try bootedSimulators()
    guard let requested, requested != "booted" else {
        if booted.count == 1 { return booted[0] }
        if requested == "booted" { throw ambiguousSimulator(booted) }
        return simulatorInOnlyWindow(among: booted, application: application)
    }
    let matches = booted.filter { $0.identifier.caseInsensitiveCompare(requested) == .orderedSame || $0.name == requested }
    if matches.count == 1 { return matches[0] }
    if matches.isEmpty {
        throw Failure(.usage, "unknown_device", "No booted simulator matches \"\(requested)\".", details: ["booted": booted.map(\.dictionary)])
    }
    throw ambiguousSimulator(matches)
}

/// With several simulators booted but one Device Hub device window open, that window's simulator is the one in use.
func simulatorInOnlyWindow(among booted: [Simulator], application: AXUIElement?) -> Simulator? {
    guard booted.count > 1, AXIsProcessTrusted() else { return nil }
    guard let application = application
            ?? processIdentifier(executableName: deviceHubExecutable).map(AXUIElementCreateApplication) else { return nil }
    let windows = deviceWindows(in: application)
    guard windows.count == 1, let identifier = windows[0].deviceIdentifier else { return nil }
    return booted.first { $0.identifier == identifier }
}

func requireSimulator(_ requested: String?) throws -> Simulator {
    if let simulator = try resolveSimulator(requested) { return simulator }
    throw ambiguousSimulator(try bootedSimulators())
}

func ambiguousSimulator(_ booted: [Simulator]) -> Failure {
    if booted.isEmpty {
        return Failure(.deviceHubUnavailable, "no_booted_simulator", "No simulator is booted.", hint: "Boot one with `xcrun simctl boot <udid>` or from Device Hub.")
    }
    return Failure(.usage, "ambiguous_device", "\(booted.count) simulators are booted.", hint: "Pass --device with one of their UDIDs.", details: ["booted": booted.map(\.dictionary)])
}

func displays(of simulator: Simulator) throws -> [Display] {
    try displayInfo(of: simulator).displays
}

/// The device's displays and its orientation (portrait, landscapeLeft, ...), as devicectl reports them.
func displayInfo(of simulator: Simulator) throws -> (displays: [Display], orientation: String) {
    try parseDisplayInfo(try xcrun(["devicectl", "device", "info", "displays", "--device", simulator.identifier, "--quiet", "--json-output", "-"]))
}

/// Parses `devicectl device info displays --json-output -`.
func parseDisplayInfo(_ data: Data) throws -> (displays: [Display], orientation: String) {
    let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    let info = root?["result"] as? [String: Any]
    let orientation = (info?["orientation"] as? [String: Any])?["currentDeviceOrientation"] as? String ?? ""
    let entries = info?["displays"] as? [[String: Any]] ?? []
    var result = entries.map { entry -> Display in
        let bounds = entry["bounds"] as? [[Int]] ?? []
        let size = bounds.count == 2 ? bounds[1] : [0, 0]
        return Display(
            identifier: entry["displayId"] as? Int ?? 0,
            uniqueIdentifier: entry["uniqueId"] as? String ?? "",
            primary: entry["primary"] as? Bool ?? false,
            active: entry["active"] as? Bool ?? false,
            backlight: entry["backlightState"] as? String ?? "",
            width: size.first ?? 0,
            height: size.last ?? 0,
            orientation: entry["currentOrientation"] as? String ?? ""
        )
    }
    if result.count > 1 {
        for index in result.indices { result[index].position = result[index].primary ? "outer" : "inner" }
    }
    return (result, orientation)
}

/// Screenshots one display and writes it with no alpha channel, as App Store Connect requires.
/// A .jpg or .jpeg path is written as JPEG at quality 0.95, anything else as PNG.
func screenshot(_ simulator: Simulator, display: Display, to destination: URL) throws -> (width: Int, height: Int) {
    let capture = FileManager.default.temporaryDirectory.appendingPathComponent("ax-\(UUID().uuidString).png")
    defer { try? FileManager.default.removeItem(at: capture) }
    _ = try xcrun(["simctl", "io", simulator.identifier, "screenshot", "--display=\(display.identifier)", capture.path])

    guard let source = CGImageSourceCreateWithURL(capture as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        throw Failure(.simulatorToolFailed, "screenshot_unreadable", "simctl wrote a screenshot ax could not read.")
    }
    let width = image.width, height = image.height
    let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
    let opaqueInfo = CGImageAlphaInfo.noneSkipLast.rawValue
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: image.colorSpace ?? sRGB, bitmapInfo: opaqueInfo)
            ?? CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB, bitmapInfo: opaqueInfo) else {
        throw Failure(.actionFailed, "screenshot_write_failed", "Could not prepare the screenshot for writing.")
    }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

    let isJPEG = ["jpg", "jpeg"].contains(destination.pathExtension.lowercased())
    let type = isJPEG ? UTType.jpeg : UTType.png
    try? FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard let opaque = context.makeImage(),
          let output = CGImageDestinationCreateWithURL(destination as CFURL, type.identifier as CFString, 1, nil) else {
        throw Failure(.actionFailed, "screenshot_write_failed", "Could not write \(destination.path).")
    }
    CGImageDestinationAddImage(output, opaque, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
    guard CGImageDestinationFinalize(output) else {
        throw Failure(.actionFailed, "screenshot_write_failed", "Could not write \(destination.path).")
    }
    return (width, height)
}
