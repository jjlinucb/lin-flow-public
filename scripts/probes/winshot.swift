import AppKit
import CoreGraphics
// Usage: winshot <pid> <out.png> [nameSubstring]  — screenshots the largest layer-0 window of a pid.
let a = CommandLine.arguments
let pid = pid_t(a[1])!
let out = a[2]
let want: String? = a.count > 3 ? a[3] : nil
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
var best: (CGWindowID, CGRect)? = nil
for w in list {
    guard let p = w[kCGWindowOwnerPID as String] as? pid_t, p == pid,
          let layer = w[kCGWindowLayer as String] as? Int, layer == 0,
          let num = w[kCGWindowNumber as String] as? CGWindowID,
          let b = w[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
    let r = CGRect(x: b["X"]!, y: b["Y"]!, width: b["Width"]!, height: b["Height"]!)
    let name = w[kCGWindowName as String] as? String ?? ""
    if let want = want, !name.contains(want) { continue }
    if best == nil || r.width * r.height > best!.1.width * best!.1.height { best = (num, r) }
}
guard let found = best else { print("no window"); exit(1) }
print("window \(found.0) \(found.1)")
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
task.arguments = ["-l\(found.0)", "-x", "-o", out]
try! task.run(); task.waitUntilExit()
print("screencapture exit \(task.terminationStatus)")
