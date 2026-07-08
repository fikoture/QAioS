// QAioS uygulama ikonunu üretir (1024x1024 PNG).
// Tasarım: koyu lacivertten camgöbeğine gradyan squircle zemin üzerinde
// beyaz kalkan + içinde canlı log/nabız çizgisi; altta "bySentinelAI" yazısı.
// Kullanım: swift scripts/make_icon.swift <çıktı.png>

import AppKit

let outputPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.png"
let size = 1024

guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
) else { fatalError("bitmap oluşturulamadı") }

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

func P(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x, y: y) }

// --- Zemin: macOS squircle (kenarlardan ~10% boşluk) ---
let inset: CGFloat = 100
let bgRect = NSRect(x: inset, y: inset, width: 1024 - 2 * inset, height: 1024 - 2 * inset)
let bgPath = NSBezierPath(roundedRect: bgRect, xRadius: 185, yRadius: 185)
NSGradient(
    starting: NSColor(calibratedRed: 0.03, green: 0.07, blue: 0.18, alpha: 1),
    ending:   NSColor(calibratedRed: 0.02, green: 0.42, blue: 0.50, alpha: 1)
)!.draw(in: bgPath, angle: -55)

// --- Kalkan ---
let shield = NSBezierPath()
shield.move(to: P(512, 780))                                              // tepe orta
shield.curve(to: P(712, 700), controlPoint1: P(590, 762), controlPoint2: P(662, 730))
shield.curve(to: P(512, 300), controlPoint1: P(712, 490), controlPoint2: P(640, 370))
shield.curve(to: P(312, 700), controlPoint1: P(384, 370), controlPoint2: P(312, 490))
shield.curve(to: P(512, 780), controlPoint1: P(362, 730), controlPoint2: P(434, 762))
shield.close()

NSColor.white.withAlphaComponent(0.10).setFill()
shield.fill()
NSColor.white.withAlphaComponent(0.92).setStroke()
shield.lineWidth = 26
shield.stroke()

// --- Kalkan içindeki nabız / log akış çizgisi ---
NSGraphicsContext.current?.saveGraphicsState()
shield.addClip()
let pulse = NSBezierPath()
pulse.move(to: P(330, 540))
pulse.line(to: P(430, 540))
pulse.line(to: P(468, 620))
pulse.line(to: P(522, 440))
pulse.line(to: P(560, 540))
pulse.line(to: P(694, 540))
pulse.lineWidth = 30
pulse.lineCapStyle = .round
pulse.lineJoinStyle = .round
NSColor(calibratedRed: 0.20, green: 0.95, blue: 0.75, alpha: 1).setStroke()
pulse.stroke()

// Nabzın tepe noktasında hata vurgusu (kırmızı nokta)
let dot = NSBezierPath(ovalIn: NSRect(x: 522 - 26, y: 440 - 26, width: 52, height: 52))
NSColor(calibratedRed: 1.0, green: 0.32, blue: 0.30, alpha: 1).setFill()
dot.fill()
NSGraphicsContext.current?.restoreGraphicsState()

// --- Alt yazı: bySentinelAI ---
let caption = "bySentinelAI" as NSString
let captionAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 62, weight: .semibold),
    .foregroundColor: NSColor.white.withAlphaComponent(0.88),
    .kern: 1.5,
]
let captionSize = caption.size(withAttributes: captionAttrs)
caption.draw(at: P((1024 - captionSize.width) / 2, 168), withAttributes: captionAttrs)

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("png üretilemedi") }
try! png.write(to: URL(fileURLWithPath: outputPath))
print("✓ ikon yazıldı: \(outputPath)")
