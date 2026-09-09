// Render the app's own menu bar symbol as a high-resolution application icon.
import AppKit
let output = CommandLine.arguments[1]
let size = NSSize(width: 1024, height: 1024)
let image = NSImage(size: size)
image.lockFocus()
let frame = NSRect(x: 72, y: 72, width: 880, height: 880)
let shape = NSBezierPath(roundedRect: frame, xRadius: 205, yRadius: 205)
NSGradient(starting: NSColor(srgbRed: 0.0, green: 0.38, blue: 0.87, alpha: 1), ending: NSColor(srgbRed: 0.22, green: 0.59, blue: 1, alpha: 1))!.draw(in: shape, angle: 90)
NSColor.white.withAlphaComponent(0.2).setStroke()
shape.lineWidth = 3
shape.stroke()
let configuration = NSImage.SymbolConfiguration(pointSize: 512, weight: .regular)
    .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
let symbol = NSImage(systemSymbolName: "earbuds", accessibilityDescription: nil)!.withSymbolConfiguration(configuration)!
let aspect = symbol.size.height / symbol.size.width
let bounds = NSRect(x: 232, y: (1024 - 560 * aspect) / 2, width: 560, height: 560 * aspect)
symbol.draw(in: bounds)
image.unlockFocus()
let representation = NSBitmapImageRep(data: image.tiffRepresentation!)!
try representation.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
