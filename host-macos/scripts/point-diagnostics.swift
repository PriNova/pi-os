// Read-only, numeric diagnostics for the disposable installed-host test.
// No titles, filenames, text values, screenshots, focus changes or events.
import AppKit
import ApplicationServices
let a = CommandLine.arguments
guard a.count == 3, let x = Double(a[1]), let y = Double(a[2]), x.isFinite, y.isFinite else {
    fputs("Usage: point-diagnostics.swift <finite-x> <finite-y>\n", stderr); exit(64)
}
let point = CGPoint(x: x, y: y)
let windows = (CGWindowListCopyWindowInfo(.optionOnScreenOnly, 0) as? [[String:Any]] ?? []).compactMap { info -> [String:Any]? in
    guard let raw = info[kCGWindowBounds as String] as? NSDictionary, let frame = CGRect(dictionaryRepresentation: raw), frame.contains(point) else { return nil }
    return ["pid":info[kCGWindowOwnerPID as String] ?? -1,"id":info[kCGWindowNumber as String] ?? -1,"layer":info[kCGWindowLayer as String] ?? -1,"alpha":info[kCGWindowAlpha as String] ?? -1]
}
func value(_ e: AXUIElement, _ key: String) -> CFTypeRef? {
    AXUIElementSetMessagingTimeout(e, 0.05); var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(e, key as CFString, &v) == .success ? v : nil
}
let system = AXUIElementCreateSystemWide()
var output: [String:Any] = ["point": ["x":point.x,"y":point.y], "windowsAtPoint": windows]
if let app = value(system, kAXFocusedApplicationAttribute), CFGetTypeID(app) == AXUIElementGetTypeID() {
    var pid: pid_t = 0; AXUIElementGetPid(app as! AXUIElement, &pid); output["focusedAppPID"] = pid
}
if let element = value(system, kAXFocusedUIElementAttribute), CFGetTypeID(element) == AXUIElementGetTypeID() {
    var pid: pid_t = 0; AXUIElementGetPid(element as! AXUIElement, &pid); output["focusedElementPID"] = pid
    output["focusedRole"] = value(element as! AXUIElement, kAXRoleAttribute) as? String
}
print(String(decoding: try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted,.sortedKeys]), as: UTF8.self))
