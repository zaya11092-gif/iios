import CoreGraphics
import Metal
import UIKit

// Renders a VR UI panel's content (rounded card + accent bar + text) into a
// Metal texture via CoreGraphics. Textures are premultiplied RGBA, matching
// the scene pipeline's blend state.
final class PanelTextRenderer {

    enum Style {
        case card         // wide info card (title + subtitle + status)
        case button       // square menu-bar button (centered label + status)
        case menuIcon     // palm gesture indicator: 3 accent bars glyph
    }

    struct Content {
        var title: String
        var subtitle: String = ""
        var statusLine: String = ""
        var accent: UIColor = UIColor(red: 0.95, green: 0.45, blue: 0.25, alpha: 1)
    }

    let texture: MTLTexture
    let width: Int
    let height: Int
    let style: Style

    /// Creates a (re)drawable panel texture. Content can be re-rendered into
    /// the same texture (e.g. live connection status) with render(_:).
    init(device: MTLDevice, width: Int = 512, height: Int = 320, style: Style = .card) {
        self.width = width
        self.height = height
        self.style = style
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        desc.usage = [.shaderRead]
        desc.storageMode = .shared
        texture = device.makeTexture(descriptor: desc)!
    }

    func render(_ content: Content) {
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: width * height * 4)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: &pixels,
                                  width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                  space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }

        // CG origin is bottom-left; flip for top-down drawing.
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)

        let w = CGFloat(width), h = CGFloat(height)

        // Card background
        let bgRect = CGRect(x: 6, y: 6, width: w - 12, height: h - 12)
        let corner: CGFloat = style == .card ? 26 : 22
        let path = UIBezierPath(roundedRect: bgRect, cornerRadius: corner)
        UIColor(red: 0.07, green: 0.08, blue: 0.11, alpha: 0.94).setFill()
        path.fill()
        UIColor(white: 1, alpha: 0.10).setStroke()
        path.lineWidth = 2
        path.stroke()

        switch style {
        case .card:
            // Accent bar (left edge)
            let accentRect = CGRect(x: 22, y: 34, width: 8, height: h - 68)
            let accentPath = UIBezierPath(roundedRect: accentRect, cornerRadius: 4)
            content.accent.setFill()
            accentPath.fill()
            drawString(ctx: ctx, text: content.title,
                       rect: CGRect(x: 46, y: 34, width: w - 70, height: 56),
                       font: .boldSystemFont(ofSize: 40), color: .white)
            drawString(ctx: ctx, text: content.subtitle,
                       rect: CGRect(x: 46, y: 96, width: w - 70, height: h - 160),
                       font: .systemFont(ofSize: 26), color: UIColor(white: 1, alpha: 0.72))
            if !content.statusLine.isEmpty {
                drawString(ctx: ctx, text: content.statusLine,
                           rect: CGRect(x: 46, y: h - 58, width: w - 70, height: 34),
                           font: .monospacedSystemFont(ofSize: 22, weight: .medium),
                           color: content.accent)
            }

        case .button:
            // Centered label + optional status line under it.
            drawString(ctx: ctx, text: content.title,
                       rect: CGRect(x: 12, y: h * 0.28, width: w - 24, height: h * 0.34),
                       font: .boldSystemFont(ofSize: 44), color: .white,
                       align: .center)
            if !content.statusLine.isEmpty {
                drawString(ctx: ctx, text: content.statusLine,
                           rect: CGRect(x: 12, y: h * 0.64, width: w - 24, height: 40),
                           font: .monospacedSystemFont(ofSize: 24, weight: .semibold),
                           color: content.accent, align: .center)
            }
            // bottom accent strip
            let strip = CGRect(x: 30, y: h - 26, width: w - 60, height: 8)
            let stripPath = UIBezierPath(roundedRect: strip, cornerRadius: 4)
            content.accent.setFill()
            stripPath.fill()

        case .menuIcon:
            // Quest-style system-gesture indicator: three accent bars.
            UIColor(white: 1, alpha: 0.08).setFill()
            UIBezierPath(roundedRect: bgRect.insetBy(dx: 10, dy: 10), cornerRadius: 30).fill()
            let barH: CGFloat = h * 0.075
            let barW: CGFloat = w * 0.5
            for i in 0..<3 {
                let y = h * 0.5 + (CGFloat(i) - 1) * barH * 2.1 - barH / 2
                let bar = UIBezierPath(roundedRect: CGRect(x: (w - barW) / 2, y: y, width: barW, height: barH),
                                       cornerRadius: barH / 2)
                content.accent.setFill()
                bar.fill()
            }
        }

        // Upload (CG rows are top-first, matching texture v=0 = top).
        texture.replace(region: MTLRegion(origin: MTLOrigin(), size: MTLSize(width: width, height: height, depth: 1)),
                        mipmapLevel: 0, withBytes: &pixels, bytesPerRow: bytesPerRow)
    }

    private func drawString(ctx: CGContext, text: String, rect: CGRect, font: UIFont, color: UIColor,
                            align: NSTextAlignment = .left) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = align
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ]
        let attr = NSAttributedString(string: text, attributes: attrs)
        UIGraphicsPushContext(ctx)
        attr.draw(with: rect.insetBy(dx: 0, dy: 2), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
        UIGraphicsPopContext()
    }

    private func drawString(ctx: CGContext, text: String, rect: CGRect, font: UIFont, color: UIColor) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
        ]
        let attr = NSAttributedString(string: text, attributes: attrs)
        // Draw each wrapped line via CTFramesetter-free approach: use
        // NSAttributedString.boundingRect + draw(with:).
        UIGraphicsPushContext(ctx)
        attr.draw(with: rect.insetBy(dx: 0, dy: 2), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
        UIGraphicsPopContext()
    }
}
