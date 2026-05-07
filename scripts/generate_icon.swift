#!/usr/bin/env swift
//
// Generates Latent.icns at all the sizes macOS expects.
//
// Concept: dark squircle (Apple's standard rounded-square shape) with a
// vivid violet → magenta gradient, an iris/aperture made of 6 angled
// blades in a frosted-white gradient, and a soft inner glow at the
// optical center. Reads as "lens + AI" without being cheesy.
//
// Output:
//   Resources/AppBundle/Latent.iconset/  (all the PNG sizes)
//   Resources/AppBundle/Latent.icns      (combined, via /usr/bin/iconutil)
//
// Run:
//   swift scripts/generate_icon.swift
//

import AppKit
import CoreGraphics
import Foundation

// MARK: - Sizing

let outputDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("Resources/AppBundle/Latent.iconset")
let icnsURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("Resources/AppBundle/Latent.icns")

// (filename, pixel size)
let entries: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

// MARK: - Drawing

/// Draw the icon at an arbitrary pixel size. All measurements scale relative
/// to the canvas so a 16×16 looks identical (just smaller) to a 1024×1024.
func renderIcon(size: Int) -> CGImage {
    let s = CGFloat(size)
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: size * 4,
        space: cs,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!

    // 1. Squircle background. Apple's standard rounded-square corner radius
    //    is roughly 18% of the side length for app icons.
    let cornerRadius = s * 0.225
    let bgRect = CGRect(x: 0, y: 0, width: s, height: s)
    let bgPath = CGPath(roundedRect: bgRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
    ctx.addPath(bgPath)
    ctx.clip()

    // 2. Diagonal gradient: deep violet → electric magenta. Start dark for
    //    contrast under the iris, end bright for visual energy.
    let bgGradient = CGGradient(
        colorsSpace: cs,
        colors: [
            CGColor(red: 0.16, green: 0.04, blue: 0.42, alpha: 1.0), // deep violet
            CGColor(red: 0.43, green: 0.10, blue: 0.78, alpha: 1.0), // mid purple
            CGColor(red: 0.92, green: 0.18, blue: 0.74, alpha: 1.0), // hot magenta
        ] as CFArray,
        locations: [0.0, 0.55, 1.0]
    )!
    ctx.drawLinearGradient(
        bgGradient,
        start: CGPoint(x: 0, y: s),
        end: CGPoint(x: s, y: 0),
        options: []
    )

    // 3. Soft central radial glow — gives the iris something to glow against.
    let glow = CGGradient(
        colorsSpace: cs,
        colors: [
            CGColor(red: 1, green: 1, blue: 1, alpha: 0.18),
            CGColor(red: 1, green: 1, blue: 1, alpha: 0.0),
        ] as CFArray,
        locations: [0.0, 1.0]
    )!
    ctx.drawRadialGradient(
        glow,
        startCenter: CGPoint(x: s * 0.5, y: s * 0.5),
        startRadius: 0,
        endCenter: CGPoint(x: s * 0.5, y: s * 0.5),
        endRadius: s * 0.42,
        options: []
    )

    // 4. The aperture iris — six rotated triangular blades that overlap to
    //    form the classic camera-shutter shape. White core fading to a cool
    //    cyan edge where blades meet, plus a faint inner shadow that gives
    //    each blade a 3D feel.
    let irisCenter = CGPoint(x: s * 0.5, y: s * 0.5)
    let irisOuter = s * 0.32
    let irisInner = s * 0.06   // pinhole at the center
    let bladeCount = 6

    let irisGradient = CGGradient(
        colorsSpace: cs,
        colors: [
            CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0),
            CGColor(red: 0.78, green: 0.92, blue: 1.0, alpha: 1.0),
        ] as CFArray,
        locations: [0.0, 1.0]
    )!

    for i in 0..<bladeCount {
        let angle = (CGFloat(i) / CGFloat(bladeCount)) * .pi * 2.0
        let nextAngle = (CGFloat(i + 1) / CGFloat(bladeCount)) * .pi * 2.0

        // Each blade: a triangle with apex at `irisInner` from center, base
        // out at `irisOuter`. The base is offset slightly tangentially so
        // adjacent blades overlap and form the iris pattern.
        let apex = CGPoint(
            x: irisCenter.x + cos(angle) * irisInner,
            y: irisCenter.y + sin(angle) * irisInner
        )
        let baseLeading = CGPoint(
            x: irisCenter.x + cos(angle) * irisOuter,
            y: irisCenter.y + sin(angle) * irisOuter
        )
        let baseTrailing = CGPoint(
            x: irisCenter.x + cos(nextAngle) * irisOuter,
            y: irisCenter.y + sin(nextAngle) * irisOuter
        )

        let blade = CGMutablePath()
        blade.move(to: apex)
        blade.addLine(to: baseLeading)
        blade.addLine(to: baseTrailing)
        blade.closeSubpath()

        ctx.saveGState()
        ctx.addPath(blade)
        ctx.clip()
        // Linear gradient running across each blade, edge → center, gives
        // a sense of the blade's curvature.
        ctx.drawLinearGradient(
            irisGradient,
            start: baseLeading,
            end: apex,
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )
        ctx.restoreGState()

        // Subtle dark stroke between blades adds depth without looking busy.
        ctx.saveGState()
        ctx.setStrokeColor(CGColor(red: 0.12, green: 0.0, blue: 0.30, alpha: 0.35))
        ctx.setLineWidth(s * 0.004)
        ctx.addPath(blade)
        ctx.strokePath()
        ctx.restoreGState()
    }

    // 5. Tiny dark pupil at the optical center — sells the lens metaphor.
    ctx.saveGState()
    ctx.setFillColor(CGColor(red: 0.04, green: 0.0, blue: 0.16, alpha: 0.85))
    ctx.fillEllipse(in: CGRect(
        x: irisCenter.x - irisInner * 0.55,
        y: irisCenter.y - irisInner * 0.55,
        width: irisInner * 1.1,
        height: irisInner * 1.1
    ))
    // Specular hot spot — reads as a glint of light.
    ctx.setFillColor(CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.7))
    ctx.fillEllipse(in: CGRect(
        x: irisCenter.x - irisInner * 0.18,
        y: irisCenter.y - irisInner * 0.05,
        width: irisInner * 0.28,
        height: irisInner * 0.28
    ))
    ctx.restoreGState()

    return ctx.makeImage()!
}

// MARK: - PNG export

func writePNG(_ cg: CGImage, to url: URL) throws {
    let rep = NSBitmapImageRep(cgImage: cg)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "icon", code: -1, userInfo: [NSLocalizedDescriptionKey: "PNG encode failed"])
    }
    try data.write(to: url)
}

// MARK: - Run

print("rendering Latent icon set…")
for (filename, size) in entries {
    let cg = renderIcon(size: size)
    let url = outputDir.appendingPathComponent(filename)
    try writePNG(cg, to: url)
    print("  → \(filename) (\(size)×\(size))")
}

// MARK: - .icns

print("building Latent.icns via /usr/bin/iconutil…")
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", outputDir.path, "-o", icnsURL.path]
try p.run()
p.waitUntilExit()
if p.terminationStatus != 0 {
    print("iconutil exited \(p.terminationStatus)")
    exit(1)
}
print("done → \(icnsURL.path)")
