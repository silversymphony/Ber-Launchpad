import AppKit
import Foundation

guard CommandLine.arguments.count >= 2 else {
    fputs("Usage: swift generate_icon.swift <output.iconset>\n", stderr)
    exit(1)
}

let iconsetPath = CommandLine.arguments[1]
let fm = FileManager.default
try? fm.removeItem(atPath: iconsetPath)
try fm.createDirectory(atPath: iconsetPath, withIntermediateDirectories: true)

func renderIcon(pixelSize: Int) -> Data? {
    let size = CGFloat(pixelSize)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelSize,
        pixelsHigh: pixelSize,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { return nil }

    NSGraphicsContext.saveGraphicsState()
    guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else {
        NSGraphicsContext.restoreGraphicsState()
        return nil
    }
    NSGraphicsContext.current = ctx
    let cg = ctx.cgContext

    // Standard macOS Big Sur / Sequoia icon inset (~100/1024 margin)
    let margin = size * 0.097
    let boxRect = CGRect(x: margin, y: margin, width: size - margin * 2, height: size - margin * 2)
    let cornerRadius = boxRect.width * 0.225

    // Drop shadow behind main squircle
    cg.saveGState()
    cg.setShadow(
        offset: CGSize(width: 0, height: -size * 0.02),
        blur: size * 0.04,
        color: NSColor.black.withAlphaComponent(0.38).cgColor
    )
    let outerPath = NSBezierPath(roundedRect: boxRect, xRadius: cornerRadius, yRadius: cornerRadius)
    NSColor(calibratedWhite: 0.92, alpha: 1.0).setFill()
    outerPath.fill()
    cg.restoreGState()

    // Outer metallic silver-white gradient frame
    cg.saveGState()
    outerPath.addClip()
    let bgGrad = NSGradient(colors: [
        NSColor(calibratedRed: 0.97, green: 0.98, blue: 1.0, alpha: 1.0),
        NSColor(calibratedRed: 0.85, green: 0.87, blue: 0.91, alpha: 1.0)
    ])
    bgGrad?.draw(in: boxRect, angle: -90)
    cg.restoreGState()

    // Inner dark glass plate
    let innerInset = boxRect.width * 0.055
    let innerRect = boxRect.insetBy(dx: innerInset, dy: innerInset)
    let innerRadius = cornerRadius * 0.84
    let innerPath = NSBezierPath(roundedRect: innerRect, xRadius: innerRadius, yRadius: innerRadius)

    cg.saveGState()
    innerPath.addClip()
    let darkGrad = NSGradient(colors: [
        NSColor(calibratedRed: 0.14, green: 0.16, blue: 0.22, alpha: 1.0),
        NSColor(calibratedRed: 0.09, green: 0.10, blue: 0.14, alpha: 1.0)
    ])
    darkGrad?.draw(in: innerRect, angle: -90)
    cg.restoreGState()

    // Inner subtle highlight border
    NSColor.white.withAlphaComponent(0.25).setStroke()
    innerPath.lineWidth = max(1, size * 0.004)
    innerPath.stroke()

    // Iconic Launchpad 3x3 colorful rounded tiles
    let tileColors: [[(NSColor, NSColor)]] = [
        // Top row (CG coordinates: y=0 at bottom, so row 2 is top)
        [
            (NSColor(calibratedRed: 0.98, green: 0.36, blue: 0.38, alpha: 1), NSColor(calibratedRed: 0.85, green: 0.18, blue: 0.24, alpha: 1)),
            (NSColor(calibratedRed: 1.00, green: 0.62, blue: 0.22, alpha: 1), NSColor(calibratedRed: 0.92, green: 0.42, blue: 0.08, alpha: 1)),
            (NSColor(calibratedRed: 0.99, green: 0.84, blue: 0.26, alpha: 1), NSColor(calibratedRed: 0.90, green: 0.66, blue: 0.08, alpha: 1))
        ],
        // Middle row
        [
            (NSColor(calibratedRed: 0.82, green: 0.38, blue: 0.95, alpha: 1), NSColor(calibratedRed: 0.62, green: 0.20, blue: 0.82, alpha: 1)),
            (NSColor(calibratedRed: 0.24, green: 0.78, blue: 0.96, alpha: 1), NSColor(calibratedRed: 0.10, green: 0.54, blue: 0.86, alpha: 1)),
            (NSColor(calibratedRed: 0.30, green: 0.86, blue: 0.48, alpha: 1), NSColor(calibratedRed: 0.14, green: 0.68, blue: 0.32, alpha: 1))
        ],
        // Bottom row
        [
            (NSColor(calibratedRed: 0.36, green: 0.54, blue: 0.98, alpha: 1), NSColor(calibratedRed: 0.20, green: 0.34, blue: 0.86, alpha: 1)),
            (NSColor(calibratedRed: 0.22, green: 0.84, blue: 0.78, alpha: 1), NSColor(calibratedRed: 0.08, green: 0.64, blue: 0.62, alpha: 1)),
            (NSColor(calibratedRed: 0.96, green: 0.42, blue: 0.72, alpha: 1), NSColor(calibratedRed: 0.80, green: 0.20, blue: 0.54, alpha: 1))
        ]
    ]

    let gridPadding = innerRect.width * 0.145
    let gap = innerRect.width * 0.08
    let usableW = innerRect.width - gridPadding * 2 - gap * 2
    let tileSize = usableW / 3.0
    let tileCorner = tileSize * 0.26

    for row in 0..<3 {
        for col in 0..<3 {
            let x = innerRect.minX + gridPadding + CGFloat(col) * (tileSize + gap)
            // row 0 = bottom, row 2 = top
            let y = innerRect.minY + gridPadding + CGFloat(row) * (tileSize + gap)
            let tileRect = CGRect(x: x, y: y, width: tileSize, height: tileSize)
            let tilePath = NSBezierPath(roundedRect: tileRect, xRadius: tileCorner, yRadius: tileCorner)

            cg.saveGState()
            cg.setShadow(
                offset: CGSize(width: 0, height: -size * 0.008),
                blur: size * 0.015,
                color: NSColor.black.withAlphaComponent(0.45).cgColor
            )
            NSColor.black.setFill()
            tilePath.fill()
            cg.restoreGState()

            let (topCol, botCol) = tileColors[2 - row][col]
            cg.saveGState()
            tilePath.addClip()
            let tGrad = NSGradient(colors: [topCol, botCol])
            tGrad?.draw(in: tileRect, angle: -90)
            cg.restoreGState()

            // Specular highlight
            NSColor.white.withAlphaComponent(0.32).setStroke()
            tilePath.lineWidth = max(0.75, size * 0.003)
            tilePath.stroke()
        }
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

let specs: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

for (filename, px) in specs {
    guard let data = renderIcon(pixelSize: px) else {
        fputs("Failed to render \(filename)\n", stderr)
        exit(1)
    }
    let outURL = URL(fileURLWithPath: iconsetPath).appendingPathComponent(filename)
    try data.write(to: outURL)
}

print("Generated iconset at \(iconsetPath)")
