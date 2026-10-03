import AppKit
import Foundation
let root = URL(fileURLWithPath: CommandLine.arguments[1])
for file in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter({$0.pathExtension == "png"}) {
    guard let rep = NSBitmapImageRep(data: try Data(contentsOf: file)) else { fatalError("Cannot decode \(file.lastPathComponent)") }
    var bright = 0; var colored = 0
    for y in stride(from: 0, to: rep.pixelsHigh, by: max(1,rep.pixelsHigh/40)) { for x in stride(from: 0, to: rep.pixelsWide, by: max(1,rep.pixelsWide/40)) {
        let c = rep.colorAt(x:x,y:y)!.usingColorSpace(.deviceRGB)!
        if c.redComponent + c.greenComponent + c.blueComponent > 2.5 { bright += 1 }
        if c.greenComponent > c.redComponent + 0.1 { colored += 1 }
    }}
    guard bright > 80, colored >= 200 else { fputs("FAIL \(file.lastPathComponent): white=\(bright) teal=\(colored)\n",stderr);exit(1) }
    print("PASS \(file.lastPathComponent): \(rep.pixelsWide)x\(rep.pixelsHigh)")
}
