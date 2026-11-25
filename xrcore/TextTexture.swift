import CoreGraphics
import Metal
import UIKit

// Renders a VR UI panel's content (rounded card + accent bar + text) into a
// Metal texture via CoreGraphics. Textures are premultiplied RGBA, matching
// the scene pipeline's blend state.
final class PanelTextRenderer {

    struct Content {
        var title: String
        var subtitle: String
        var statusLine: String = ""
        var accent: UIColor = UIColor(red: 0.95, green: 0.45, blue: 0.25, alpha: 1)
    }

    let texture: MTLTexture
    let width: Int
    let height: Int

    /// Creates a (re)drawable panel texture. Content can be re-rendered into
    /// the same texture (e.g. live connection status) with render(_:).
    init(device: MTLDevice, width: Int = 512, height: Int = 320) {
        self.width = width
        self.height = height
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
        let path = UIBezierPath(roundedRect: bgRect, cornerRadius: 26)
        UIColor(red: 0.07, green: 0.08, blue: 0.11, alpha: 0.94).setFill()
        path.fill()
        UIColor(white: 1, alpha: 0.10).setStroke()
        path.lineWidth = 2
        path.stroke()

        // Accent bar (left edge)
        let accentRect = CGRect(x: 22, y: 34, width: 8, height: h - 68)
        let accentPath = UIBezierPath(roundedRect: accentRect, cornerRadius: 4)
        content.accent.setFill()
        accentPath.fill()

        // Title
        drawString(ctx: ctx, text: content.title,
                   rect: CGRect(x: 46, y: 34, width: w - 70, height: 56),
                   font: .boldSystemFont(ofSize: 40), color: .white)

        // Subtitle (wraps)
        drawString(ctx: ctx, text: content.subtitle,
                   rect: CGRect(x: 46, y: 96, width: w - 70, height: h - 160),
                   font: .systemFont(ofSize: 26), color: UIColor(white: 1, alpha: 0.72))

        // Status line (bottom)
        if !content.statusLine.isEmpty {
            drawString(ctx: ctx, text: content.statusLine,
                       rect: CGRect(x: 46, y: h - 58, width: w - 70, height: 34),
                       font: .monospacedSystemFont(ofSize: 22, weight: .medium),
                       color: content.accent)
        }

        // Upload (CG rows are top-first, matching texture v=0 = top).
        texture.replace(region: MTLRegion(origin: MTLOrigin(), size: MTLSize(width: width, height: height, depth: 1)),
                        mipmapLevel: 0, withBytes: &pixels, bytesPerRow: bytesPerRow)
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
