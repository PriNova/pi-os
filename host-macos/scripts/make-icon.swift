// Build-time asset generator. No Swift compilation or drawing helper is spawned at runtime.
import AppKit
import Foundation

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for size in [16, 32, 64, 128, 256, 512, 1024] {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: size * 4, bitsPerPixel: 32)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let scale = CGFloat(size) / 1024
    let transform = NSAffineTransform(); transform.scale(by: scale); transform.concat()
    let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
    let path = NSBezierPath(roundedRect: tile, xRadius: 184, yRadius: 184)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
    shadow.shadowBlurRadius = 32; shadow.shadowOffset = NSSize(width: 0, height: -12); shadow.set()
    NSColor(calibratedWhite: 0.1, alpha: 1).setFill(); path.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(colors: [NSColor(srgbRed: 0.10, green: 0.18, blue: 0.28, alpha: 1),
                        NSColor(srgbRed: 0.035, green: 0.075, blue: 0.13, alpha: 1)])!.draw(in: path, angle: -90)
    NSColor.white.withAlphaComponent(0.14).setStroke(); path.lineWidth = 2; path.stroke()
    let cyan = NSColor(srgbRed: 0.30, green: 0.76, blue: 1, alpha: 1)
    let ring = NSBezierPath(ovalIn: NSRect(x: 292, y: 292, width: 440, height: 440)); ring.lineWidth = 36
    NSGraphicsContext.saveGraphicsState()
    let glow = NSShadow(); glow.shadowColor = cyan.withAlphaComponent(0.65)
    glow.shadowBlurRadius = 42; glow.shadowOffset = .zero; glow.set()
    cyan.setStroke(); ring.stroke(); cyan.setFill()
    NSBezierPath(ovalIn: NSRect(x: 417, y: 417, width: 190, height: 190)).fill()
    NSGraphicsContext.restoreGraphicsState()
    cyan.setStroke(); ring.stroke(); cyan.setFill()
    NSBezierPath(ovalIn: NSRect(x: 417, y: 417, width: 190, height: 190)).fill()
    NSGraphicsContext.restoreGraphicsState()
    let png = bitmap.representation(using: .png, properties: [:])!
    if [16, 32, 128, 256, 512].contains(size) { try png.write(to: output.appendingPathComponent("icon_\(size)x\(size).png")) }
    if [32, 64, 256, 512, 1024].contains(size) { try png.write(to: output.appendingPathComponent("icon_\(size / 2)x\(size / 2)@2x.png")) }
}
