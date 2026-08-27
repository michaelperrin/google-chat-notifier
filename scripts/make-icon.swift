#!/usr/bin/env swift
//
// Génère les PNG de l'icône d'app (bulle de message blanche sur fond vert arrondi)
// dans le dossier .iconset passé en argument. Utilisé par make-icon.sh + iconutil.
//
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Vert Google (dégradé vertical léger).
let topColor = CGColor(red: 0.204, green: 0.659, blue: 0.325, alpha: 1)    // #34A853
let bottomColor = CGColor(red: 0.071, green: 0.553, blue: 0.259, alpha: 1) // #128D42

/// Dessine l'icône à `size` px et renvoie le CGImage.
func renderIcon(size: Int) -> CGImage {
    let n = CGFloat(size)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    // Fond arrondi (squircle approximé par un rounded rect à ~22,37 % — style macOS).
    let inset = n * 0.05
    let rect = CGRect(x: inset, y: inset, width: n - 2 * inset, height: n - 2 * inset)
    let radius = rect.width * 0.2237
    let roundedPath = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

    ctx.saveGState()
    ctx.addPath(roundedPath)
    ctx.clip()
    let gradient = CGGradient(
        colorsSpace: space,
        colors: [topColor, bottomColor] as CFArray,
        locations: [0, 1]
    )!
    // y up : dégradé du haut (clair) vers le bas (foncé).
    ctx.drawLinearGradient(
        gradient,
        start: CGPoint(x: 0, y: rect.maxY),
        end: CGPoint(x: 0, y: rect.minY),
        options: []
    )
    ctx.restoreGState()

    // Bulle de message blanche : rectangle arrondi + queue triangulaire en bas à gauche.
    // Positions en repère haut-gauche (y vers le bas) puis converties (CG a l'origine en bas).
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * n, y: (1 - y) * n) }

    let bubble = CGRect(
        x: 0.20 * n, y: (1 - 0.68) * n,
        width: 0.60 * n, height: 0.42 * n
    )
    let bubbleRadius = bubble.height * 0.30

    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.addPath(CGPath(
        roundedRect: bubble,
        cornerWidth: bubbleRadius, cornerHeight: bubbleRadius,
        transform: nil
    ))
    ctx.fillPath()

    // Queue de la bulle, greffée sous le bord inférieur gauche.
    ctx.beginPath()
    ctx.move(to: p(0.30, 0.66))
    ctx.addLine(to: p(0.30, 0.82))
    ctx.addLine(to: p(0.46, 0.67))
    ctx.closePath()
    ctx.fillPath()

    // Trois points, comme une conversation en cours.
    let dotRadius = n * 0.038
    for x in [CGFloat(0.36), 0.50, 0.64] {
        let center = p(x, 0.47)
        ctx.setFillColor(topColor)
        ctx.fillEllipse(in: CGRect(
            x: center.x - dotRadius, y: center.y - dotRadius,
            width: 2 * dotRadius, height: 2 * dotRadius
        ))
    }

    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

// Point d'entrée
guard CommandLine.arguments.count >= 2 else {
    FileHandle.standardError.write(Data("Usage: make-icon.swift <iconset-dir>\n".utf8))
    exit(1)
}
let outDir = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

// pixels -> fichiers .iconset qui utilisent cette taille
let mapping: [Int: [String]] = [
    16: ["icon_16x16.png"],
    32: ["icon_16x16@2x.png", "icon_32x32.png"],
    64: ["icon_32x32@2x.png"],
    128: ["icon_128x128.png"],
    256: ["icon_128x128@2x.png", "icon_256x256.png"],
    512: ["icon_256x256@2x.png", "icon_512x512.png"],
    1024: ["icon_512x512@2x.png"]
]

for (px, names) in mapping.sorted(by: { $0.key < $1.key }) {
    let image = renderIcon(size: px)
    for name in names {
        writePNG(image, to: outDir.appendingPathComponent(name))
    }
}
print("Icônes générées dans \(outDir.path)")
