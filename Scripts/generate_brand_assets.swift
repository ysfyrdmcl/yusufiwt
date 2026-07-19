#!/usr/bin/env swift

import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

private let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()

private struct RGB {
    let red: CGFloat
    let green: CGFloat
    let blue: CGFloat

    var color: NSColor { NSColor(red: red, green: green, blue: blue, alpha: 1) }
}

private enum Palette {
    static let outer = RGB(red: 0.020, green: 0.043, blue: 0.094)
    static let navyTop = RGB(red: 0.063, green: 0.169, blue: 0.302)
    static let navyBottom = RGB(red: 0.027, green: 0.078, blue: 0.149)
    static let cyan = RGB(red: 0.208, green: 0.851, blue: 1)
    static let violet = RGB(red: 0.651, green: 0.420, blue: 1)
    static let merge = RGB(red: 0.455, green: 0.522, blue: 1)
}

private func scaledPoint(_ x: CGFloat, _ y: CGFloat, scale: CGFloat) -> NSPoint {
    NSPoint(x: x * scale, y: (1024 - y) * scale)
}

private func drawIcon(size: Int) throws -> Data {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bitmapFormat: [],
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw NSError(domain: "yusufiwt.brand", code: 1)
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    defer { NSGraphicsContext.restoreGraphicsState() }

    let scale = CGFloat(size) / 1024
    Palette.outer.color.setFill()
    NSBezierPath(rect: NSRect(x: 0, y: 0, width: size, height: size)).fill()

    let squircle = NSBezierPath(
        roundedRect: NSRect(x: 32 * scale, y: 32 * scale, width: 960 * scale, height: 960 * scale),
        xRadius: 224 * scale,
        yRadius: 224 * scale
    )
    NSGradient(starting: Palette.navyBottom.color, ending: Palette.navyTop.color)?.draw(in: squircle, angle: 60)
    NSColor.white.withAlphaComponent(0.08).setStroke()
    squircle.lineWidth = max(1, 10 * scale)
    squircle.stroke()

    func branch(from start: NSPoint, control1: NSPoint, control2: NSPoint, to end: NSPoint, color: NSColor) {
        let path = NSBezierPath()
        path.move(to: start)
        path.curve(to: end, controlPoint1: control1, controlPoint2: control2)
        path.lineWidth = max(1.25, 82 * scale)
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        color.setStroke()
        path.stroke()
    }

    let junction = scaledPoint(512, 520, scale: scale)
    branch(
        from: scaledPoint(280, 288, scale: scale),
        control1: scaledPoint(280, 410, scale: scale),
        control2: scaledPoint(402, 452, scale: scale),
        to: junction,
        color: Palette.cyan.color
    )
    branch(
        from: scaledPoint(744, 288, scale: scale),
        control1: scaledPoint(744, 410, scale: scale),
        control2: scaledPoint(622, 452, scale: scale),
        to: junction,
        color: Palette.violet.color
    )

    let trunk = NSBezierPath()
    trunk.move(to: junction)
    trunk.line(to: scaledPoint(512, 792, scale: scale))
    trunk.lineWidth = max(1.25, 82 * scale)
    trunk.lineCapStyle = .round
    Palette.merge.color.setStroke()
    trunk.stroke()

    func terminal(at point: NSPoint, color: NSColor) {
        let diameter = max(2.5, 116 * scale)
        let circle = NSBezierPath(ovalIn: NSRect(
            x: point.x - diameter / 2,
            y: point.y - diameter / 2,
            width: diameter,
            height: diameter
        ))
        color.setFill()
        circle.fill()
    }

    terminal(at: scaledPoint(280, 288, scale: scale), color: Palette.cyan.color)
    terminal(at: scaledPoint(744, 288, scale: scale), color: Palette.violet.color)
    terminal(at: scaledPoint(512, 792, scale: scale), color: Palette.merge.color)
    context.flushGraphics()

    guard let sourceImage = bitmap.cgImage,
          let opaqueContext = CGContext(
              data: nil,
              width: size,
              height: size,
              bitsPerComponent: 8,
              bytesPerRow: size * 4,
              space: CGColorSpaceCreateDeviceRGB(),
              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
          )
    else {
        throw NSError(domain: "yusufiwt.brand", code: 2)
    }
    opaqueContext.draw(sourceImage, in: CGRect(x: 0, y: 0, width: size, height: size))
    guard let opaqueImage = opaqueContext.makeImage() else {
        throw NSError(domain: "yusufiwt.brand", code: 3)
    }
    let output = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(
        output,
        UTType.png.identifier as CFString,
        1,
        nil
    ) else {
        throw NSError(domain: "yusufiwt.brand", code: 4)
    }
    CGImageDestinationAddImage(destination, opaqueImage, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw NSError(domain: "yusufiwt.brand", code: 5)
    }
    return output as Data
}

private func writeIcon(size: Int, relativePath: String) throws {
    let output = repoRoot.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
    try drawIcon(size: size).write(to: output, options: .atomic)
}

let macIconDirectory = "Apps/macOS/Assets.xcassets/AppIcon.appiconset"
for size in [16, 32, 64, 128, 256, 512, 1024] {
    try writeIcon(size: size, relativePath: "\(macIconDirectory)/AppIcon-\(size).png")
}
try writeIcon(size: 1024, relativePath: "Apps/iOS/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png")
try writeIcon(size: 1024, relativePath: "Apps/watchOS/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png")
try writeIcon(size: 512, relativePath: "Brand/yusufiwt-mark-preview.png")

print("Generated yusufiwt app icons and preview.")
