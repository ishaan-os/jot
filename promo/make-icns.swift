// Builds assets/AppIcon.icns from the 1024px PNG using ImageIO's own ICNS encoder
// (iconutil isn't usable in every environment; hand-packing chunk types is error-prone).
import AppKit
import UniformTypeIdentifiers

let args = CommandLine.arguments
let src = NSImage(contentsOfFile: args[1])!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
// (pixels, dpi): 144 dpi marks the @2x variant of the half-size slot.
let sizes: [(Int, Int)] = [(16, 72), (32, 144), (32, 72), (64, 144), (128, 72), (256, 144), (256, 72), (512, 144),
                           (512, 72), (1024, 144)]
let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: args[2]) as CFURL, UTType.icns.identifier as CFString,
                                           sizes.count, nil)!
for (s, dpi) in sizes {
    let ctx = CGContext(data: nil, width: s, height: s, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.draw(src, in: CGRect(x: 0, y: 0, width: s, height: s))
    CGImageDestinationAddImage(dest, ctx.makeImage()!,
                               [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary)
}
guard CGImageDestinationFinalize(dest) else { fatalError("icns write failed") }
