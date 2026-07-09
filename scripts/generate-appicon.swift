#!/usr/bin/env swift
// Regenerates MCPDeck/Resources/Assets.xcassets/AppIcon.appiconset/*.png.
// Pure AppKit drawing so the icon is reproducible from source with no design
// tool: macOS-style squircle, indigo→blue gradient, white 3D-stack glyph.
import AppKit

let iconSizes: [(name: String, points: Int, scale: Int)] = [
    ("icon_16", 16, 1), ("icon_16@2x", 16, 2),
    ("icon_32", 32, 1), ("icon_32@2x", 32, 2),
    ("icon_128", 128, 1), ("icon_128@2x", 128, 2),
    ("icon_256", 256, 1), ("icon_256@2x", 256, 2),
    ("icon_512", 512, 1), ("icon_512@2x", 512, 2),
]

let outputDirectory = URL(filePath: CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "MCPDeck/Resources/Assets.xcassets/AppIcon.appiconset")

func drawIcon(pixels: Int) -> NSBitmapImageRep {
    let size = CGFloat(pixels)
    // Draw into an explicit bitmap: lockFocus would inherit the Retina
    // display's 2x backing scale and double every output size.
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .calibratedRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { fatalError("Could not create bitmap") }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)

    // Apple's macOS icon grid: the squircle fills ~80% of the canvas.
    let inset = size * 0.10
    let squircleRect = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let squircle = NSBezierPath(roundedRect: squircleRect, xRadius: size * 0.185, yRadius: size * 0.185)

    NSGradient(
        starting: NSColor(calibratedRed: 0.32, green: 0.28, blue: 0.86, alpha: 1),
        ending: NSColor(calibratedRed: 0.10, green: 0.52, blue: 0.95, alpha: 1)
    )?.draw(in: squircle, angle: -90)

    // Subtle top highlight for depth.
    NSGradient(
        starting: NSColor(calibratedWhite: 1, alpha: 0.18),
        ending: NSColor(calibratedWhite: 1, alpha: 0)
    )?.draw(in: squircle, angle: -90)

    if let symbol = NSImage(systemSymbolName: "square.stack.3d.up.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: size * 0.42, weight: .medium)) {
        let tinted = NSImage(size: symbol.size)
        tinted.lockFocus()
        NSColor.white.set()
        let symbolRect = NSRect(origin: .zero, size: symbol.size)
        symbol.draw(in: symbolRect)
        symbolRect.fill(using: .sourceAtop)
        tinted.unlockFocus()

        let glyphWidth = size * 0.52
        let glyphHeight = glyphWidth * (symbol.size.height / symbol.size.width)
        tinted.draw(in: NSRect(
            x: (size - glyphWidth) / 2,
            y: (size - glyphHeight) / 2,
            width: glyphWidth,
            height: glyphHeight
        ))
    }

    NSGraphicsContext.restoreGraphicsState()
    return bitmap
}

try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

for spec in iconSizes {
    let pixels = spec.points * spec.scale
    let bitmap = drawIcon(pixels: pixels)
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        fatalError("Could not encode \(spec.name)")
    }
    try png.write(to: outputDirectory.appending(path: "\(spec.name).png"))
    print("wrote \(spec.name).png (\(pixels)x\(pixels))")
}
