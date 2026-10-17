// Renders Den.svg to PNGs and Den.icns:  swift render.swift   (run from app/Icon)
import AppKit
let svg = NSImage(contentsOfFile: "Den.svg")!
func png(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    svg.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}
let set = URL(fileURLWithPath: "Den.iconset")
try? FileManager.default.removeItem(at: set)
try! FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for pt in [16, 32, 128, 256, 512] {
    try! png(pt).write(to: set.appending(path: "icon_\(pt)x\(pt).png"))
    try! png(pt * 2).write(to: set.appending(path: "icon_\(pt)x\(pt)@2x.png"))
}
try! png(1024).write(to: URL(fileURLWithPath: "Den.png"))
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", "Den.iconset", "-o", "Den.icns"]
try! iconutil.run(); iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: set)
