// Draws the MacFanPilot app icon and writes the AppIcon set.
// Usage: swift scripts/make-icon.swift App/Assets.xcassets/AppIcon.appiconset

import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

func drawIcon(size: Int) -> CGImage {
    let s = CGFloat(size)
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: s / 1024, y: s / 1024)   // draw on a 1024 pt canvas

    // macOS icon grid: an 824 pt rounded square centred on the canvas.
    let plate = CGRect(x: 100, y: 100, width: 824, height: 824)
    let platePath = CGPath(roundedRect: plate, cornerWidth: 185, cornerHeight: 185, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 24, color: CGColor(gray: 0, alpha: 0.3))
    ctx.addPath(platePath)
    ctx.setFillColor(CGColor(srgbRed: 0.05, green: 0.15, blue: 0.25, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(platePath)
    ctx.clip()
    let colors = [CGColor(srgbRed: 0.16, green: 0.62, blue: 0.78, alpha: 1),
                  CGColor(srgbRed: 0.05, green: 0.20, blue: 0.40, alpha: 1)] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    ctx.restoreGState()

    let center = CGPoint(x: 512, y: 512)
    let r: CGFloat = 285

    // Shroud ring
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.28))
    ctx.setLineWidth(22)
    ctx.strokeEllipse(in: CGRect(x: center.x - 330, y: center.y - 330, width: 660, height: 660))

    // Blades
    ctx.setFillColor(CGColor(gray: 1, alpha: 0.96))
    let blades = 4
    for k in 0..<blades {
        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        ctx.rotate(by: CGFloat(k) * 2 * .pi / CGFloat(blades))
        // A swept blade: convex leading edge out to the tip, tighter trailing edge back to the hub.
        let blade = CGMutablePath()
        blade.move(to: CGPoint(x: -0.08 * r, y: 0.18 * r))
        blade.addCurve(to: CGPoint(x: 0.62 * r, y: 0.78 * r),
                       control1: CGPoint(x: -0.30 * r, y: 0.66 * r), control2: CGPoint(x: 0.24 * r, y: 1.10 * r))
        blade.addCurve(to: CGPoint(x: 0.19 * r, y: 0.06 * r),
                       control1: CGPoint(x: 0.50 * r, y: 0.50 * r), control2: CGPoint(x: 0.34 * r, y: 0.24 * r))
        blade.closeSubpath()
        ctx.addPath(blade)
        ctx.fillPath()
        ctx.restoreGState()
    }

    // Hub
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.fillEllipse(in: CGRect(x: center.x - 0.25 * r, y: center.y - 0.25 * r, width: 0.5 * r, height: 0.5 * r))
    ctx.setFillColor(CGColor(srgbRed: 0.08, green: 0.32, blue: 0.52, alpha: 1))
    ctx.fillEllipse(in: CGRect(x: center.x - 0.10 * r, y: center.y - 0.10 * r, width: 0.2 * r, height: 0.2 * r))

    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("could not write \(url.path)") }
}

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: make-icon.swift <AppIcon.appiconset>\n".utf8))
    exit(2)
}
let out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        writePNG(drawIcon(size: points * scale), to: out.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: out.appendingPathComponent("Contents.json"))
print("wrote \(images.count) icons to \(out.path)")
