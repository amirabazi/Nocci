// Draws Nocci's app icon and writes Assets/AppIcon.icns. The icon is original
// artwork: a black notch hanging from the top of a dark screen, with a white
// and an orange usage ring beside the camera. It uses no provider mark.
//
// Run from the checkout after changing the drawing:
//   swiftc -module-cache-path .build/module-cache Scripts/app-icon.swift -o .build/app-icon
//   .build/app-icon Assets/AppIcon.icns
import AppKit
import CoreGraphics

struct Colour {
    var red, green, blue: CGFloat
    var alpha: CGFloat = 1
    init(_ hex: UInt32, alpha: CGFloat = 1) {
        red = CGFloat((hex >> 16) & 0xFF) / 255
        green = CGFloat((hex >> 8) & 0xFF) / 255
        blue = CGFloat(hex & 0xFF) / 255
        self.alpha = alpha
    }
    func with(alpha: CGFloat) -> Colour { var copy = self; copy.alpha = alpha; return copy }
    var cg: CGColor { CGColor(red: red, green: green, blue: blue, alpha: alpha) }
}

// Apple's 1024-point icon grid: an 824-point rounded body with a 100-point margin.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let bodyRadius: CGFloat = 185
let space = CGColorSpace(name: CGColorSpace.sRGB)!

/// The notch's outline, as the panel draws it: full width at the top edge, a
/// concave flare into each side, rounded bottom corners. y grows downwards.
func notch(left: CGFloat, right: CGFloat, top: CGFloat, height: CGFloat, flare: CGFloat, bottom: CGFloat) -> CGPath {
    let path = CGMutablePath()
    path.move(to: CGPoint(x: left - flare, y: top - 2))
    path.addLine(to: CGPoint(x: right + flare, y: top - 2))
    path.addLine(to: CGPoint(x: right + flare, y: top))
    path.addQuadCurve(to: CGPoint(x: right, y: top + flare), control: CGPoint(x: right, y: top))
    path.addLine(to: CGPoint(x: right, y: top + height - bottom))
    path.addQuadCurve(to: CGPoint(x: right - bottom, y: top + height), control: CGPoint(x: right, y: top + height))
    path.addLine(to: CGPoint(x: left + bottom, y: top + height))
    path.addQuadCurve(to: CGPoint(x: left, y: top + height - bottom), control: CGPoint(x: left, y: top + height))
    path.addLine(to: CGPoint(x: left, y: top + flare))
    path.addQuadCurve(to: CGPoint(x: left - flare, y: top), control: CGPoint(x: left, y: top))
    path.closeSubpath()
    return path
}

func gradient(_ colours: [Colour]) -> CGGradient {
    CGGradient(colorsSpace: space, colors: colours.map(\.cg) as CFArray, locations: nil)!
}

/// A usage ring like the compact strip's: a faint track and a clockwise arc from twelve o'clock.
func ring(_ context: CGContext, center: CGPoint, radius: CGFloat, width: CGFloat, fraction: CGFloat, colour: Colour) {
    context.setLineWidth(width)
    context.setLineCap(.round)
    context.setStrokeColor(Colour(0xFFFFFF, alpha: 0.16).cg)
    context.strokeEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    context.setStrokeColor(colour.cg)
    let start = -CGFloat.pi / 2
    context.addArc(center: center, radius: radius, startAngle: start, endAngle: start + 2 * .pi * fraction, clockwise: false)
    context.strokePath()
}

func draw(in context: CGContext) {
    let shape = CGPath(roundedRect: body, cornerWidth: bodyRadius, cornerHeight: bodyRadius, transform: nil)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: 12), blur: 28, color: Colour(0x000000, alpha: 0.35).cg)
    context.addPath(shape)
    context.setFillColor(Colour(0x000000).cg)
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(shape)
    context.clip()
    context.drawLinearGradient(gradient([Colour(0x404859), Colour(0x101217)]), start: CGPoint(x: 512, y: 100),
                               end: CGPoint(x: 512, y: 924), options: [])
    let glow = Colour(0x7C93C4)
    context.drawRadialGradient(gradient([glow.with(alpha: 0.4), glow.with(alpha: 0)]),
                               startCenter: CGPoint(x: 512, y: 330), startRadius: 0,
                               endCenter: CGPoint(x: 512, y: 330), endRadius: 460, options: [])
    // The notch hangs from the flat part of the top edge, clear of the
    // rounded corners, so its flares show.
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: 14), blur: 36, color: Colour(0x000000, alpha: 0.6).cg)
    context.addPath(notch(left: 250, right: 774, top: 100, height: 250, flare: 46, bottom: 92))
    context.setFillColor(Colour(0x000000).cg)
    context.fillPath()
    context.restoreGState()
    // The camera: a dark lens with a hint of blue glass.
    context.setFillColor(Colour(0x1B1E25).cg)
    context.fillEllipse(in: CGRect(x: 495, y: 151, width: 34, height: 34))
    context.setFillColor(Colour(0x3A4A6A, alpha: 0.9).cg)
    context.fillEllipse(in: CGRect(x: 508, y: 158, width: 14, height: 14))
    ring(context, center: CGPoint(x: 350, y: 222), radius: 58, width: 24, fraction: 0.62, colour: Colour(0xFFFFFF, alpha: 0.94))
    ring(context, center: CGPoint(x: 674, y: 222), radius: 58, width: 24, fraction: 0.9, colour: Colour(0xFF9F0A))
    context.restoreGState()

    // A hairline where light catches the body's edge.
    context.addPath(CGPath(roundedRect: body.insetBy(dx: 1.5, dy: 1.5), cornerWidth: bodyRadius - 1.5,
                           cornerHeight: bodyRadius - 1.5, transform: nil))
    context.setStrokeColor(Colour(0xFFFFFF, alpha: 0.12).cg)
    context.setLineWidth(3)
    context.strokePath()
}

/// Each size is drawn from the vector shapes, not scaled down from 1024.
func png(pixels: Int) -> Data {
    let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.translateBy(x: 0, y: CGFloat(pixels))
    context.scaleBy(x: CGFloat(pixels) / 1024, y: -CGFloat(pixels) / 1024)
    draw(in: context)
    return NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!
}

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("Usage: app-icon <output.icns>\n".utf8))
    exit(1)
}
let output = URL(fileURLWithPath: CommandLine.arguments[1])
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }
for points in [16, 32, 128, 256, 512] {
    try png(pixels: points).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try png(pixels: points * 2).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { exit(iconutil.terminationStatus) }
print("Wrote \(output.path)")
