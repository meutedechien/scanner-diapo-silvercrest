// Génère AppIcon.icns : une diapo (cadre en carton + paysage) sur fond de table lumineuse
// Usage : swift icon.swift   (produit AppIcon.icns dans le dossier courant)
import AppKit

func drawIcon(_ S: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let c = NSGraphicsContext.current!.cgContext
    c.scaleBy(x: S / 1024, y: S / 1024)
    let cs = CGColorSpaceCreateDeviceRGB()
    func col(_ h: UInt32, _ a: CGFloat = 1) -> CGColor {
        CGColor(red: CGFloat(h >> 16 & 255) / 255, green: CGFloat(h >> 8 & 255) / 255, blue: CGFloat(h & 255) / 255, alpha: a)
    }
    func grad(_ cols: [CGColor], _ p0: CGPoint, _ p1: CGPoint) {
        let g = CGGradient(colorsSpace: cs, colors: cols as CFArray, locations: nil)!
        c.drawLinearGradient(g, start: p0, end: p1, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }

    // Fond : carré arrondi (grille macOS : 824 px dans 1024), table lumineuse
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let squircle = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: col(0x000000, 0.35))
    c.addPath(squircle); c.setFillColor(col(0x1B2A4A)); c.fillPath()
    c.restoreGState()
    c.saveGState()
    c.addPath(squircle); c.clip()
    grad([col(0x2B4C7E), col(0x14213D)], CGPoint(x: 512, y: 924), CGPoint(x: 512, y: 100))
    // halo de lumière derrière la diapo
    let halo = CGGradient(colorsSpace: cs, colors: [col(0xFFF4D6, 0.55), col(0xFFF4D6, 0)] as CFArray, locations: [0, 1])!
    c.drawRadialGradient(halo, startCenter: CGPoint(x: 512, y: 530), startRadius: 0,
                         endCenter: CGPoint(x: 512, y: 530), endRadius: 430, options: [])
    c.restoreGState()

    // Diapo légèrement inclinée
    c.saveGState()
    c.translateBy(x: 512, y: 520)
    c.rotate(by: -8 * .pi / 180)
    let mount = CGRect(x: -270, y: -270, width: 540, height: 540)
    let mountPath = CGPath(roundedRect: mount, cornerWidth: 44, cornerHeight: 44, transform: nil)
    c.saveGState()
    c.setShadow(offset: CGSize(width: 10, height: -22), blur: 36, color: col(0x000000, 0.5))
    c.addPath(mountPath); c.setFillColor(col(0xF4EFE4)); c.fillPath()
    c.restoreGState()
    c.saveGState()
    c.addPath(mountPath); c.clip()
    grad([col(0xFBF8F1), col(0xE6DECE)], CGPoint(x: -270, y: 270), CGPoint(x: 270, y: -270))
    c.restoreGState()

    // Fenêtre 24×36 (paysage) avec coins arrondis
    let win = CGRect(x: -205, y: -140, width: 410, height: 280)
    let winPath = CGPath(roundedRect: win, cornerWidth: 18, cornerHeight: 18, transform: nil)
    c.saveGState()
    c.addPath(winPath); c.clip()
    // ciel au coucher du soleil
    grad([col(0x3A2E6E), col(0xE0607E), col(0xFFB35C)], CGPoint(x: 0, y: 140), CGPoint(x: 0, y: -30))
    // soleil
    c.setFillColor(col(0xFFE7A0)); c.fillEllipse(in: CGRect(x: 30, y: -40, width: 110, height: 110))
    // montagnes
    func mountain(_ pts: [CGPoint], _ color: CGColor) {
        c.beginPath(); c.move(to: CGPoint(x: -220, y: -150))
        pts.forEach { c.addLine(to: $0) }
        c.addLine(to: CGPoint(x: 220, y: -150)); c.closePath()
        c.setFillColor(color); c.fillPath()
    }
    mountain([CGPoint(x: -220, y: -10), CGPoint(x: -120, y: 70), CGPoint(x: -40, y: 5), CGPoint(x: 60, y: 60),
              CGPoint(x: 150, y: -5), CGPoint(x: 220, y: 20)], col(0x7A3E6B))
    mountain([CGPoint(x: -220, y: -70), CGPoint(x: -90, y: 0), CGPoint(x: 20, y: -60), CGPoint(x: 130, y: 15),
              CGPoint(x: 220, y: -40)], col(0x3F2656))
    // lac
    c.setFillColor(col(0x251A40)); c.fill(CGRect(x: -220, y: -150, width: 440, height: 60))
    c.setFillColor(col(0xFFD58A, 0.6))
    for (i, w) in [90.0, 60, 36].enumerated() {
        c.fill(CGRect(x: 85 - w / 2, y: -105 - Double(i) * 14, width: w, height: 5))
    }
    c.restoreGState()
    // biseau intérieur de la fenêtre
    c.addPath(winPath); c.setStrokeColor(col(0x000000, 0.25)); c.setLineWidth(6); c.strokePath()

    // petite étiquette numérotée sur le cadre
    c.setFillColor(col(0xD9534F))
    c.fill(CGRect(x: -205, y: -225, width: 120, height: 36))
    c.setFillColor(col(0x8A8170, 0.55))
    for i in 0..<3 { c.fill(CGRect(x: -40 + Double(i) * 85, y: -212, width: 70, height: 10)) }
    c.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let fm = FileManager.default
let dir = "AppIcon.iconset"
try? fm.removeItem(atPath: dir)
try! fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
for s in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = CGFloat(s * scale)
        let name = scale == 1 ? "icon_\(s)x\(s).png" : "icon_\(s)x\(s)@2x.png"
        try! drawIcon(px).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(dir)/\(name)"))
    }
}
try! drawIcon(1024).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "icon_preview.png"))
print("iconset OK")
