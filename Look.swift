import AppKit
import CoreText

// MARK: - Малювання

enum Look {
    static let ringD: CGFloat = 22, boltW: CGFloat = 7

    static func width(bolt: Bool) -> CGFloat { ringD + (bolt ? boltW + 1.5 : 0) }

    static func numberFont(size: CGFloat) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: .heavy)
        if let d = base.fontDescriptor.withDesign(.rounded), let f = NSFont(descriptor: d, size: size) { return f }
        return base
    }

    /// Шрифт цифр залежно від довжини числа (одна/дві цифри крупніше, «100» дрібніше).
    static func digitFont(for txt: String) -> NSFont {
        numberFont(size: txt.count >= 3 ? 7.1 : 9.6)
    }

    static let ringStroke: CGFloat = 2.2

    /// Найдальший кут чорнила цифр від центру кільця й внутрішній радіус (за ним чорнило налізло б на дугу).
    static func inkFit(_ v: Int) -> (farthest: CGFloat, inner: CGFloat) {
        let txt = String(v)
        let font = digitFont(for: txt)
        let attr = NSAttributedString(string: txt, attributes: [.font: font])
        let line = CTLineCreateWithAttributedString(attr)
        let ink = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)       // чорнило відносно базової лінії
        let adv = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        // Як у battery(): по горизонталі центруємо за advance, по вертикалі за висотою великих літер.
        let x0 = -adv / 2 + ink.minX, x1 = -adv / 2 + ink.maxX
        let y0 = -font.capHeight / 2 + ink.minY, y1 = -font.capHeight / 2 + ink.maxY
        let far = max(hypot(x0, y0), hypot(x0, y1), hypot(x1, y0), hypot(x1, y1))
        return (far, ringD / 2 - ringStroke - 0.2)
    }

    /// Аркуш усіх значень 0…100 (масштаб 4×, темний фон) для огляду на накладання.
    static func sheet(to dir: URL) {
        let cols = 11, rows = 10, cw: CGFloat = 36, ch: CGFloat = 30, scale: CGFloat = 4
        let W = Int(CGFloat(cols) * cw * scale), H = Int(CGFloat(rows) * ch * scale)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: W, pixelsHigh: H, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let gc = NSGraphicsContext(bitmapImageRep: rep) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gc
        gc.cgContext.scaleBy(x: scale, y: scale)
        NSColor(white: 0.13, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: CGFloat(cols) * cw, height: CGFloat(rows) * ch).fill()
        var bad: [String] = []
        for v in 0...100 {
            let col = v % cols, row = v / cols
            let x = CGFloat(col) * cw + (cw - ringD) / 2
            let y = CGFloat(rows - 1 - row) * ch + (ch - ringD) / 2
            tint(battery(soc: Double(v), bolt: false), .white, alpha: 1).draw(in: NSRect(x: x, y: y, width: ringD, height: ringD))
            let f = inkFit(v)
            if f.farthest > f.inner - 0.8 {            // потрібен видимий зазор між цифрами й дугою
                 bad.append("\(v): чорнило \(String(format: "%.2f", f.farthest)) pt при внутрішньому радіусі \(String(format: "%.2f", f.inner))") }
        }
        NSGraphicsContext.restoreGraphicsState()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: dir.appendingPathComponent("ecoflowbar-all-values.png")) }
        print(bad.isEmpty ? "all 0...100 fit inside the ring" : "TOO TIGHT:\n" + bad.joined(separator: "\n"))
    }

    /// Кільце-шкала з числом у центрі (так заряд показує й застосунок EcoFlow). Шаблонна, одноколірна:
    /// доріжка бліда (alpha), дуга заряду суцільна, число завжди суцільне й не ріжеться заливкою.
    static func battery(soc: Double?, bolt: Bool) -> NSImage {
        let size = NSSize(width: width(bolt: bolt), height: ringD)
        let img = NSImage(size: size, flipped: false) { _ in
            let x0: CGFloat = bolt ? boltW + 1.5 : 0
            let stroke = ringStroke
            let c = NSPoint(x: x0 + ringD / 2, y: ringD / 2)
            let r = ringD / 2 - stroke / 2 - 0.2

            // доріжка
            let track = NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
            track.lineWidth = stroke
            NSColor.black.withAlphaComponent(0.34).setStroke()
            track.stroke()

            // дуга заряду: від верху за годинниковою стрілкою
            if let sc = soc, sc > 0 {
                let f = CGFloat(min(100, max(0, sc))) / 100
                let arc: NSBezierPath
                if f >= 0.995 {
                    arc = NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
                } else {
                    arc = NSBezierPath()
                    arc.appendArc(withCenter: c, radius: r, startAngle: 90, endAngle: 90 - max(f, 0.03) * 360, clockwise: true)
                }
                arc.lineWidth = stroke
                arc.lineCapStyle = .round
                NSColor.black.setStroke()
                arc.stroke()
            }

            // число в центрі
            let txt = soc.map { "\(Int($0.rounded()))" } ?? "–"
            let font = digitFont(for: txt)
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
            let ts = (txt as NSString).size(withAttributes: attrs)
            let baseline = c.y - font.capHeight / 2
            (txt as NSString).draw(at: NSPoint(x: c.x - ts.width / 2, y: baseline + font.descender), withAttributes: attrs)

            // блискавка поруч: живлення на вході
            if bolt {
                let bh: CGFloat = 11.5
                let ox: CGFloat = 0.3, oy = (ringD - bh) / 2
                let pts: [(CGFloat, CGFloat)] = [(0.64, 1.0), (0.10, 0.42), (0.46, 0.42), (0.34, 0.0), (0.92, 0.62), (0.54, 0.62)]
                let p = NSBezierPath()
                for (i, q) in pts.enumerated() {
                    let pt = NSPoint(x: ox + q.0 * boltW, y: oy + q.1 * bh)
                    i == 0 ? p.move(to: pt) : p.line(to: pt)
                }
                p.close()
                NSColor.black.setFill()
                p.fill()
            }
            return true
        }
        img.isTemplate = true
        return img
    }

    static func titleFont() -> NSFont {
        let base = NSFont.systemFont(ofSize: 12, weight: .semibold)
        if let d = base.fontDescriptor.withDesign(.rounded), let f = NSFont(descriptor: d, size: 12) { return f }
        return base
    }

    /// Прев'ю без екрана: іконка + число на темному й світлому фоні менюбару (масштаб 4×).
    static func preview(states: [(String, Double?, Bool, Bool)], to dir: URL, scale: CGFloat = 4, name: String = "ecoflowbar-preview.png") {
        let cellW: CGFloat = 52, cellH: CGFloat = 24
        let rows: [(NSColor, NSColor)] = [(NSColor(white: 0.13, alpha: 1), .white), (NSColor(white: 0.93, alpha: 1), .black)]
        let W = Int(cellW * CGFloat(states.count) * scale), H = Int(cellH * CGFloat(rows.count) * scale)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: W, pixelsHigh: H, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let gc = NSGraphicsContext(bitmapImageRep: rep) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gc
        gc.cgContext.scaleBy(x: scale, y: scale)
        for (ri, row) in rows.enumerated() {
            let y0 = cellH * CGFloat(rows.count - 1 - ri)
            row.0.setFill()
            NSRect(x: 0, y: y0, width: cellW * CGFloat(states.count), height: cellH).fill()
            for (ci, st) in states.enumerated() {
                let x0 = cellW * CGFloat(ci)
                let im = battery(soc: st.1, bolt: st.2)
                let tinted = tint(im, row.1, alpha: st.3 ? 0.45 : 1)
                tinted.draw(in: NSRect(x: x0 + 12, y: y0 + (cellH - im.size.height) / 2, width: im.size.width, height: im.size.height))
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: dir.appendingPathComponent(name))
        }
    }

    static func tint(_ img: NSImage, _ color: NSColor, alpha: CGFloat) -> NSImage {
        let out = NSImage(size: img.size, flipped: false) { r in
            img.draw(in: r)
            color.withAlphaComponent(alpha).setFill()
            r.fill(using: .sourceIn)
            return true
        }
        return out
    }
}
