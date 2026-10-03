// Draws Orbit's app icon (1024×1024 PNG): the orbit mark from the web favicon, on a night-sky tile.
// Used by build.sh:  swift tools/make-icon.swift out.png
import AppKit

let px = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

// The macOS icon tile: an 824-point rounded square, centered.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
ctx.saveGState()
ctx.addPath(CGPath(roundedRect: tile, cornerWidth: 186, cornerHeight: 186, transform: nil))
ctx.clip()
let sky = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                     colors: [CGColor(red: 0.11, green: 0.15, blue: 0.26, alpha: 1), CGColor(red: 0.04, green: 0.07, blue: 0.13, alpha: 1)] as CFArray,
                     locations: [0, 1])!
ctx.drawRadialGradient(sky, startCenter: CGPoint(x: 512, y: 600), startRadius: 0, endCenter: CGPoint(x: 512, y: 512), endRadius: 620, options: [.drawsAfterEndLocation])
// A few stars.
var seed: UInt64 = 7
func rnd() -> CGFloat { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return CGFloat(seed >> 33) / CGFloat(1 << 31) }
for _ in 0..<38 {
    let r = 1.5 + rnd() * 3
    ctx.setFillColor(CGColor(red: 0.93, green: 0.95, blue: 1, alpha: 0.25 + rnd() * 0.5))
    ctx.fillEllipse(in: CGRect(x: 120 + rnd() * 784, y: 120 + rnd() * 784, width: r, height: r))
}
ctx.restoreGState()

// The orbit mark, drawn in the favicon's own 32×32 coordinates (y pointing down, like SVG).
let violet = CGColor(red: 0.65, green: 0.61, blue: 1, alpha: 1)
ctx.saveGState()
ctx.translateBy(x: 512, y: 512)
ctx.scaleBy(x: 21, y: -21)
ctx.translateBy(x: -16, y: -16)
ctx.saveGState()
ctx.translateBy(x: 16, y: 16)
ctx.rotate(by: -28 * .pi / 180)
ctx.setStrokeColor(violet.copy(alpha: 0.55)!)
ctx.setLineWidth(2)
ctx.strokeEllipse(in: CGRect(x: -13, y: -6.5, width: 26, height: 13))
ctx.restoreGState()
ctx.setFillColor(violet)
ctx.fillEllipse(in: CGRect(x: 11, y: 11, width: 10, height: 10))
ctx.fillEllipse(in: CGRect(x: 25.8 - 2.6, y: 8.3 - 2.6, width: 5.2, height: 5.2))
ctx.restoreGState()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
