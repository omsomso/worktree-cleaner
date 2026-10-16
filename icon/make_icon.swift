// Draws the Worktree Cleaner app icon (1024×1024 PNG): a branch that has merged back into
// its main line, with a check badge, on a teal rounded square. Run by icon/make-icns.sh.
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments[1]
guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
      let context = NSGraphicsContext(bitmapImageRep: rep) else { fatalError("no context") }
NSGraphicsContext.current = context
let cg = context.cgContext

// macOS icon grid: the shape is inset from the canvas and has rounded corners.
let inset: CGFloat = 100
let rect = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let shape = CGPath(roundedRect: rect, cornerWidth: 185, cornerHeight: 185, transform: nil)

// Soft drop shadow, then the teal gradient.
cg.saveGState()
cg.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: CGColor(gray: 0, alpha: 0.35))
cg.addPath(shape); cg.setFillColor(CGColor(red: 0.06, green: 0.33, blue: 0.35, alpha: 1)); cg.fillPath()
cg.restoreGState()
cg.saveGState()
cg.addPath(shape); cg.clip()
let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
    CGColor(red: 0.18, green: 0.66, blue: 0.60, alpha: 1), CGColor(red: 0.05, green: 0.31, blue: 0.35, alpha: 1)] as CFArray,
    locations: [0, 1])!
cg.drawLinearGradient(gradient, start: CGPoint(x: size / 2, y: size - inset), end: CGPoint(x: size / 2, y: inset), options: [])

let white = CGColor(gray: 1, alpha: 1)
cg.setStrokeColor(white)
cg.setLineWidth(46)
cg.setLineCap(.round)

// Main line, and a branch that leaves it and merges back.
cg.move(to: CGPoint(x: 360, y: 250)); cg.addLine(to: CGPoint(x: 360, y: 790)); cg.strokePath()
let branch = CGMutablePath()
branch.move(to: CGPoint(x: 360, y: 340))
branch.addCurve(to: CGPoint(x: 620, y: 500), control1: CGPoint(x: 360, y: 450), control2: CGPoint(x: 620, y: 390))
branch.addLine(to: CGPoint(x: 620, y: 560))
branch.addCurve(to: CGPoint(x: 360, y: 720), control1: CGPoint(x: 620, y: 670), control2: CGPoint(x: 360, y: 610))
cg.setStrokeColor(CGColor(gray: 1, alpha: 0.75))
cg.addPath(branch); cg.strokePath()

// Commits.
cg.setFillColor(white)
for (x, y, r) in [(360.0, 270.0, 52.0), (620.0, 530.0, 52.0), (360.0, 760.0, 52.0)] {
    cg.fillEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
}

// Check badge: merged and safe to remove.
let badge = CGPoint(x: 690, y: 300), badgeRadius: CGFloat = 132
cg.saveGState()
cg.setShadow(offset: CGSize(width: 0, height: -6), blur: 16, color: CGColor(gray: 0, alpha: 0.25))
cg.setFillColor(white)
cg.fillEllipse(in: CGRect(x: badge.x - badgeRadius, y: badge.y - badgeRadius, width: 2 * badgeRadius, height: 2 * badgeRadius))
cg.restoreGState()
cg.setStrokeColor(CGColor(red: 0.10, green: 0.56, blue: 0.42, alpha: 1))
cg.setLineWidth(40)
cg.setLineJoin(.round)
cg.move(to: CGPoint(x: badge.x - 62, y: badge.y + 2))
cg.addLine(to: CGPoint(x: badge.x - 15, y: badge.y - 48))
cg.addLine(to: CGPoint(x: badge.x + 68, y: badge.y + 52))
cg.strokePath()
cg.restoreGState()

NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
