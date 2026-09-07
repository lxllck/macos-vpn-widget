import AppKit
import Foundation

// Генератор иконки приложения. Рисуем векторно и растеризуем во все размеры,
// которые требует .icns, — так иконка остаётся чёткой и на 16 px, и на 1024 px.

/// Скруглённый прямоугольник по сетке Apple для macOS: тело занимает 824 pt
/// из 1024 pt холста, радиус скругления — 185 pt.
func iconBody(_ s: CGFloat) -> NSBezierPath {
    let inset = s * (100.0 / 1024.0)
    let r = s * (185.0 / 1024.0)
    let rect = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    return NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r)
}

/// Силуэт щита. Плечи чуть скруглены, низ сходится в мягкий клин —
/// на 16 px деталей уже не видно, поэтому важен именно силуэт.
func shield(_ s: CGFloat) -> NSBezierPath {
    let cx = s / 2
    let w = s * 0.40
    let top = s * 0.755, bottom = s * 0.245
    let h = top - bottom
    let shoulder = top - h * 0.36
    let r = s * 0.028

    let p = NSBezierPath()
    p.move(to: NSPoint(x: cx - w / 2 + r, y: top))
    p.line(to: NSPoint(x: cx + w / 2 - r, y: top))
    p.curve(to: NSPoint(x: cx + w / 2, y: top - r),
            controlPoint1: NSPoint(x: cx + w / 2, y: top),
            controlPoint2: NSPoint(x: cx + w / 2, y: top))
    p.line(to: NSPoint(x: cx + w / 2, y: shoulder))
    p.curve(to: NSPoint(x: cx, y: bottom),
            controlPoint1: NSPoint(x: cx + w / 2, y: bottom + h * 0.24),
            controlPoint2: NSPoint(x: cx + w * 0.24, y: bottom))
    p.curve(to: NSPoint(x: cx - w / 2, y: shoulder),
            controlPoint1: NSPoint(x: cx - w * 0.24, y: bottom),
            controlPoint2: NSPoint(x: cx - w / 2, y: bottom + h * 0.24))
    p.line(to: NSPoint(x: cx - w / 2, y: top - r))
    p.curve(to: NSPoint(x: cx - w / 2 + r, y: top),
            controlPoint1: NSPoint(x: cx - w / 2, y: top),
            controlPoint2: NSPoint(x: cx - w / 2, y: top))
    p.close()
    return p
}

/// Замочная скважина двумя отдельными фигурами. Объединять их в один контур
/// нельзя: appendOval и построенный вручную вырез обходятся в разные стороны,
/// и на их пересечении заливка взаимно уничтожается — при nonZero там
/// появлялась белая перемычка. Поэтому вырезаем каждую фигуру своим проходом.
func keyholeParts(_ s: CGFloat) -> [NSBezierPath] {
    let cx = s / 2
    let top = s * 0.755, bottom = s * 0.245
    let h = top - bottom
    let kcy = top - h * 0.40
    let kr = s * 0.044

    let circle = NSBezierPath(ovalIn: NSRect(x: cx - kr, y: kcy - kr,
                                             width: kr * 2, height: kr * 2))
    let slotBottom = kcy - h * 0.26
    let slot = NSBezierPath()
    slot.move(to: NSPoint(x: cx - kr * 0.55, y: kcy))
    slot.line(to: NSPoint(x: cx + kr * 0.55, y: kcy))
    slot.line(to: NSPoint(x: cx + kr * 1.05, y: slotBottom))
    slot.line(to: NSPoint(x: cx - kr * 1.05, y: slotBottom))
    slot.close()
    return [circle, slot]
}

/// Фон рисуется отдельной функцией, потому что его же приходится повторить
/// внутри скважины: так сквозь вырез виден ровно тот же градиент, а не дыра
/// в альфа-канале, которую оставил бы destinationOut.
func drawBackground(_ s: CGFloat) {
    NSGradient(colors: [NSColor(srgbRed: 0.42, green: 0.66, blue: 0.99, alpha: 1),
                        NSColor(srgbRed: 0.11, green: 0.25, blue: 0.69, alpha: 1)])!
        .draw(in: NSRect(x: 0, y: 0, width: s, height: s), angle: -90)
    NSGradient(colors: [NSColor(white: 1, alpha: 0.22), NSColor(white: 1, alpha: 0)])!
        .draw(in: NSRect(x: 0, y: s * 0.52, width: s, height: s * 0.48), angle: -90)
}

func render(size s: CGFloat) -> Data {
    let px = Int(s)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high

    NSGraphicsContext.saveGraphicsState()
    iconBody(s).addClip()
    drawBackground(s)
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current?.cgContext.setShadow(
        offset: CGSize(width: 0, height: -s * 0.010),
        blur: s * 0.026,
        color: NSColor(white: 0, alpha: 0.26).cgColor)
    NSColor.white.setFill()
    shield(s).fill()
    NSGraphicsContext.restoreGraphicsState()

    for part in keyholeParts(s) {
        NSGraphicsContext.saveGraphicsState()
        part.addClip()
        drawBackground(s)
        NSGraphicsContext.restoreGraphicsState()
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let outDir = CommandLine.arguments[1]
for (name, size) in [("icon_16x16", 16.0), ("icon_16x16@2x", 32.0),
                     ("icon_32x32", 32.0), ("icon_32x32@2x", 64.0),
                     ("icon_128x128", 128.0), ("icon_128x128@2x", 256.0),
                     ("icon_256x256", 256.0), ("icon_256x256@2x", 512.0),
                     ("icon_512x512", 512.0), ("icon_512x512@2x", 1024.0)] {
    let url = URL(fileURLWithPath: "\(outDir)/\(name).png")
    try! render(size: CGFloat(size)).write(to: url)
}
print("иконка отрисована в \(outDir)")
