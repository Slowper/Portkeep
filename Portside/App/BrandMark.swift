import AppKit
import SwiftUI

enum BrandMark {
    static let blue = NSColor(srgbRed: 47 / 255, green: 123 / 255, blue: 1, alpha: 1)

    /// Menu-bar template: black, so macOS tints it for light/dark.
    static func statusItemImage(pointSize: CGFloat = 16) -> NSImage {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let pixel = max(16, ceil(pointSize * scale))
        let image = render(size: pixel, color: .black)
        image.isTemplate = true
        image.size = NSSize(width: pointSize, height: pointSize)
        image.accessibilityDescription = Product.name
        return image
    }

    static func render(size: CGFloat, color: NSColor) -> NSImage {
        let extent = NSSize(width: size, height: size)
        return NSImage(size: extent, flipped: true) { rect in
            color.setFill()
            path(in: rect).fill()
            return true
        }
    }

    /// Square frame with top/bottom notches and a center bar — the H-port mark.
    static func path(in rect: CGRect) -> NSBezierPath {
        let inset = rect.width * 0.17
        let box = rect.insetBy(dx: inset, dy: inset)
        let corner = max(1.2, box.width * 0.07)
        let thickness = box.width * 0.22
        let notchW = box.width * 0.30
        let notchH = thickness * 0.92
        let barH = thickness

        let path = NSBezierPath()
        path.windingRule = .evenOdd
        path.appendRoundedRect(box, xRadius: corner, yRadius: corner)

        let notchX = box.midX - notchW / 2
        path.appendRoundedRect(
            CGRect(x: notchX, y: box.minY - 1, width: notchW, height: notchH + 1),
            xRadius: corner * 0.7,
            yRadius: corner * 0.7
        )
        path.appendRoundedRect(
            CGRect(x: notchX, y: box.maxY - notchH, width: notchW, height: notchH + 1),
            xRadius: corner * 0.7,
            yRadius: corner * 0.7
        )

        let holeX = box.minX + thickness
        let holeW = box.width - thickness * 2
        let holeCorner = max(0.8, holeW * 0.08)
        let topHoleY = box.minY + thickness
        let topHoleH = box.midY - barH / 2 - topHoleY
        let bottomHoleY = box.midY + barH / 2
        let bottomHoleH = box.maxY - thickness - bottomHoleY
        if topHoleH > 0.5 {
            path.appendRoundedRect(
                CGRect(x: holeX, y: topHoleY, width: holeW, height: topHoleH),
                xRadius: holeCorner,
                yRadius: holeCorner
            )
        }
        if bottomHoleH > 0.5 {
            path.appendRoundedRect(
                CGRect(x: holeX, y: bottomHoleY, width: holeW, height: bottomHoleH),
                xRadius: holeCorner,
                yRadius: holeCorner
            )
        }
        return path
    }
}

struct BrandMarkView: View {
    var size: CGFloat = 22
    var color: Color = Color(nsColor: BrandMark.blue)

    var body: some View {
        Canvas { context, canvasSize in
            let rect = CGRect(origin: .zero, size: canvasSize)
            context.fill(Path(BrandMark.path(in: rect).cgPath), with: .color(color))
        }
        .frame(width: size, height: size)
        .accessibilityLabel(Product.name)
    }
}
