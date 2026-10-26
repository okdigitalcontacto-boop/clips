// Clips · © 2026 OK Digital. Todos los derechos reservados.
import AppKit
// Genera el .iconset: un clip vertical blanco con un play coral sobre el degradado de la app.
let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

let coral = NSColor(red: 1.0, green: 0.36, blue: 0.22, alpha: 1)
let magenta = NSColor(red: 0.86, green: 0.25, blue: 0.52, alpha: 1)
let indigo = NSColor(red: 0.36, green: 0.33, blue: 0.9, alpha: 1)

func draw(_ s: CGFloat) -> NSImage {
    NSImage(size: NSSize(width: s, height: s), flipped: false) { _ in
        let k = s / 1024
        // Plantilla de iconos de macOS: 824×824 centrado, esquinas continuas.
        let base = NSRect(x: 100 * k, y: 100 * k, width: 824 * k, height: 824 * k)
        let squircle = NSBezierPath(roundedRect: base, xRadius: 185 * k, yRadius: 185 * k)

        NSGraphicsContext.saveGraphicsState()
        let drop = NSShadow()
        drop.shadowColor = NSColor.black.withAlphaComponent(0.3); drop.shadowBlurRadius = 24 * k; drop.shadowOffset = NSSize(width: 0, height: -10 * k)
        drop.set()
        indigo.setFill(); squircle.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGradient(colors: [coral, magenta, indigo], atLocations: [0, 0.48, 1], colorSpace: .sRGB)!.draw(in: squircle, angle: -62)
        // Clip vertical: tarjeta blanca en primer plano.
        let tall = NSRect(x: 376 * k, y: 270 * k, width: 272 * k, height: 484 * k)
        let tallPath = NSBezierPath(roundedRect: tall, xRadius: 56 * k, yRadius: 56 * k)
        NSGraphicsContext.saveGraphicsState()
        let lift = NSShadow()
        lift.shadowColor = NSColor(red: 0.15, green: 0.05, blue: 0.3, alpha: 0.45); lift.shadowBlurRadius = 40 * k; lift.shadowOffset = NSSize(width: 0, height: -18 * k)
        lift.set()
        NSColor.white.setFill(); tallPath.fill()
        NSGraphicsContext.restoreGraphicsState()

        // Play coral dentro del clip.
        let cx = tall.midX + 12 * k, cy = tall.midY, r = 70 * k
        let play = NSBezierPath()
        play.move(to: NSPoint(x: cx - r * 0.6, y: cy + r))
        play.line(to: NSPoint(x: cx - r * 0.6, y: cy - r))
        play.line(to: NSPoint(x: cx + r * 0.95, y: cy))
        play.close()
        play.lineJoinStyle = .round; play.lineWidth = 26 * k
        coral.setFill(); play.fill()
        coral.setStroke(); play.stroke()

        return true
    }
}

let names: [Int: [String]] = [16: ["icon_16x16"], 32: ["icon_16x16@2x", "icon_32x32"], 64: ["icon_32x32@2x"], 128: ["icon_128x128"],
                              256: ["icon_128x128@2x", "icon_256x256"], 512: ["icon_256x256@2x", "icon_512x512"], 1024: ["icon_512x512@2x"]]
for (s, files) in names {
    let img = draw(CGFloat(s))
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: s, pixelsHigh: s, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    img.draw(in: NSRect(x: 0, y: 0, width: s, height: s))
    NSGraphicsContext.restoreGraphicsState()
    let png = rep.representation(using: .png, properties: [:])!
    for f in files { try! png.write(to: URL(fileURLWithPath: "\(out)/\(f).png")) }
}
