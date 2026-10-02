import AppKit
let files = Array(CommandLine.arguments.dropFirst(2)); let out = CommandLine.arguments[1]
let imgs = files.map { NSImage(contentsOfFile: $0)!.cgImage(forProposedRect: nil, context: nil, hints: nil)! }
let w = imgs.map(\.width).reduce(0, +), h = imgs.map(\.height).max()!
let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
var x = 0; for i in imgs { c.draw(i, in: CGRect(x: x, y: 0, width: i.width, height: i.height)); x += i.width }
try! NSBitmapImageRep(cgImage: c.makeImage()!).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
