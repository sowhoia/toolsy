// Draws the app icon and writes Resources/AppIcon.icns.
//
//   swift scripts/make-icon.swift
//
// The icon is a 2×2 set of module tiles, one of them switched on: what the panel looks like.
import AppKit
import SwiftUI

let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appending(path: "Toolsy-\(UUID().uuidString).iconset")
let output = root.appending(path: "Resources/AppIcon.icns")

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255, alpha: alpha
    )
}

func squircle(_ rect: CGRect, radius: CGFloat) -> CGPath {
    RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: rect).cgPath
}

func gradient(_ colors: [CGColor]) -> CGGradient {
    guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: nil) else {
        fatalError("cannot create gradient")
    }
    return gradient
}

/// Draws the icon on a 1024-point canvas; the context is scaled for the requested pixel size.
func draw(in context: CGContext) {
    // The macOS icon grid: an 824-point rounded square centred on the 1024 canvas.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = squircle(body, radius: 185)

    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35))
    context.addPath(bodyPath)
    context.setFillColor(color(0x1C1C22))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(bodyPath)
    context.clip()
    context.drawLinearGradient(
        gradient([color(0x4B4D5E), color(0x23242D), color(0x121217)]),
        start: CGPoint(x: body.midX, y: body.maxY), end: CGPoint(x: body.midX, y: body.minY), options: []
    )
    // A soft light from the top-left, as if the surface were glass.
    context.drawRadialGradient(
        gradient([color(0xFFFFFF, 0.20), color(0xFFFFFF, 0)]),
        startCenter: CGPoint(x: body.minX + 200, y: body.maxY - 120), startRadius: 0,
        endCenter: CGPoint(x: body.minX + 200, y: body.maxY - 120), endRadius: 620, options: []
    )
    context.restoreGState()

    let tile: CGFloat = 268
    let gap: CGFloat = 56
    let origin = CGPoint(x: body.midX - tile - gap / 2, y: body.midY - tile - gap / 2)
    for row in 0..<2 {
        for column in 0..<2 {
            let rect = CGRect(
                x: origin.x + CGFloat(column) * (tile + gap), y: origin.y + CGFloat(row) * (tile + gap),
                width: tile, height: tile
            )
            let path = squircle(rect, radius: 78)
            let isOn = row == 1 && column == 0  // top-left in screen terms (y grows upwards here)

            context.saveGState()
            context.addPath(path)
            context.clip()
            if isOn {
                context.drawLinearGradient(
                    gradient([color(0x5BE584), color(0x25B556)]),
                    start: CGPoint(x: rect.midX, y: rect.maxY), end: CGPoint(x: rect.midX, y: rect.minY), options: []
                )
            } else {
                context.drawLinearGradient(
                    gradient([color(0xFFFFFF, 0.34), color(0xFFFFFF, 0.14)]),
                    start: CGPoint(x: rect.midX, y: rect.maxY), end: CGPoint(x: rect.midX, y: rect.minY), options: []
                )
            }
            context.restoreGState()

            // The bright upper rim that makes a tile read as a lens rather than a flat square.
            context.saveGState()
            context.addPath(path)
            context.clip()
            context.addPath(squircle(rect.insetBy(dx: 3, dy: 3), radius: 75))
            context.setLineWidth(6)
            context.replacePathWithStrokedPath()
            context.clip()
            context.drawLinearGradient(
                gradient([color(0xFFFFFF, isOn ? 0.55 : 0.50), color(0xFFFFFF, 0.04)]),
                start: CGPoint(x: rect.minX, y: rect.maxY), end: CGPoint(x: rect.maxX, y: rect.minY), options: []
            )
            context.restoreGState()

            if isOn {
                // The thumb of a switch, resting at "on".
                let thumb = CGRect(x: rect.midX - 66, y: rect.midY - 46, width: 132, height: 92)
                context.saveGState()
                context.setShadow(offset: CGSize(width: 0, height: -6), blur: 14, color: color(0x0A5A28, 0.45))
                context.addPath(CGPath(roundedRect: thumb, cornerWidth: 46, cornerHeight: 46, transform: nil))
                context.setFillColor(color(0xFFFFFF))
                context.fillPath()
                context.restoreGState()
            }
        }
    }
}

func png(pixels: Int) -> Data {
    guard let context = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        fatalError("cannot create a \(pixels)-pixel bitmap")
    }
    context.interpolationQuality = .high
    context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    draw(in: context)
    guard let image = context.makeImage(),
          let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
        fatalError("cannot encode a \(pixels)-pixel PNG")
    }
    return data
}

try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }
for points in [16, 32, 128, 256, 512] {
    try png(pixels: points).write(to: iconset.appending(path: "icon_\(points)x\(points).png"))
    try png(pixels: points * 2).write(to: iconset.appending(path: "icon_\(points)x\(points)@2x.png"))
}

let iconutil = Process()
iconutil.executableURL = URL(filePath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path(percentEncoded: false), "-o", output.path(percentEncoded: false)]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    fatalError("iconutil failed with status \(iconutil.terminationStatus)")
}
print(output.path(percentEncoded: false))
