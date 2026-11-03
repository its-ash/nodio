// Draws the Nodio DMG window background. Usage: swift background.swift <out-prefix>
// Writes <out-prefix>.png (1x) and <out-prefix>@2x.png. Layout matches make.sh.
import AppKit

let W: CGFloat = 660, H: CGFloat = 440
let iconY: CGFloat = 150
let appX: CGFloat = 165, appsX: CGFloat = 495
let accent = NSColor(srgbRed: 0.0, green: 0.44, blue: 0.89, alpha: 1)
let muted = NSColor(srgbRed: 0.36, green: 0.37, blue: 0.42, alpha: 1)

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data((msg + "\n").utf8))
    exit(1)
}

/// Draws a line of text centered on the window, `top` points below the top edge.
func text(_ s: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, top: CGFloat) {
    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color]
    let sz = s.size(withAttributes: attrs)
    s.draw(at: NSPoint(x: (W - sz.width) / 2, y: H - top - sz.height), withAttributes: attrs)
}

func draw() {
    let bounds = NSRect(x: 0, y: 0, width: W, height: H)
    NSGradient(starting: NSColor(srgbRed: 0.99, green: 0.99, blue: 1, alpha: 1),
               ending: NSColor(srgbRed: 0.92, green: 0.94, blue: 0.97, alpha: 1))?.draw(in: bounds, angle: -90)

    text("Drag Nodio to Applications", size: 20, weight: .semibold, color: .black, top: 34)

    // Arrow from the app icon to the Applications folder.
    let y = H - iconY, start = appX + 72, tip = appsX - 66
    accent.setStroke()
    accent.setFill()
    let line = NSBezierPath()
    line.move(to: NSPoint(x: start, y: y))
    line.line(to: NSPoint(x: tip - 14, y: y))
    line.lineWidth = 5
    line.lineCapStyle = .round
    line.stroke()
    let head = NSBezierPath()
    head.move(to: NSPoint(x: tip, y: y))
    head.line(to: NSPoint(x: tip - 20, y: y + 13))
    head.line(to: NSPoint(x: tip - 20, y: y - 13))
    head.close()
    head.fill()

    // Divider above the help row.
    NSColor(white: 0, alpha: 0.08).setFill()
    NSRect(x: 40, y: H - 238, width: W - 80, height: 1).fill()

    text("If macOS says Nodio is damaged or cannot be opened:", size: 12, weight: .medium, color: muted, top: 384)
    text("double-click Fix Nodio.terminal, or follow Read Me.txt.", size: 12, weight: .regular, color: muted, top: 404)
}

func render(scale: CGFloat) -> Data {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(W * scale), pixelsHigh: Int(H * scale),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ), let ctx = NSGraphicsContext(bitmapImageRep: rep) else { fail("Cannot create bitmap") }
    rep.size = NSSize(width: W, height: H)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    draw()
    NSGraphicsContext.restoreGraphicsState()
    guard let png = rep.representation(using: .png, properties: [:]) else { fail("Cannot encode PNG") }
    return png
}

let args = CommandLine.arguments
guard args.count == 2, !args[1].isEmpty else { fail("usage: swift background.swift <out-prefix>") }
do {
    try render(scale: 1).write(to: URL(fileURLWithPath: args[1] + ".png"))
    try render(scale: 2).write(to: URL(fileURLWithPath: args[1] + "@2x.png"))
} catch {
    fail("Cannot write background: \(error.localizedDescription)")
}
