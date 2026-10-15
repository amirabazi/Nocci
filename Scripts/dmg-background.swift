// Draws the background of Nocci's disk image window: the app icon's slate
// gradient and glow, an arrow from the app to Applications, and a caption.
// Finder picks the colour of each icon's name itself (black on macOS 27, even
// in dark mode, but white on some setups), so the name sits on a mid-tone tag
// that both read on at 4.5:1.
//
// Run by Scripts/build-dmg.sh, which passes the window layout:
//   dmg-background <output.png> <width> <height> <app-x> <applications-x> <icon-y> <icon-size>
// It writes <output.png> and <output>@2x.png beside it.
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

let arguments = CommandLine.arguments
guard arguments.count == 8, let width = Double(arguments[2]), let height = Double(arguments[3]),
      let appX = Double(arguments[4]), let applicationsX = Double(arguments[5]),
      let iconY = Double(arguments[6]), let iconSize = Double(arguments[7]) else {
    FileHandle.standardError.write(Data("Usage: dmg-background <output.png> <width> <height> <app-x> <applications-x> <icon-y> <icon-size>\n".utf8))
    exit(1)
}
let space = CGColorSpace(name: CGColorSpace.sRGB)!

func gradient(_ colours: [Colour]) -> CGGradient {
    CGGradient(colorsSpace: space, colors: colours.map(\.cg) as CFArray, locations: nil)!
}

/// y grows downwards, as Finder places icons.
func draw(in context: CGContext) {
    let full = CGRect(x: 0, y: 0, width: width, height: height)
    context.drawLinearGradient(gradient([Colour(0x2E3441), Colour(0x12151A)]), start: .zero,
                               end: CGPoint(x: 0, y: height), options: [])
    let glow = Colour(0x7C93C4)
    context.drawRadialGradient(gradient([glow.with(alpha: 0.28), glow.with(alpha: 0)]),
                               startCenter: CGPoint(x: width / 2, y: iconY - 40), startRadius: 0,
                               endCenter: CGPoint(x: width / 2, y: iconY - 40), endRadius: width * 0.55, options: [])
    context.clip(to: full)

    // The arrow, between the two icons at their centre line.
    let start = appX + iconSize / 2 + 28, end = applicationsX - iconSize / 2 - 28
    let arrow = CGMutablePath()
    arrow.move(to: CGPoint(x: start, y: iconY))
    arrow.addLine(to: CGPoint(x: end, y: iconY))
    arrow.move(to: CGPoint(x: end - 14, y: iconY - 14))
    arrow.addLine(to: CGPoint(x: end, y: iconY))
    arrow.addLine(to: CGPoint(x: end - 14, y: iconY + 14))
    context.addPath(arrow)
    context.setStrokeColor(Colour(0xFFFFFF, alpha: 0.42).cg)
    context.setLineWidth(5)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.strokePath()

    // A tag under each icon's name. #6E7787 has a relative luminance of
    // 0.183: 4.5:1 against white text and 4.6:1 against black.
    for x in [appX, applicationsX] {
        let tag = CGRect(x: x - 52, y: iconY + iconSize / 2 + 8, width: 104, height: 22)
        context.addPath(CGPath(roundedRect: tag, cornerWidth: 11, cornerHeight: 11, transform: nil))
        context.setFillColor(Colour(0x6E7787).cg)
        context.fillPath()
    }

    let caption = NSAttributedString(string: "Drag Nocci to Applications", attributes: [
        .font: NSFont.systemFont(ofSize: 15, weight: .medium),
        .foregroundColor: NSColor(white: 1, alpha: 0.78),
    ])
    let size = caption.size()
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
    caption.draw(at: CGPoint(x: (width - size.width) / 2, y: iconY + iconSize / 2 + 66))
    NSGraphicsContext.restoreGraphicsState()
}

func png(scale: Int) -> Data {
    let context = CGContext(data: nil, width: Int(width) * scale, height: Int(height) * scale, bitsPerComponent: 8,
                            bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.translateBy(x: 0, y: CGFloat(Int(height) * scale))
    context.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))
    draw(in: context)
    let rep = NSBitmapImageRep(cgImage: context.makeImage()!)
    rep.size = NSSize(width: width, height: height)
    return rep.representation(using: .png, properties: [:])!
}

let output = URL(fileURLWithPath: arguments[1])
let retina = output.deletingPathExtension().path + "@2x.png"
try png(scale: 1).write(to: output)
try png(scale: 2).write(to: URL(fileURLWithPath: retina))
print("Wrote \(output.path) and \(retina)")
