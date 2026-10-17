import AppKit
let destination = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
let sizes = [(16, "icon_16x16"), (32, "icon_16x16@2x"), (32, "icon_32x32"), (64, "icon_32x32@2x"), (128, "icon_128x128"), (256, "icon_128x128@2x"), (256, "icon_256x256"), (512, "icon_256x256@2x"), (512, "icon_512x512"), (1024, "icon_512x512@2x")]
for (size, name) in sizes {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
    context.cgContext.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    let background = NSBezierPath(roundedRect: NSRect(x: 32, y: 32, width: 960, height: 960), xRadius: 210, yRadius: 210)
    NSGradient(starting: NSColor(red: 0.08, green: 0.19, blue: 0.24, alpha: 1), ending: NSColor(red: 0.05, green: 0.10, blue: 0.16, alpha: 1))!.draw(in: background, angle: -75)
    let colors = [NSColor(red: 0.28, green: 0.85, blue: 0.67, alpha: 1), NSColor(red: 0.40, green: 0.65, blue: 1, alpha: 1), NSColor(red: 0.72, green: 0.54, blue: 0.98, alpha: 1)]
    let heights: [CGFloat] = [265, 490, 365]
    for i in 0..<3 {
        let x = CGFloat(210 + i * 220)
        NSColor.white.withAlphaComponent(0.07).setFill(); NSBezierPath(roundedRect: NSRect(x: x, y: 210, width: 160, height: 560), xRadius: 45, yRadius: 45).fill()
        colors[i].setFill(); NSBezierPath(roundedRect: NSRect(x: x, y: 210, width: 160, height: heights[i]), xRadius: 45, yRadius: 45).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: destination.appendingPathComponent(name + ".png"))
}
// ICNS accepts PNG representations directly; this avoids platform iconutil differences.
let types = [("icp4", "icon_16x16"), ("icp5", "icon_32x32"), ("icp6", "icon_32x32@2x"), ("ic07", "icon_128x128"), ("ic08", "icon_256x256"), ("ic09", "icon_512x512"), ("ic10", "icon_512x512@2x"), ("ic11", "icon_16x16@2x"), ("ic12", "icon_32x32@2x"), ("ic13", "icon_128x128@2x"), ("ic14", "icon_256x256@2x")]
func lengthData(_ n: Int) -> Data { var big = UInt32(n).bigEndian; return withUnsafeBytes(of: &big) { Data($0) } }
var payload = Data()
for (type, name) in types {
    let png = try Data(contentsOf: destination.appendingPathComponent(name + ".png"))
    payload.append(Data(type.utf8)); payload.append(lengthData(png.count + 8)); payload.append(png)
}
var icon = Data("icns".utf8); icon.append(lengthData(payload.count + 8)); icon.append(payload)
let output = CommandLine.arguments.count > 2 ? URL(fileURLWithPath: CommandLine.arguments[2]) : destination.deletingLastPathComponent().appendingPathComponent("AppIcon.icns")
try icon.write(to: output)
