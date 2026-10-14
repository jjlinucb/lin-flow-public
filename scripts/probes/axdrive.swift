import AppKit
import ApplicationServices
// Usage: axdrive dump <pid> [depth] | press <pid> <text> [role] | select <pid> <rowtext> | setvalue <pid> <text|@Role:idx> <value>
//        | focus <pid> <text|@Role:idx> | type <pid> "text" (keys go to this pid only) | act <pid> <text|@Role:idx> <AXAction> | enabled <pid> <text> | close <pid> <title>
func attr(_ e: AXUIElement, _ name: String) -> AnyObject? {
    var v: AnyObject?
    return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
}
func str(_ e: AXUIElement, _ name: String) -> String? { attr(e, name) as? String }
func children(_ e: AXUIElement) -> [AXUIElement] { (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }
func describe(_ e: AXUIElement) -> String {
    var parts = [str(e, kAXRoleAttribute) ?? "?"]
    if let t = str(e, kAXTitleAttribute), !t.isEmpty { parts.append("title=\"\(t)\"") }
    if let d = str(e, kAXDescriptionAttribute), !d.isEmpty { parts.append("desc=\"\(d)\"") }
    if let v = attr(e, kAXValueAttribute) { let s = "\(v)"; if !s.isEmpty && s.count < 160 { parts.append("value=\"\(s)\"") } }
    if let h = str(e, kAXHelpAttribute), !h.isEmpty { parts.append("help=\"\(h)\"") }
    return parts.joined(separator: " ")
}
func dump(_ e: AXUIElement, _ depth: Int, _ max: Int) {
    print(String(repeating: "  ", count: depth) + describe(e))
    if depth < max { for c in children(e) { dump(c, depth + 1, max) } }
}
func find(_ e: AXUIElement, _ pred: (AXUIElement) -> Bool, _ depth: Int = 0) -> AXUIElement? {
    if pred(e) { return e }
    if depth > 40 { return nil }
    for c in children(e) { if let f = find(c, pred, depth + 1) { return f } }
    return nil
}
/// "@AXTextField:1" picks the second element of that role in tree order.
func nth(_ root: AXUIElement, role: String, index: Int) -> AXUIElement? {
    var seen = 0
    var found: AXUIElement? = nil
    _ = find(root, { e in
        guard str(e, kAXRoleAttribute) == role else { return false }
        if seen == index { found = e; return true }
        seen += 1
        return false
    })
    return found
}
func matches(_ e: AXUIElement, _ needle: String) -> Bool {
    for k in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, kAXHelpAttribute] {
        if let s = attr(e, k) as? String, s.localizedCaseInsensitiveContains(needle) { return true }
    }
    return false
}
let a = CommandLine.arguments
guard a.count >= 3 else { print("usage"); exit(2) }
let cmd = a[1]; let pid = pid_t(a[2])!
let app = AXUIElementCreateApplication(pid)
switch cmd {
case "dump":
    dump(app, 0, a.count > 3 ? Int(a[3])! : 12)
case "press":
    let needle = a[3]; let role: String? = a.count > 4 ? a[4] : nil
    guard let el = find(app, { e in
        let r = str(e, kAXRoleAttribute)
        return (role == nil || r == role!) && r != "AXWindow" && r != "AXApplication" && matches(e, needle)
    }) else { print("not found: \(needle)"); exit(1) }
    print("pressing " + describe(el))
    print("result \(AXUIElementPerformAction(el, kAXPressAction as CFString).rawValue)")
case "focus", "act", "enabled":
    // focus <pid> @Role:idx | act <pid> @Role:idx AXActionName | enabled <pid> <needle>
    var el: AXUIElement? = nil
    if a[3].hasPrefix("@"), let colon = a[3].lastIndex(of: ":"), let idx = Int(a[3][a[3].index(after: colon)...]) {
        el = nth(app, role: String(a[3][a[3].index(after: a[3].startIndex)..<colon]), index: idx)
    } else {
        el = find(app, { e in str(e, kAXRoleAttribute) != "AXWindow" && str(e, kAXRoleAttribute) != "AXApplication" && matches(e, a[3]) })
    }
    guard let target = el else { print("not found"); exit(1) }
    switch cmd {
    case "focus":
        print("focus \(AXUIElementSetAttributeValue(target, kAXFocusedAttribute as CFString, kCFBooleanTrue).rawValue) on " + describe(target))
    case "act":
        print("act \(a[4]) \(AXUIElementPerformAction(target, a[4] as CFString).rawValue) on " + describe(target))
    default:
        var v: CFTypeRef?
        AXUIElementCopyAttributeValue(target, kAXEnabledAttribute as CFString, &v)
        print("enabled=\((v as? Bool).map(String.init) ?? "?") " + describe(target))
    }
case "type":
    // type <pid> "text": key events delivered to this process only, never through the HID tap.
    let text = a[3]
    for ch in text.unicodeScalars {
        let src = CGEventSource(stateID: .privateState)
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false) else { continue }
        var u = [UniChar](String(ch).utf16)
        down.keyboardSetUnicodeString(stringLength: u.count, unicodeString: &u)
        up.keyboardSetUnicodeString(stringLength: u.count, unicodeString: &u)
        if ch == "\n" { down.setIntegerValueField(.keyboardEventKeycode, value: 36); up.setIntegerValueField(.keyboardEventKeycode, value: 36) }
        down.postToPid(pid); up.postToPid(pid)
        usleep(8000)
    }
    print("typed \(text.count) chars")
case "setvalue":
    var target: AXUIElement? = nil
    if a[3].hasPrefix("@"), let colon = a[3].lastIndex(of: ":"), let idx = Int(a[3][a[3].index(after: colon)...]) {
        target = nth(app, role: String(a[3][a[3].index(after: a[3].startIndex)..<colon]), index: idx)
    } else {
        target = find(app, { e in ["AXTextField", "AXTextArea"].contains(str(e, kAXRoleAttribute) ?? "") && matches(e, a[3]) })
    }
    guard let el = target else { print("not found"); exit(1) }
    print("setvalue \(AXUIElementSetAttributeValue(el, kAXValueAttribute as CFString, a[4] as CFTypeRef).rawValue) on " + describe(el))
case "select":
    guard let row = find(app, { e in str(e, kAXRoleAttribute) == "AXRow" && find(e, { matches($0, a[3]) }) != nil }) else { print("row not found"); exit(1) }
    print("select \(AXUIElementSetAttributeValue(row, kAXSelectedAttribute as CFString, kCFBooleanTrue).rawValue) on " + describe(row))
case "close":
    guard let win = find(app, { e in str(e, kAXRoleAttribute) == "AXWindow" && (str(e, kAXTitleAttribute) ?? "").contains(a[3]) }),
          let btn = attr(win, kAXCloseButtonAttribute) else { print("window not found"); exit(1) }
    print("close \(AXUIElementPerformAction(btn as! AXUIElement, kAXPressAction as CFString).rawValue)")
default: print("unknown")
}
