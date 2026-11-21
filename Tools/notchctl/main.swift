// SPDX-License-Identifier: GPL-3.0-or-later
// notchctl: drive and inspect Hoo Notch on the real screen, for end-to-end
// checks, the way Playwright drives a browser. Coordinates are global, in
// points, from the top-left of the main display (as screencapture -R uses).
//
//   notchctl perms                 permission status (asks for them if missing)
//   notchctl info                  display, camera notch and the app's windows
//   notchctl shot FILE [x y w h]   screenshot (default: the top 260 pt around the notch)
//   notchctl move X Y              move the pointer
//   notchctl hover [part] [secs]   hover the notch: center | hoo-left | hoo-right | below (default center, 1.5 s)
//   notchctl click X Y | dclick X Y
//   notchctl scroll DX DY [option] scroll at the pointer, optionally holding Option
//   notchctl away                  park the pointer away from the notch
//   notchctl ax [depth]            accessibility tree of the app's windows
import AppKit
import ApplicationServices
import Foundation

let appNames = ["Hoo Notch (Developer)", "VorssaintDeveloper", "Hoo Notch", "Vorssaint"]
let args = Array(CommandLine.arguments.dropFirst())
func fail(_ message: String) -> Never { FileHandle.standardError.write((message + "\n").data(using: .utf8)!); exit(1) }

var mainHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

/// The camera housing, in top-left coordinates, or the top middle on a display without one.
func notchRect() -> CGRect {
    guard let screen = NSScreen.screens.first else { return .zero }
    let top = screen.safeAreaInsets.top
    if top > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
        return CGRect(x: left.maxX, y: 0, width: right.minX - left.maxX, height: top)
    }
    return CGRect(x: screen.frame.midX - 100, y: 0, width: 200, height: 32)
}

func appPID() -> pid_t? {
    NSWorkspace.shared.runningApplications.first { app in
        appNames.contains(app.localizedName ?? "") || app.bundleIdentifier == "com.vorssaint.utils.dev"
    }?.processIdentifier
}

func post(_ type: CGEventType, _ point: CGPoint, clicks: Int64 = 1, flags: CGEventFlags = []) {
    guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left) else { return }
    event.setIntegerValueField(.mouseEventClickState, value: clicks)
    event.flags = flags
    event.post(tap: .cghidEventTap)
}

func move(_ point: CGPoint) { post(.mouseMoved, point) }

func click(_ point: CGPoint, count: Int64 = 1) {
    move(point); usleep(80_000)
    for n in 1...count {
        post(.leftMouseDown, point, clicks: n); usleep(40_000)
        post(.leftMouseUp, point, clicks: n); usleep(90_000)
    }
}

func number(_ i: Int) -> CGFloat {
    guard args.count > i, let value = Double(args[i]) else { fail("missing number argument \(i)") }
    return CGFloat(value)
}

func axDump(_ element: AXUIElement, depth: Int, max: Int) {
    func attr(_ name: String) -> AnyObject? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }
    let role = attr(kAXRoleAttribute) as? String ?? "?"
    let id = attr("AXIdentifier") as? String
    let title = (attr(kAXTitleAttribute) as? String) ?? (attr(kAXDescriptionAttribute) as? String) ?? (attr(kAXValueAttribute) as? String)
    var frame = ""
    if let pos = attr(kAXPositionAttribute), let size = attr(kAXSizeAttribute) {
        var p = CGPoint.zero, s = CGSize.zero
        AXValueGetValue(pos as! AXValue, .cgPoint, &p); AXValueGetValue(size as! AXValue, .cgSize, &s)
        frame = String(format: " [%.0f,%.0f %.0f×%.0f]", p.x, p.y, s.width, s.height)
    }
    let label = [id.map { "#\($0)" }, title.flatMap { $0.isEmpty ? nil : "\"\($0.prefix(60))\"" }].compactMap { $0 }.joined(separator: " ")
    print(String(repeating: "  ", count: depth) + role + (label.isEmpty ? "" : " " + label) + frame)
    guard depth < max, let children = attr(kAXChildrenAttribute) as? [AXUIElement] else { return }
    for child in children { axDump(child, depth: depth + 1, max: max) }
}

switch args.first ?? "help" {
case "perms":
    let screen = CGPreflightScreenCaptureAccess(), ax = AXIsProcessTrusted()
    print("screen recording: \(screen ? "granted" : "missing")")
    print("accessibility:    \(ax ? "granted" : "missing")")
    if !screen { _ = CGRequestScreenCaptureAccess() }
    if !ax { _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary) }
    exit(screen && ax ? 0 : 2)
case "info":
    let n = notchRect()
    for (i, s) in NSScreen.screens.enumerated() {
        print("display \(i): \(Int(s.frame.width))×\(Int(s.frame.height)) pt, scale \(s.backingScaleFactor), notch top inset \(s.safeAreaInsets.top)")
    }
    print(String(format: "notch: x %.0f y %.0f w %.0f h %.0f (center %.0f)", n.minX, n.minY, n.width, n.height, n.midX))
    print("app pid: \(appPID().map(String.init) ?? "not running")")
    if let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]], let pid = appPID() {
        for w in list where (w[kCGWindowOwnerPID as String] as? pid_t) == pid {
            let b = w[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
            print(String(format: "  window layer %d: x %.0f y %.0f w %.0f h %.0f", w[kCGWindowLayer as String] as? Int ?? 0,
                         b["X"] ?? 0, b["Y"] ?? 0, b["Width"] ?? 0, b["Height"] ?? 0))
        }
    }
case "shot":
    guard args.count >= 2 else { fail("usage: notchctl shot FILE [x y w h]") }
    let n = notchRect()
    let rect = args.count >= 6 ? CGRect(x: number(2), y: number(3), width: number(4), height: number(5))
        : CGRect(x: n.midX - 380, y: 0, width: 760, height: 260)
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    task.arguments = ["-x", "-R\(Int(rect.minX)),\(Int(rect.minY)),\(Int(rect.width)),\(Int(rect.height))", args[1]]
    try task.run(); task.waitUntilExit()
    exit(task.terminationStatus)
case "move": move(CGPoint(x: number(1), y: number(2)))
case "click": click(CGPoint(x: number(1), y: number(2)))
case "dclick": click(CGPoint(x: number(1), y: number(2)), count: 2)
case "hover":
    let n = notchRect(), part = args.count > 1 ? args[1] : "center"
    let seconds = args.count > 2 ? Double(args[2]) ?? 1.5 : 1.5
    let point: CGPoint
    switch part {
    case "hoo-left": point = CGPoint(x: n.minX - 22, y: n.midY)
    case "hoo-right": point = CGPoint(x: n.maxX + 22, y: n.midY)
    case "below": point = CGPoint(x: n.midX, y: n.maxY + 40)
    default: point = CGPoint(x: n.midX, y: n.maxY - 4)
    }
    // Arrive from below like a hand would, so tracking areas see an entry.
    move(CGPoint(x: point.x, y: point.y + 60)); usleep(120_000)
    for k in 1...6 { move(CGPoint(x: point.x, y: point.y + 60 - CGFloat(k) * 10)); usleep(30_000) }
    usleep(UInt32(seconds * 1_000_000))
    print(String(format: "hovering %@ at %.0f,%.0f", part, point.x, point.y))
case "scroll":
    let flags: CGEventFlags = args.count > 3 && args[3] == "option" ? .maskAlternate : []
    if let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                       wheel1: Int32(number(2)), wheel2: Int32(number(1)), wheel3: 0) {
        e.flags = flags; e.post(tap: .cghidEventTap)
    }
case "away":
    let n = notchRect(); move(CGPoint(x: n.midX, y: 420))
case "type":
    // Types text, but only into Hoo Notch: never into another app by mistake.
    guard args.count >= 2 else { fail("usage: notchctl type TEXT") }
    guard let pid = appPID(), NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
        fail("refusing to type: Hoo Notch is not the frontmost app")
    }
    for scalar in args[1].unicodeScalars {
        var unit = Array(String(scalar).utf16)
        for down in [true, false] {
            if let e = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down) {
                e.keyboardSetUnicodeString(stringLength: unit.count, unicodeString: &unit); e.post(tap: .cghidEventTap)
            }
        }
        usleep(12_000)
    }
case "key":
    // return | escape | up | down | tab
    let codes: [String: CGKeyCode] = ["return": 36, "escape": 53, "up": 126, "down": 125, "tab": 48]
    guard args.count >= 2, let code = codes[args[1]] else { fail("usage: notchctl key return|escape|up|down|tab") }
    guard let pid = appPID(), NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
        fail("refusing to send keys: Hoo Notch is not the frontmost app")
    }
    for down in [true, false] { CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)?.post(tap: .cghidEventTap) }
case "fill":
    // Sets the text of the app's first text field through accessibility.
    guard args.count >= 2, let pid = appPID() else { fail("usage: notchctl fill TEXT") }
    func field(_ element: AXUIElement, _ depth: Int) -> AXUIElement? {
        var role: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        if (role as? String) == kAXTextFieldRole || (role as? String) == kAXTextAreaRole { return element }
        guard depth < 30 else { return nil }
        var children: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
        for child in (children as? [AXUIElement]) ?? [] { if let hit = field(child, depth + 1) { return hit } }
        return nil
    }
    guard let target = field(AXUIElementCreateApplication(pid), 0) else { fail("no text field on screen") }
    AXUIElementSetAttributeValue(target, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    let result = AXUIElementSetAttributeValue(target, kAXValueAttribute as CFString, args[1] as CFString)
    print(result == .success ? "filled" : "fill failed (\(result.rawValue))")
case "press":
    // Presses a button in the app by its name, through accessibility: no
    // pointer, so nothing behind the island can be clicked by mistake.
    guard args.count >= 2 else { fail("usage: notchctl press TITLE") }
    guard let pid = appPID() else { fail("app not running") }
    let wanted = args[1].lowercased()
    func find(_ element: AXUIElement, _ depth: Int) -> AXUIElement? {
        var role: AnyObject?, title: AnyObject?, description: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &title)
        AXUIElementCopyAttributeValue(element, kAXDescriptionAttribute as CFString, &description)
        let name = ((title as? String) ?? (description as? String) ?? "").lowercased()
        if (role as? String) == kAXButtonRole, !name.isEmpty, name == wanted || name.hasPrefix(wanted) { return element }
        guard depth < 30 else { return nil }
        var children: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
        for child in (children as? [AXUIElement]) ?? [] { if let hit = find(child, depth + 1) { return hit } }
        return nil
    }
    guard let button = find(AXUIElementCreateApplication(pid), 0) else { fail("no button named \"\(args[1])\" on screen") }
    let result = AXUIElementPerformAction(button, kAXPressAction as CFString)
    print(result == .success ? "pressed \(args[1])" : "press failed (\(result.rawValue))")
case "ax":
    guard let pid = appPID() else { fail("app not running") }
    guard AXIsProcessTrusted() else { fail("accessibility permission missing: run `notchctl perms`") }
    let app = AXUIElementCreateApplication(pid)
    axDump(app, depth: 0, max: args.count > 1 ? Int(args[1]) ?? 8 : 8)
default:
    print("usage: notchctl perms | info | shot FILE [x y w h] | move X Y | hover [center|hoo-left|hoo-right|below] [secs] | click X Y | dclick X Y | scroll DX DY [option] | away | ax [depth]")
}
