#!/usr/bin/env swift
import AppKit
import Foundation

let arguments = CommandLine.arguments

guard arguments.count == 3 else {
    FileHandle.standardError.write(Data("Usage: make-app-icon.swift <source-png> <output-icns>\n".utf8))
    exit(64)
}

let sourceURL = URL(fileURLWithPath: arguments[1])
let outputURL = URL(fileURLWithPath: arguments[2])

guard let sourceImage = NSImage(contentsOf: sourceURL) else {
    FileHandle.standardError.write(Data("Could not read source image: \(sourceURL.path)\n".utf8))
    exit(66)
}

let sourceSize = sourceImage.size
let iconEntries: [(type: String, size: Int)] = [
    ("icp4", 16),
    ("icp5", 32),
    ("icp6", 64),
    ("ic07", 128),
    ("ic08", 256),
    ("ic09", 512),
    ("ic10", 1024),
]

func renderPNG(size: Int) throws -> Data {
    let targetSize = NSSize(width: size, height: size)
    let image = NSImage(size: targetSize)
    let canvas = NSRect(origin: .zero, size: targetSize)
    let maxContentSize = CGFloat(size) * 0.82
    let scale = min(maxContentSize / sourceSize.width, maxContentSize / sourceSize.height)
    let drawSize = NSSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
    let drawRect = NSRect(
        x: (CGFloat(size) - drawSize.width) / 2.0,
        y: (CGFloat(size) - drawSize.height) / 2.0,
        width: drawSize.width,
        height: drawSize.height
    )

    image.lockFocus()
    NSColor.clear.setFill()
    canvas.fill()
    sourceImage.draw(
        in: drawRect,
        from: NSRect(origin: .zero, size: sourceSize),
        operation: .sourceOver,
        fraction: 1.0
    )
    image.unlockFocus()

    guard
        let tiffData = image.tiffRepresentation,
        let bitmap = NSBitmapImageRep(data: tiffData),
        let pngData = bitmap.representation(using: .png, properties: [:])
    else {
        throw NSError(
            domain: "MakeAppIcon",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Could not render \(size)x\(size) icon"]
        )
    }

    return pngData
}

func appendASCII(_ value: String, to data: inout Data) {
    data.append(contentsOf: value.utf8)
}

func appendUInt32BE(_ value: Int, to data: inout Data) {
    var bigEndian = UInt32(value).bigEndian
    withUnsafeBytes(of: &bigEndian) { bytes in
        data.append(contentsOf: bytes)
    }
}

do {
    var body = Data()

    for entry in iconEntries {
        let pngData = try renderPNG(size: entry.size)
        appendASCII(entry.type, to: &body)
        appendUInt32BE(8 + pngData.count, to: &body)
        body.append(pngData)
    }

    var iconData = Data()
    appendASCII("icns", to: &iconData)
    appendUInt32BE(8 + body.count, to: &iconData)
    iconData.append(body)

    try FileManager.default.createDirectory(
        at: outputURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try iconData.write(to: outputURL)
} catch {
    FileHandle.standardError.write(Data("Could not create app icon: \(error.localizedDescription)\n".utf8))
    exit(1)
}
