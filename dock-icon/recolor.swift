// Rotate the hue of every PNG in an iconset: recolor.swift <in.iconset> <out.iconset> <degrees>
// Claude's orange sits near 13°; +202° lands it near 215° (blue). Whites and greys don't change.
import AppKit
import CoreImage

let args = CommandLine.arguments
guard args.count == 4, let degrees = Double(args[3]) else {
  FileHandle.standardError.write("usage: recolor.swift <in.iconset> <out.iconset> <degrees>\n".data(using: .utf8)!)
  exit(2)
}
let src = URL(fileURLWithPath: args[1]), dst = URL(fileURLWithPath: args[2])
try FileManager.default.createDirectory(at: dst, withIntermediateDirectories: true)
let ctx = CIContext()
for name in try FileManager.default.contentsOfDirectory(atPath: src.path) where name.hasSuffix(".png") {
  guard let input = CIImage(contentsOf: src.appendingPathComponent(name)),
        let filter = CIFilter(name: "CIHueAdjust") else { continue }
  filter.setValue(input, forKey: kCIInputImageKey)
  filter.setValue(degrees * .pi / 180, forKey: kCIInputAngleKey)
  guard let output = filter.outputImage,
        let cg = ctx.createCGImage(output, from: input.extent) else { continue }
  let rep = NSBitmapImageRep(cgImage: cg)
  try rep.representation(using: .png, properties: [:])!.write(to: dst.appendingPathComponent(name))
}
