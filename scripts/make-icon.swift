#!/usr/bin/env swift
// Run from the repository root: swift scripts/make-icon.swift
// Keep the approved artwork intact; add transparent macOS icon margins and export all scales.
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let sourceURL = root.appendingPathComponent("Support/Bowerbird.png")
let iconsetURL = root.appendingPathComponent("build/Bowerbird.iconset")
let outputURL = root.appendingPathComponent("Support/Bowerbird.icns")
let catalogURL = root.appendingPathComponent("build/BowerbirdAssets.xcassets")
let appIconURL = catalogURL.appendingPathComponent("Bowerbird.appiconset")
let compiledURL = root.appendingPathComponent("build/icon-resources")

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
      let artwork = CGImageSourceCreateImageAtIndex(source, 0, nil),
      artwork.width == artwork.height else {
    fail("Expected square artwork at \(sourceURL.path)")
}
try FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
let sizes: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]

for (name, size) in sizes {
    guard let context = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8,
        bytesPerRow: size * 4, space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { fail("Cannot create \(size)px bitmap") }
    // The source tile already has a small transparent margin. This produces a tile
    // approximately 82% of the final canvas, keeping its apparent size native to macOS.
    let inset = CGFloat(size) / 16
    context.interpolationQuality = .high
    context.draw(artwork, in: CGRect(
        x: inset, y: inset,
        width: CGFloat(size) - 2 * inset, height: CGFloat(size) - 2 * inset
    ))
    guard let rendered = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(
              iconsetURL.appendingPathComponent(name) as CFURL,
              UTType.png.identifier as CFString, 1, nil
          ) else { fail("Cannot export \(name)") }
    CGImageDestinationAddImage(destination, rendered, nil)
    guard CGImageDestinationFinalize(destination) else { fail("Cannot save \(name)") }
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconsetURL.path, "-o", outputURL.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fail("iconutil failed") }

// A named asset catalog lets modern macOS recognize the icon's existing background,
// instead of shrinking the legacy ICNS onto an extra system-provided white tile.
try FileManager.default.createDirectory(at: appIconURL, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: compiledURL, withIntermediateDirectories: true)
var images: [[String: String]] = []
for (name, pixels) in sizes {
    let scale = name.contains("@2x") ? 2 : 1
    let points = pixels / scale
    try Data(contentsOf: iconsetURL.appendingPathComponent(name))
        .write(to: appIconURL.appendingPathComponent(name))
    images.append([
        "filename": name, "idiom": "mac",
        "size": "\(points)x\(points)", "scale": "\(scale)x",
    ])
}
let info: [String: Any] = ["author": "xcode", "version": 1]
try JSONSerialization.data(withJSONObject: ["images": images, "info": info], options: [.prettyPrinted, .sortedKeys])
    .write(to: appIconURL.appendingPathComponent("Contents.json"))
try JSONSerialization.data(withJSONObject: ["info": info], options: [.prettyPrinted, .sortedKeys])
    .write(to: catalogURL.appendingPathComponent("Contents.json"))
let actool = Process()
actool.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
actool.arguments = [
    "actool", catalogURL.path, "--compile", compiledURL.path,
    "--platform", "macosx", "--minimum-deployment-target", "14.0",
    "--app-icon", "Bowerbird", "--output-partial-info-plist",
    compiledURL.appendingPathComponent("Info.plist").path,
    "--output-format", "human-readable-text",
]
try actool.run()
actool.waitUntilExit()
guard actool.terminationStatus == 0 else { fail("Asset catalog compilation failed") }
print("Created Bowerbird.icns and Assets.car with all standard and Retina sizes")
