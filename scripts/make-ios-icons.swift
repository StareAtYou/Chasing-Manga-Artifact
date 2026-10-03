import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Foundation

// Draw directly into a bitmap. AppKit drawing into the former RGB bitmap
// silently produced black pixels; CGContext also works without a window.
let destination = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Apps/iOS/Icons")
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
let sizes: [(String, Int)] = [("20x20",1),("20x20",2),("20x20",3),("29x29",1),("29x29",2),("29x29",3),("40x40",1),("40x40",2),("40x40",3),("60x60",2),("60x60",3),("76x76",1),("76x76",2),("83.5x83.5",2)]
func write(pixels: Int, name: String) throws {
    guard let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: pixels * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw NSError(domain: "Icon", code: 1) }
    context.scaleBy(x: CGFloat(pixels)/1024, y: CGFloat(pixels)/1024)
    context.setFillColor(CGColor(red: 0.05, green: 0.40, blue: 0.43, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    for x in [180,554] { context.addPath(CGPath(roundedRect: CGRect(x:x,y:236,width:290,height:548), cornerWidth:44,cornerHeight:44,transform:nil)); context.fillPath() }
    context.setFillColor(CGColor(red:0.98,green:0.70,blue:0.25,alpha:1))
    context.move(to:CGPoint(x:638,y:784));context.addLine(to:CGPoint(x:744,y:784));context.addLine(to:CGPoint(x:744,y:526));context.addLine(to:CGPoint(x:691,y:570));context.addLine(to:CGPoint(x:638,y:526));context.closePath();context.fillPath()
    guard let image = context.makeImage(), let writer = CGImageDestinationCreateWithURL(destination.appendingPathComponent(name).appendingPathExtension("png") as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw NSError(domain: "Icon",code:2) }
    CGImageDestinationAddImage(writer,image,nil)
    guard CGImageDestinationFinalize(writer) else { throw NSError(domain:"Icon",code:3) }
}
for (size,scale) in sizes { let points = Double(size.components(separatedBy:"x")[0])!;try write(pixels:Int(points*Double(scale)), name:"AppIcon"+size+(scale == 1 ? "" : "@\(scale)x")) }
try write(pixels:1024,name:"AppIcon1024")
