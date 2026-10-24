#!/usr/bin/env swift

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

private let canvas: CGFloat = 1024

private func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(red: red, green: green, blue: blue, alpha: alpha)
}

private func drawIcon(pixelSize: Int) throws -> CGImage {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
        data: nil,
        width: pixelSize,
        height: pixelSize,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw IconError.contextCreationFailed
    }

    context.setAllowsAntialiasing(true)
    context.interpolationQuality = .high
    context.scaleBy(x: CGFloat(pixelSize) / canvas, y: CGFloat(pixelSize) / canvas)

    let background = CGPath(
        roundedRect: CGRect(x: 40, y: 40, width: canvas - 80, height: canvas - 80),
        cornerWidth: 210,
        cornerHeight: 210,
        transform: nil
    )
    context.addPath(background)
    context.clip()

    let gradient = CGGradient(
        colorsSpace: colorSpace,
        colors: [
            color(0.08, 0.25, 0.78),
            color(0.00, 0.62, 0.78),
        ] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: 140, y: 920),
        end: CGPoint(x: 890, y: 80),
        options: []
    )

    // Bar chart: usage, the signal this app reads from Codex.
    context.setFillColor(color(1, 1, 1, 0.94))
    let barWidth: CGFloat = 128
    let baseline: CGFloat = 220
    let heights: [CGFloat] = [250, 390, 530]
    for (index, height) in heights.enumerated() {
        let bar = CGRect(
            x: 175 + CGFloat(index) * 152,
            y: baseline,
            width: barWidth,
            height: height
        )
        context.addPath(
            CGPath(roundedRect: bar, cornerWidth: 34, cornerHeight: 34, transform: nil)
        )
        context.fillPath()
    }

    // Reset badge: a circular arrow in the upper-right corner.
    let badgeCenter = CGPoint(x: 780, y: 770)
    let badgeRadius: CGFloat = 128
    context.setFillColor(color(1, 1, 1))
    context.fillEllipse(
        in: CGRect(
            x: badgeCenter.x - badgeRadius,
            y: badgeCenter.y - badgeRadius,
            width: badgeRadius * 2,
            height: badgeRadius * 2
        )
    )

    let ringColor = color(0.02, 0.42, 0.73)
    let ringRadius: CGFloat = 68
    let ringWidth: CGFloat = 24
    let endAngle = CGFloat.pi * 1.75
    context.setStrokeColor(ringColor)
    context.setLineWidth(ringWidth)
    context.setLineCap(.round)
    context.addArc(
        center: badgeCenter,
        radius: ringRadius,
        startAngle: 0,
        endAngle: endAngle,
        clockwise: false
    )
    context.strokePath()

    let tangent = CGPoint(x: -sin(endAngle), y: cos(endAngle))
    let perpendicular = CGPoint(x: -tangent.y, y: tangent.x)
    let tip = CGPoint(
        x: badgeCenter.x + cos(endAngle) * ringRadius,
        y: badgeCenter.y + sin(endAngle) * ringRadius
    )
    let arrow = CGMutablePath()
    arrow.move(to: CGPoint(x: tip.x + tangent.x * 54, y: tip.y + tangent.y * 54))
    arrow.addLine(to: CGPoint(
        x: tip.x + perpendicular.x * 36,
        y: tip.y + perpendicular.y * 36
    ))
    arrow.addLine(to: CGPoint(
        x: tip.x - perpendicular.x * 36,
        y: tip.y - perpendicular.y * 36
    ))
    arrow.closeSubpath()
    context.setFillColor(ringColor)
    context.addPath(arrow)
    context.fillPath()

    guard let image = context.makeImage() else {
        throw IconError.imageCreationFailed
    }
    return image
}

private func writePNG(_ image: CGImage, to url: URL) throws {
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil
    ) else {
        throw IconError.pngDestinationFailed
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw IconError.pngWriteFailed
    }
}

private func runIconutil(iconset: URL, output: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    process.arguments = ["-c", "icns", iconset.path, "-o", output.path]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw IconError.iconutilFailed(Int(process.terminationStatus))
    }
}

private func main() throws {
    let outputURL: URL
    if CommandLine.arguments.count > 1 {
        outputURL = URL(fileURLWithPath: CommandLine.arguments[1])
    } else {
        outputURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Resources/AppIcon.icns")
    }

    let temporary = FileManager.default.temporaryDirectory
        .appendingPathComponent("CodexResetTray-AppIcon-\(UUID().uuidString)", isDirectory: true)
    let iconset = temporary.appendingPathComponent("AppIcon.iconset", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: temporary) }

    try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
        at: outputURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )

    let sizes: [(pixels: Int, name: String)] = [
        (16, "icon_16x16.png"),
        (32, "icon_16x16@2x.png"),
        (32, "icon_32x32.png"),
        (64, "icon_32x32@2x.png"),
        (128, "icon_128x128.png"),
        (256, "icon_128x128@2x.png"),
        (256, "icon_256x256.png"),
        (512, "icon_256x256@2x.png"),
        (512, "icon_512x512.png"),
        (1024, "icon_512x512@2x.png"),
    ]

    for size in sizes {
        let image = try drawIcon(pixelSize: size.pixels)
        try writePNG(image, to: iconset.appendingPathComponent(size.name))
    }

    try runIconutil(iconset: iconset, output: outputURL)
    print("Wrote \(outputURL.path)")
}

private enum IconError: LocalizedError {
    case contextCreationFailed
    case imageCreationFailed
    case pngDestinationFailed
    case pngWriteFailed
    case iconutilFailed(Int)

    var errorDescription: String? {
        switch self {
        case .contextCreationFailed: return "Could not create the icon drawing context."
        case .imageCreationFailed: return "Could not rasterize the icon."
        case .pngDestinationFailed: return "Could not create a PNG destination."
        case .pngWriteFailed: return "Could not write an icon PNG."
        case .iconutilFailed(let status): return "iconutil failed with status \(status)."
        }
    }
}

do {
    try main()
} catch {
    FileHandle.standardError.write(Data("Icon generation failed: \(error.localizedDescription)\n".utf8))
    exit(1)
}
