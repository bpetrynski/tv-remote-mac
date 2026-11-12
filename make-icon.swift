// Generates AppIcon.icns for "TV Remote.app". Run: swift make-icon.swift
// Artwork (monochrome, macOS 26/27 glass style): a graphite squircle with a glass rim and an
// aluminium remote with a black clickpad, Back/TV, Play/Pause, Mute and a volume rocker.
import AppKit
import ImageIO
import UniformTypeIdentifiers

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

func gray(_ v: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: srgb, components: [v, v, v, a])!
}

func linear(_ ctx: CGContext, _ from: CGPoint, _ to: CGPoint, _ colors: [CGColor], _ locations: [CGFloat]? = nil) {
    let g = CGGradient(colorsSpace: srgb, colors: colors as CFArray, locations: locations)!
    ctx.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

func radial(_ ctx: CGContext, _ c: CGPoint, _ r: CGFloat, _ colors: [CGColor]) {
    let g = CGGradient(colorsSpace: srgb, colors: colors as CFArray, locations: nil)!
    ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: r, options: [])
}

/// Strokes `path` with a vertical gradient (light from above), like a glass edge.
func gradientStroke(_ ctx: CGContext, _ path: CGPath, width: CGFloat, top: CGColor, bottom: CGColor, box: CGRect) {
    ctx.saveGState()
    ctx.addPath(path.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 10))
    ctx.clip()
    linear(ctx, CGPoint(x: 0, y: box.maxY), CGPoint(x: 0, y: box.minY), [top, bottom])
    ctx.restoreGState()
}

/// Draws the icon in a 1024×1024 design space scaled to `s` (y grows upwards).
func drawIcon(_ ctx: CGContext, _ s: CGFloat) {
    let k = s / 1024
    func p(_ v: CGFloat) -> CGFloat { v * k }
    func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * k, y: y * k) }
    func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(x: x * k, y: y * k, width: w * k, height: h * k)
    }
    func round(_ r: CGRect, _ radius: CGFloat) -> CGPath {
        CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }
    let detailed = s >= 64   // below this, glyphs turn into noise

    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high

    // MARK: Squircle (macOS grid: 824 pt body, 100 pt margin)
    let box = rect(100, 100, 824, 824)
    let body = round(box, box.width * 0.225)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -p(12)), blur: p(28), color: gray(0, 0.32))
    ctx.addPath(body)
    ctx.setFillColor(gray(0.12))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(body)
    ctx.clip()
    // Graphite, lighter at the top.
    linear(ctx, pt(0, 924), pt(0, 100), [gray(0.30), gray(0.17), gray(0.08)], [0, 0.55, 1])
    // Soft light from the upper left, as on glass.
    radial(ctx, pt(300, 860), p(620), [gray(1, 0.13), gray(1, 0)])
    // Faint floor glow under the remote.
    radial(ctx, pt(512, 170), p(380), [gray(1, 0.06), gray(1, 0)])
    ctx.restoreGState()

    // Glass rim: bright at the top edge, almost gone at the bottom.
    ctx.saveGState()
    ctx.addPath(body)
    ctx.clip()
    gradientStroke(ctx, body, width: p(5), top: gray(1, 0.38), bottom: gray(1, 0.05), box: box)
    ctx.restoreGState()

    // MARK: Remote (drawn in the 1024 grid, then scaled into the icon's safe area)
    // Apple's icons keep their subject well inside the squircle; at full size the remote
    // would nearly touch the top and bottom edge. 0.78 leaves ~140 pt above and below.
    ctx.saveGState()
    defer { ctx.restoreGState() }
    ctx.translateBy(x: p(512), y: p(512))
    ctx.scaleBy(x: 0.78, y: 0.78)
    ctx.translateBy(x: -p(512), y: -p(512))

    // MARK: Remote body (aluminium)
    let remote = rect(362, 168, 300, 690)
    let remotePath = round(remote, p(150))

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -p(26)), blur: p(54), color: gray(0, 0.55))
    ctx.addPath(remotePath)
    ctx.setFillColor(gray(0.8))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(remotePath)
    ctx.clip()
    // Brushed metal: light top, cooler middle, a touch brighter near the bottom.
    linear(ctx, pt(0, 858), pt(0, 168), [gray(0.96), gray(0.84), gray(0.74), gray(0.80)], [0, 0.35, 0.8, 1])
    // Side shading gives it a rounded profile.
    linear(ctx, pt(362, 0), pt(662, 0),
           [gray(0, 0.16), gray(0, 0), gray(0, 0), gray(0, 0.20)], [0, 0.18, 0.78, 1])
    // Specular stripe down the left.
    linear(ctx, pt(392, 0), pt(452, 0), [gray(1, 0), gray(1, 0.45), gray(1, 0)])
    ctx.restoreGState()
    gradientStroke(ctx, remotePath, width: p(3), top: gray(1, 0.9), bottom: gray(0, 0.18), box: remote)

    // MARK: Clickpad
    let pad = pt(512, 690)
    let padR = p(118)
    let padRect = CGRect(x: pad.x - padR, y: pad.y - padR, width: padR * 2, height: padR * 2)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: p(2)), blur: p(4), color: gray(1, 0.5))
    ctx.addEllipse(in: padRect)
    ctx.setFillColor(gray(0.1))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addEllipse(in: padRect)
    ctx.clip()
    linear(ctx, CGPoint(x: 0, y: padRect.maxY), CGPoint(x: 0, y: padRect.minY), [gray(0.22), gray(0.06)])
    radial(ctx, CGPoint(x: pad.x - p(40), y: pad.y + p(55)), p(150), [gray(1, 0.10), gray(1, 0)])
    ctx.restoreGState()
    gradientStroke(ctx, CGPath(ellipseIn: padRect, transform: nil), width: p(3),
                   top: gray(1, 0.28), bottom: gray(1, 0.04), box: padRect)

    // Touch ring and the centre button.
    if detailed {
        ctx.setStrokeColor(gray(1, 0.10))
        ctx.setLineWidth(p(2.5))
        let ringR = p(80)
        ctx.strokeEllipse(in: CGRect(x: pad.x - ringR, y: pad.y - ringR, width: ringR * 2, height: ringR * 2))
        // Four direction dots.
        ctx.setFillColor(gray(1, 0.35))
        for (dx, dy) in [(0.0, 1.0), (0.0, -1.0), (1.0, 0.0), (-1.0, 0.0)] {
            let c = CGPoint(x: pad.x + CGFloat(dx) * p(99), y: pad.y + CGFloat(dy) * p(99))
            ctx.fillEllipse(in: CGRect(x: c.x - p(6), y: c.y - p(6), width: p(12), height: p(12)))
        }
    }
    let centerR = p(46)
    let centerRect = CGRect(x: pad.x - centerR, y: pad.y - centerR, width: centerR * 2, height: centerR * 2)
    ctx.saveGState()
    ctx.addEllipse(in: centerRect)
    ctx.clip()
    linear(ctx, CGPoint(x: 0, y: centerRect.maxY), CGPoint(x: 0, y: centerRect.minY), [gray(0.26), gray(0.13)])
    ctx.restoreGState()
    gradientStroke(ctx, CGPath(ellipseIn: centerRect, transform: nil), width: p(2.5),
                   top: gray(1, 0.30), bottom: gray(0, 0.4), box: centerRect)

    // MARK: Buttons
    func button(_ c: CGPoint, _ r: CGFloat) {
        let b = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: p(1.5)), blur: p(2), color: gray(1, 0.6))
        ctx.addEllipse(in: b)
        ctx.setFillColor(gray(0.14))
        ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addEllipse(in: b)
        ctx.clip()
        linear(ctx, CGPoint(x: 0, y: b.maxY), CGPoint(x: 0, y: b.minY), [gray(0.24), gray(0.09)])
        ctx.restoreGState()
        gradientStroke(ctx, CGPath(ellipseIn: b, transform: nil), width: p(2),
                       top: gray(1, 0.25), bottom: gray(1, 0.03), box: b)
    }

    let left: CGFloat = 450, right: CGFloat = 574, r = p(38)
    let back = pt(left, 500), tv = pt(right, 500)
    let play = pt(left, 396), mute = pt(left, 292)
    [back, tv, play, mute].forEach { button($0, r) }

    // Volume rocker: a pill spanning the two lower rows on the right.
    let rocker = CGRect(x: pt(right, 0).x - r, y: mute.y - r, width: r * 2, height: (play.y - mute.y) + r * 2)
    let rockerPath = round(rocker, r)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: p(1.5)), blur: p(2), color: gray(1, 0.6))
    ctx.addPath(rockerPath)
    ctx.setFillColor(gray(0.14))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(rockerPath)
    ctx.clip()
    linear(ctx, CGPoint(x: 0, y: rocker.maxY), CGPoint(x: 0, y: rocker.minY), [gray(0.24), gray(0.09)])
    ctx.restoreGState()
    gradientStroke(ctx, rockerPath, width: p(2), top: gray(1, 0.25), bottom: gray(1, 0.03), box: rocker)

    // MARK: Glyphs (light grey, thin)
    guard detailed else { return }
    ctx.setStrokeColor(gray(0.78))
    ctx.setFillColor(gray(0.78))
    ctx.setLineWidth(p(6))
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)

    // Back: chevron.
    ctx.move(to: CGPoint(x: back.x + p(7), y: back.y + p(14)))
    ctx.addLine(to: CGPoint(x: back.x - p(8), y: back.y))
    ctx.addLine(to: CGPoint(x: back.x + p(7), y: back.y - p(14)))
    ctx.strokePath()

    // TV: screen outline with a stand.
    ctx.setLineWidth(p(5))
    ctx.addPath(round(CGRect(x: tv.x - p(17), y: tv.y - p(8), width: p(34), height: p(22)), p(4)))
    ctx.strokePath()
    ctx.move(to: CGPoint(x: tv.x - p(9), y: tv.y - p(15)))
    ctx.addLine(to: CGPoint(x: tv.x + p(9), y: tv.y - p(15)))
    ctx.strokePath()

    // Play/Pause: triangle and two bars.
    ctx.move(to: CGPoint(x: play.x - p(17), y: play.y + p(12)))
    ctx.addLine(to: CGPoint(x: play.x - p(17), y: play.y - p(12)))
    ctx.addLine(to: CGPoint(x: play.x + p(1), y: play.y))
    ctx.closePath()
    ctx.fillPath()
    ctx.fill(CGRect(x: play.x + p(6), y: play.y - p(12), width: p(5), height: p(24)))
    ctx.fill(CGRect(x: play.x + p(14), y: play.y - p(12), width: p(5), height: p(24)))

    // Mute: speaker with a slash.
    ctx.move(to: CGPoint(x: mute.x - p(16), y: mute.y + p(6)))
    ctx.addLine(to: CGPoint(x: mute.x - p(8), y: mute.y + p(6)))
    ctx.addLine(to: CGPoint(x: mute.x + p(4), y: mute.y + p(16)))
    ctx.addLine(to: CGPoint(x: mute.x + p(4), y: mute.y - p(16)))
    ctx.addLine(to: CGPoint(x: mute.x - p(8), y: mute.y - p(6)))
    ctx.addLine(to: CGPoint(x: mute.x - p(16), y: mute.y - p(6)))
    ctx.closePath()
    ctx.fillPath()
    ctx.setLineWidth(p(5))
    ctx.move(to: CGPoint(x: mute.x + p(10), y: mute.y + p(10)))
    ctx.addLine(to: CGPoint(x: mute.x + p(20), y: mute.y - p(10)))
    ctx.strokePath()

    // Volume: + at the top, − at the bottom of the rocker.
    let vx = rocker.midX
    ctx.setLineWidth(p(6))
    ctx.move(to: CGPoint(x: vx - p(12), y: play.y))
    ctx.addLine(to: CGPoint(x: vx + p(12), y: play.y))
    ctx.move(to: CGPoint(x: vx, y: play.y - p(12)))
    ctx.addLine(to: CGPoint(x: vx, y: play.y + p(12)))
    ctx.move(to: CGPoint(x: vx - p(12), y: mute.y))
    ctx.addLine(to: CGPoint(x: vx + p(12), y: mute.y))
    ctx.strokePath()
}

func png(size: Int, to url: URL) {
    let s = CGFloat(size)
    guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                              bytesPerRow: 0, space: srgb,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        fatalError("could not create a \(size) px context")
    }
    drawIcon(ctx, s)
    guard let image = ctx.makeImage(),
          let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { fatalError("could not write \(url.path)") }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("writing the PNG failed") }
}

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1]
               : FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for base in [16, 32, 128, 256, 512] {
    png(size: base, to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    png(size: base * 2, to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}

let icns = root.appendingPathComponent("AppIcon.icns")
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try task.run()
task.waitUntilExit()
guard task.terminationStatus == 0 else { fatalError("iconutil returned \(task.terminationStatus)") }
try? FileManager.default.removeItem(at: iconset)
print("Built: \(icns.path)")
