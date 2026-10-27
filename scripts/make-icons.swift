// Renders the Hushpad app icons: one ribbon that loops over itself, drawn with a fixed-angle
// calligraphy nib so it twists, showing a cream front and an apricot back. Playful, and still says
// nothing about recording: no sound wave, no microphone, no red dot.
//
// Usage: swift scripts/make-icons.swift <output-folder>
// Writes icon-light/dark/tinted.png (iPhone, 1024, full bleed), icon-mac.png (squircle), icon-watch.png,
// and menubar.png / menubar@2x.png (18 pt template image for the Mac menu bar).
import AppKit
import CoreGraphics

enum Variant: String, CaseIterable { case light, dark, tinted }

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

let space = CGColorSpace(name: CGColorSpace.sRGB)!

func context(_ size: CGFloat) -> CGContext {
    CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
              space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

struct Palette {
    var background: [CGColor]
    var front: CGColor
    var back: CGColor
}

func palette(_ variant: Variant) -> Palette {
    switch variant {
    case .light:
        Palette(background: [color(0x3A5A92), color(0x1C2C4C)], front: color(0xFAF3E3), back: color(0xF2B880))
    case .dark:
        Palette(background: [color(0x26324A), color(0x111622)], front: color(0xEDE6D6), back: color(0xD99E68))
    case .tinted:
        Palette(background: [color(0x000000), color(0x000000)], front: color(0xFFFFFF), back: color(0xFFFFFF, 0.5))
    }
}

func fillBackground(_ ctx: CGContext, _ colors: [CGColor], size: CGFloat) {
    let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size), end: CGPoint(x: size, y: 0), options: [])
}

/// The ribbon: a prolate cycloid (one loop), tilted 12°, swept by a flat nib. Each step is a quad between
/// the nib's ends; which side faces us flips where the path turns past the nib angle, giving the twist.
/// Fitted so the whole ribbon sits in a centred `box`-wide square.
func drawRibbon(_ ctx: CGContext, _ p: Palette, size: CGFloat, box: CGFloat) {
    let steps = 1200, loop = 3.0
    let t0 = -0.15 * Double.pi, t1 = 2.15 * Double.pi
    let tilt = 12 * CGFloat.pi / 180, nibAngle = 40 * CGFloat.pi / 180
    var points = (0...steps).map { step -> CGPoint in
        let t = t0 + (t1 - t0) * Double(step) / Double(steps)
        let x = t - loop * sin(t), y = -loop * cos(t)
        return CGPoint(x: x * cos(tilt) - y * sin(tilt), y: x * sin(tilt) + y * cos(tilt))
    }
    // Nib length relative to the curve's width, before fitting.
    let curveWidth = points.map(\.x).max()! - points.map(\.x).min()!
    var nib = CGVector(dx: cos(nibAngle) * curveWidth * 0.155, dy: sin(nibAngle) * curveWidth * 0.155)
    let xs = points.flatMap { [$0.x - nib.dx, $0.x + nib.dx] }, ys = points.flatMap { [$0.y - nib.dy, $0.y + nib.dy] }
    let scale = box * size / 1024 / max(xs.max()! - xs.min()!, ys.max()! - ys.min()!)
    let centre = CGPoint(x: (xs.max()! + xs.min()!) / 2, y: (ys.max()! + ys.min()!) / 2)
    points = points.map { CGPoint(x: size / 2 + ($0.x - centre.x) * scale, y: size / 2 + ($0.y - centre.y) * scale) }
    nib = CGVector(dx: nib.dx * scale, dy: nib.dy * scale)

    for index in 0..<steps {
        // Span two steps so neighbouring quads overlap and no antialiasing seams show.
        let p0 = points[index], p1 = points[min(index + 2, steps)]
        let facing = (p1.x - p0.x) * nib.dy - (p1.y - p0.y) * nib.dx
        ctx.setFillColor(facing > 0 ? p.front : p.back)
        ctx.move(to: CGPoint(x: p0.x - nib.dx, y: p0.y - nib.dy))
        ctx.addLine(to: CGPoint(x: p0.x + nib.dx, y: p0.y + nib.dy))
        ctx.addLine(to: CGPoint(x: p1.x + nib.dx, y: p1.y + nib.dy))
        ctx.addLine(to: CGPoint(x: p1.x - nib.dx, y: p1.y - nib.dy))
        ctx.closePath()
        ctx.fillPath()
    }
}

func render(_ variant: Variant, size: CGFloat = 1024, box: CGFloat = 640) -> CGImage {
    let ctx = context(size)
    let p = palette(variant)
    fillBackground(ctx, p.background, size: size)
    drawRibbon(ctx, p, size: size, box: box)
    return ctx.makeImage()!
}

/// macOS doesn't mask icons: draw inside Apple's rounded-square grid (824 pt body, soft shadow).
func macIcon(size: CGFloat = 1024) -> CGImage {
    let ctx = context(size)
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: color(0x000000, 0.3))
    ctx.addPath(shape)
    ctx.setFillColor(color(0x2F4A7A))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.addPath(shape)
    ctx.clip()
    ctx.draw(render(.light), in: body)
    return ctx.makeImage()!
}

/// Watch icons are circles: the same ribbon, a little smaller so it clears the mask.
func watchIcon() -> CGImage { render(.light, box: 600) }

/// Menu bar: the ribbon alone in black on clear, back side half transparent. Used as a template image, so
/// macOS tints it for light and dark menu bars and it never changes while recording.
func menuBarIcon(scale: CGFloat) -> CGImage {
    let size = 18 * scale
    let ctx = context(size)
    drawRibbon(ctx, Palette(background: [], front: color(0x000000), back: color(0x000000, 0.45)), size: size, box: 1024)
    return ctx.makeImage()!
}

func write(_ image: CGImage, to url: URL) {
    let rep = NSBitmapImageRep(cgImage: image)
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? ".")
try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for variant in Variant.allCases {
    write(render(variant), to: output.appendingPathComponent("icon-\(variant.rawValue).png"))
}
write(macIcon(), to: output.appendingPathComponent("icon-mac.png"))
write(watchIcon(), to: output.appendingPathComponent("icon-watch.png"))
write(menuBarIcon(scale: 1), to: output.appendingPathComponent("menubar.png"))
write(menuBarIcon(scale: 2), to: output.appendingPathComponent("menubar@2x.png"))
print("Wrote icons to \(output.path)")
