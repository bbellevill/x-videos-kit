// Génère app/AppIcon.icns : carré arrondi noir, bouton d'enregistrement violet plat (charte XTablo).
import Cocoa
let out = CommandLine.arguments[1]
let set = out + "/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: set, withIntermediateDirectories: true)
func png(_ px: Int, _ name: String) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    let body = NSRect(x: s * 0.1, y: s * 0.1, width: s * 0.8, height: s * 0.8)
    NSColor(srgbRed: 0.04, green: 0.04, blue: 0.045, alpha: 1).setFill()
    NSBezierPath(roundedRect: body, xRadius: s * 0.18, yRadius: s * 0.18).fill()
    let violet = NSColor(srgbRed: 0x7b / 255, green: 0x5b / 255, blue: 0xf4 / 255, alpha: 1)
    let ring = NSBezierPath(ovalIn: NSRect(x: s * 0.27, y: s * 0.27, width: s * 0.46, height: s * 0.46))
    ring.lineWidth = s * 0.035; violet.setStroke(); ring.stroke()
    violet.setFill()
    NSBezierPath(ovalIn: NSRect(x: s * 0.36, y: s * 0.36, width: s * 0.28, height: s * 0.28)).fill()
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(set)/\(name).png"))
}
for (pt, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    png(pt * scale, scale == 1 ? "icon_\(pt)x\(pt)" : "icon_\(pt)x\(pt)@2x")
}
