import AppKit
// usage: png.swift in.svg out.png size
let a = CommandLine.arguments, size = Int(a[3])!
let img = NSImage(contentsOfFile: a[1])!
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
img.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: a[2]))
