// Dikte app icon generator (AppKit/CoreGraphics only, no external assets).
//
//   swift app/scripts/make-icon.swift [A|B|C]   # write AppIcon.appiconset + build/dikte.icns
//   swift app/scripts/make-icon.swift --preview # render all variants + contact sheet
//
// Every size is drawn from vectors (not downscaled), on Apple's macOS icon grid:
// 1024 canvas, 824×824 continuous-corner body centered, radius ≈ 185, soft drop shadow.
import AppKit
import CoreGraphics
import Foundation

let defaultVariant = "B"

let appDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let assetsDir = appDir.appendingPathComponent("dikte/Sources/Resources/Assets.xcassets")
let buildDir = appDir.appendingPathComponent("dikte/build")

// MARK: - Geometry helpers

let canvas: CGFloat = 1024
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let bodyRadius: CGFloat = 185.4

/// Rounded rect with continuous (curvature-matched) corners, like UIKit's `.continuous` style.
func continuousRect(_ r: CGRect, radius: CGFloat) -> CGPath {
    let rad = min(radius, min(r.width, r.height) / 2 / 1.52866483)
    let path = CGMutablePath()
    // Corner points as (along incoming edge back from the corner, along outgoing edge), in radius units.
    let seq: [(CGFloat, CGFloat)] = [
        (1.08849323, 0), (0.86840689, 0), (0.66993427, 0.06549600),
        (0.63149399, 0.07491100),
        (0.37282392, 0.16905899), (0.16906013, 0.37282401), (0.07491176, 0.63149399),
        (0.06549569, 0.66993493),
        (0, 0.86840701), (0, 1.08849299), (0, 1.52866483),
    ]
    // Corners in order (counter-clockwise in y-up space): corner, u (back along incoming), v (outgoing).
    let corners: [(CGPoint, CGVector, CGVector)] = [
        (CGPoint(x: r.maxX, y: r.minY), CGVector(dx: -1, dy: 0), CGVector(dx: 0, dy: 1)),
        (CGPoint(x: r.maxX, y: r.maxY), CGVector(dx: 0, dy: -1), CGVector(dx: -1, dy: 0)),
        (CGPoint(x: r.minX, y: r.maxY), CGVector(dx: 1, dy: 0), CGVector(dx: 0, dy: -1)),
        (CGPoint(x: r.minX, y: r.minY), CGVector(dx: 0, dy: 1), CGVector(dx: 1, dy: 0)),
    ]
    func pt(_ c: (CGPoint, CGVector, CGVector), _ p: (CGFloat, CGFloat)) -> CGPoint {
        CGPoint(x: c.0.x + (p.0 * c.1.dx + p.1 * c.2.dx) * rad,
                y: c.0.y + (p.0 * c.1.dy + p.1 * c.2.dy) * rad)
    }
    path.move(to: pt(corners[3], (0, 1.52866483)))
    for c in corners {
        path.addLine(to: pt(c, (1.52866483, 0)))
        path.addCurve(to: pt(c, seq[2]), control1: pt(c, seq[0]), control2: pt(c, seq[1]))
        path.addLine(to: pt(c, seq[3]))
        path.addCurve(to: pt(c, seq[6]), control1: pt(c, seq[4]), control2: pt(c, seq[5]))
        path.addLine(to: pt(c, seq[7]))
        path.addCurve(to: pt(c, seq[10]), control1: pt(c, seq[8]), control2: pt(c, seq[9]))
    }
    path.closeSubpath()
    return path
}

func capsule(_ r: CGRect) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: min(r.width, r.height) / 2, cornerHeight: min(r.width, r.height) / 2, transform: nil)
}

/// Capsule centered on (cx, cy).
func capsule(cx: CGFloat, cy: CGFloat, w: CGFloat, h: CGFloat) -> CGPath {
    capsule(CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h))
}

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
    CGGradient(colorsSpace: srgb, colors: stops.map(\.1) as CFArray, locations: stops.map(\.0))!
}

extension CGContext {
    func fill(_ path: CGPath, _ color: CGColor) {
        addPath(path); setFillColor(color); fillPath()
    }
    func fill(_ path: CGPath, gradient g: CGGradient, from: CGPoint, to: CGPoint) {
        saveGState(); addPath(path); clip()
        drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        restoreGState()
    }
}

// MARK: - Shared body

/// Draws the squircle body (shadow + background gradient + soft top sheen + hairline edge),
/// then calls `content` clipped to the body. `scale` is pixels per design unit (shadows ignore the CTM).
func drawBody(_ ctx: CGContext, scale: CGFloat, background: CGGradient, from: CGPoint = CGPoint(x: 512, y: 924),
              to: CGPoint = CGPoint(x: 512, y: 100), sheen: CGFloat = 0.10, edge: CGColor = rgb(0x000000, 0.10),
              content: (CGContext) -> Void) {
    let shape = continuousRect(body, radius: bodyRadius)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * scale), blur: 22 * scale, color: rgb(0x000000, 0.28))
    ctx.fill(shape, rgb(0x000000))
    ctx.restoreGState()

    ctx.fill(shape, gradient: background, from: from, to: to)
    ctx.saveGState()
    ctx.addPath(shape); ctx.clip()
    if sheen > 0 {
        let g = gradient([(0, rgb(0xFFFFFF, sheen)), (1, rgb(0xFFFFFF, 0))])
        ctx.drawLinearGradient(g, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 560), options: [])
    }
    content(ctx)
    ctx.restoreGState()

    // Hairline edge keeps the silhouette defined on backgrounds of similar tone.
    ctx.saveGState()
    ctx.addPath(shape); ctx.clip()
    ctx.addPath(shape)
    ctx.setStrokeColor(edge); ctx.setLineWidth(max(4, 1.5 / scale))
    ctx.strokePath()
    ctx.restoreGState()
}

// MARK: - Variants

/// A: waveform bars that settle into lines of text with a caret, on a deep indigo gradient.
func drawA(_ ctx: CGContext, scale: CGFloat) {
    let bg = gradient([(0, rgb(0x6B73FF)), (0.55, rgb(0x4338CA)), (1, rgb(0x241A7A))])
    drawBody(ctx, scale: scale, background: bg) { ctx in
        let barW: CGFloat = 64, pitch: CGFloat = 100, cy: CGFloat = 512
        let gap: CGFloat = 52, lineH = barW
        let lengths: [CGFloat] = [300, 236, 132]
        let caretGap: CGFloat = 30, caretW: CGFloat = 30
        // Center the whole group: 3 bars, a gap, then the text block and caret.
        let textX0 = 3 * pitch + 12
        let groupW = textX0 + lengths[0]
        let x0 = 512 - groupW / 2
        // Sound: tall rounded bars on the left, tinted toward the caret's cyan.
        let bars = gradient([(0, rgb(0xA5F3FC)), (1, rgb(0xFFFFFF))])
        let heights: [CGFloat] = [230, 420, 300]
        for (i, h) in heights.enumerated() {
            let r = CGRect(x: x0 + CGFloat(i) * pitch, y: cy - h / 2, width: barW, height: h)
            ctx.fill(capsule(r), gradient: bars, from: CGPoint(x: 0, y: cy - 210), to: CGPoint(x: 0, y: cy + 210))
        }
        // Text: three lines as thick as the bars; the last one ends in a caret.
        let tx = x0 + textX0
        for (i, len) in lengths.enumerated() {
            let y = cy + (lineH + gap) * CGFloat(1 - i)
            ctx.fill(capsule(CGRect(x: tx, y: y - lineH / 2, width: len, height: lineH)), rgb(0xFFFFFF))
        }
        let lastY = cy - (lineH + gap)
        ctx.fill(capsule(cx: tx + lengths[2] + caretGap + caretW / 2, cy: lastY, w: caretW, h: lineH * 2), rgb(0x67E8F9))
    }
}

/// B: rounded microphone whose grille is lines of text ending in a caret, on a warm gradient.
func drawB(_ ctx: CGContext, scale: CGFloat) {
    let bg = gradient([(0, rgb(0xFFC15A)), (0.5, rgb(0xFF7A3D)), (1, rgb(0xE8364F))])
    drawBody(ctx, scale: scale, background: bg, sheen: 0.12) { ctx in
        let white = rgb(0xFFFFFF)
        let head = CGRect(x: 512 - 150, y: 430, width: 300, height: 400)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -8 * scale), blur: 24 * scale, color: rgb(0x7A1020, 0.30))
        ctx.fill(capsule(head), white)
        ctx.restoreGState()

        // Holder: a U around the lower head, a stem and a base.
        let stroke: CGFloat = 46
        let arcC = CGPoint(x: 512, y: 590), arcR: CGFloat = 214
        let holder = CGMutablePath()
        holder.move(to: CGPoint(x: 512 - arcR, y: 650))
        holder.addLine(to: CGPoint(x: 512 - arcR, y: arcC.y))
        holder.addArc(center: arcC, radius: arcR, startAngle: .pi, endAngle: 0, clockwise: false)
        holder.addLine(to: CGPoint(x: 512 + arcR, y: 650))
        holder.move(to: CGPoint(x: 512, y: arcC.y - arcR))
        holder.addLine(to: CGPoint(x: 512, y: 262))
        let stroked = holder.copy(strokingWithWidth: stroke, lineCap: .round, lineJoin: .round, miterLimit: 10)
        ctx.fill(stroked, white)
        ctx.fill(capsule(cx: 512, cy: 262, w: 236, h: stroke), white)

        // Grille as text: three lines and a caret, in the background's warm red.
        // At 16 px it only muddies the silhouette, so the head stays plain there.
        guard scale * canvas > 16 else { return }
        let ink = rgb(0xF0573F)
        let lineH: CGFloat = 34, lx = head.minX + 72
        let rows: [(CGFloat, CGFloat)] = [(724, 156), (648, 120), (572, 78)]
        for (y, len) in rows {
            ctx.fill(capsule(CGRect(x: lx, y: y - lineH / 2, width: len, height: lineH)), ink)
        }
        ctx.fill(capsule(cx: lx + 78 + 34, cy: 572, w: 22, h: 76), rgb(0xE8364F))
    }
}

/// C: minimal flat speech bubble holding a waveform that ends in a caret, on a light body.
func drawC(_ ctx: CGContext, scale: CGFloat) {
    let bg = gradient([(0, rgb(0xFFFFFF)), (1, rgb(0xE6E8EF))])
    drawBody(ctx, scale: scale, background: bg, sheen: 0, edge: rgb(0x000000, 0.14)) { ctx in
        let blue = rgb(0x2563EB)
        let bubble = CGRect(x: 200, y: 300, width: 624, height: 470)
        ctx.fill(continuousRect(bubble, radius: 150), blue)
        // Tail at the lower left.
        let tail = CGMutablePath()
        tail.move(to: CGPoint(x: 336, y: 380))
        tail.addQuadCurve(to: CGPoint(x: 238, y: 210), control: CGPoint(x: 318, y: 262))
        tail.addQuadCurve(to: CGPoint(x: 450, y: 306), control: CGPoint(x: 352, y: 222))
        tail.closeSubpath()
        ctx.fill(tail, blue)

        let white = rgb(0xFFFFFF)
        let cy = bubble.midY, barW: CGFloat = 52, pitch: CGFloat = 88
        let heights: [CGFloat] = [120, 230, 320, 190]
        let x0: CGFloat = 328
        for (i, h) in heights.enumerated() {
            ctx.fill(capsule(cx: x0 + CGFloat(i) * pitch, cy: cy, w: barW, h: h), white)
        }
        ctx.fill(capsule(cx: x0 + 4 * pitch + 30, cy: cy, w: 28, h: 300), rgb(0xFFB020))
    }
}

let variants: [String: (CGContext, CGFloat) -> Void] = ["A": drawA, "B": drawB, "C": drawC]

// MARK: - Rendering

func render(_ variant: String, pixels: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                        space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high
    let s = CGFloat(pixels) / canvas
    ctx.scaleBy(x: s, y: s)
    variants[variant]!(ctx, s)
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: image.width, height: image.height)
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

func writeJSON(_ object: Any, to url: URL) {
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    try! data.write(to: url)
}

let iconSizes: [(points: Int, scale: Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]

func fileName(_ points: Int, _ scale: Int) -> String {
    "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
}

func writeAppIcon(_ variant: String) {
    let set = assetsDir.appendingPathComponent("AppIcon.appiconset")
    try? FileManager.default.removeItem(at: set)
    try! FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
    writeJSON(["info": ["author": "xcode", "version": 1]], to: assetsDir.appendingPathComponent("Contents.json"))

    // Also build an .iconset for iconutil (DMG volume icon).
    let iconset = buildDir.appendingPathComponent("dikte.iconset")
    try? FileManager.default.removeItem(at: iconset)
    try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

    var cache: [Int: CGImage] = [:]
    var images: [[String: String]] = []
    for (points, scale) in iconSizes {
        let px = points * scale
        let image = cache[px] ?? render(variant, pixels: px)
        cache[px] = image
        let name = fileName(points, scale)
        writePNG(image, to: set.appendingPathComponent(name))
        writePNG(image, to: iconset.appendingPathComponent(name))
        images.append(["filename": name, "idiom": "mac", "scale": "\(scale)x", "size": "\(points)x\(points)"])
    }
    writeJSON(["images": images, "info": ["author": "xcode", "version": 1]], to: set.appendingPathComponent("Contents.json"))

    let icns = buildDir.appendingPathComponent("dikte.icns")
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    task.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
    try! task.run(); task.waitUntilExit()
    try? FileManager.default.removeItem(at: iconset)
    print("AppIcon (\(variant)) → \(set.path)")
    if task.terminationStatus == 0 { print("icns → \(icns.path)") }
}

func writePreviews() {
    let out = buildDir.appendingPathComponent("icon-variants")
    let names = variants.keys.sorted()
    for v in names {
        writePNG(render(v, pixels: 1024), to: out.appendingPathComponent("icon-\(v).png"))
    }

    // Contact sheet: each variant in a column; rows: large on light, large on dark,
    // then 64/32/16 px at actual size and magnified ×4 (nearest neighbour) on both backgrounds.
    let col = 560, big = 400
    let w = col * names.count, h = 1400
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let light = rgb(0xECECEE), dark = rgb(0x1E1E22)
    ctx.setFillColor(light); ctx.fill(CGRect(x: 0, y: h - 460, width: w, height: 460))
    ctx.setFillColor(dark); ctx.fill(CGRect(x: 0, y: h - 920, width: w, height: 460))
    ctx.setFillColor(light); ctx.fill(CGRect(x: 0, y: 240, width: w, height: 240))
    ctx.setFillColor(dark); ctx.fill(CGRect(x: 0, y: 0, width: w, height: 240))
    for (i, v) in names.enumerated() {
        let x0 = i * col
        let large = render(v, pixels: big)
        ctx.interpolationQuality = .high
        ctx.draw(large, in: CGRect(x: x0 + (col - big) / 2, y: h - 30 - big, width: big, height: big))
        ctx.draw(large, in: CGRect(x: x0 + (col - big) / 2, y: h - 490 - big, width: big, height: big))
        // Actual 64/32/16 px, then 32 px ×4 and 16 px ×8 magnified.
        let small = [64, 32, 16].map { ($0, render(v, pixels: $0)) }
        ctx.interpolationQuality = .none
        for bandY in [240, 0] {
            let mid = bandY + 120
            var x = x0 + 30
            for (px, img) in small {
                ctx.draw(img, in: CGRect(x: x, y: mid - px / 2, width: px, height: px))
                x += px + 24
            }
            ctx.draw(small[1].1, in: CGRect(x: x, y: mid - 64, width: 128, height: 128))
            ctx.draw(small[2].1, in: CGRect(x: x + 150, y: mid - 64, width: 128, height: 128))
        }
    }
    writePNG(ctx.makeImage()!, to: out.appendingPathComponent("contact-sheet.png"))
    print("previews → \(out.path)")
}

let args = Array(CommandLine.arguments.dropFirst())
if args.contains("--preview") {
    writePreviews()
} else {
    let v = (args.first ?? defaultVariant).uppercased()
    guard variants[v] != nil else {
        FileHandle.standardError.write("usage: make-icon.swift [A|B|C] | --preview\n".data(using: .utf8)!)
        exit(2)
    }
    writeAppIcon(v)
}
