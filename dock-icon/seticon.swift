// Give a file or app bundle a Finder custom icon: seticon.swift <icon.icns> <path>
// "-" instead of an icon removes the custom icon.
// This adds "Icon\r" inside the bundle and leaves the code signature as it was (no re-signing).
import AppKit

let args = CommandLine.arguments
let image = args.count == 3 && args[1] != "-" ? NSImage(contentsOfFile: args[1]) : nil
guard args.count == 3, args[1] == "-" || image != nil else {
  FileHandle.standardError.write("usage: seticon.swift <icon.icns|-> <path>\n".data(using: .utf8)!)
  exit(2)
}
let ok = NSWorkspace.shared.setIcon(image, forFile: args[2], options: [])
print(ok ? "icon set on \(args[2])" : "setIcon failed for \(args[2])")
exit(ok ? 0 : 1)
