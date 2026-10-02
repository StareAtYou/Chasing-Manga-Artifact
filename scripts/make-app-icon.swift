import AppKit
import Foundation
let destination = CommandLine.arguments[1]
let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".iconset")
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let unit = CGFloat(pixels) / 1024
        let transform = NSAffineTransform(); transform.scale(by: unit); transform.concat()
        NSColor(calibratedRed: 0.05, green: 0.40, blue: 0.43, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: 1024, height: 1024), xRadius: 220, yRadius: 220).fill()
        NSColor.white.setFill()
        NSBezierPath(roundedRect: NSRect(x: 180, y: 236, width: 290, height: 548), xRadius: 44, yRadius: 44).fill()
        NSBezierPath(roundedRect: NSRect(x: 554, y: 236, width: 290, height: 548), xRadius: 44, yRadius: 44).fill()
        NSColor(calibratedRed: 0.98, green: 0.70, blue: 0.25, alpha: 1).setFill()
        let bookmark = NSBezierPath(); bookmark.move(to: NSPoint(x: 638, y: 784)); bookmark.line(to: NSPoint(x: 744, y: 784)); bookmark.line(to: NSPoint(x: 744, y: 526)); bookmark.line(to: NSPoint(x: 691, y: 570)); bookmark.line(to: NSPoint(x: 638, y: 526)); bookmark.close(); bookmark.fill()
        image.unlockFocus()
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        try bitmap.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent("icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"))
    }
}
let task = Process(); task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil"); task.arguments = ["-c", "icns", root.path, "-o", destination]; try task.run(); task.waitUntilExit(); guard task.terminationStatus == 0 else { exit(task.terminationStatus) }
