import CoreImage
import LucideIcons
import SwiftUI
import UIKit

struct LucideIcon: View {
    let name: String
    var size: CGFloat = 18

    var body: some View {
        Group {
            if let image = LucideStrokeRenderer.image(
                named: name,
                size: size,
                strokeWidth: InboxDesign.Icon.strokeWidth
            ) {
                Image(uiImage: image)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
            } else {
                Color.clear
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

@MainActor
private enum LucideStrokeRenderer {
    private static let sourceStrokeWidth: CGFloat = 2
    private static let context = CIContext(options: [.cacheIntermediates: false])
    private static let cache = NSCache<NSString, UIImage>()

    static func image(named name: String, size: CGFloat, strokeWidth: CGFloat) -> UIImage? {
        let scale = UITraitCollection.current.displayScale > 0
            ? UITraitCollection.current.displayScale
            : UIScreen.main.scale
        let key = "\(name)-\(size)-\(strokeWidth)-\(scale)" as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }

        guard let source = UIImage(lucideId: name) else { return nil }

        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        format.scale = scale
        let bounds = CGRect(origin: .zero, size: CGSize(width: size, height: size))
        let rendered = UIGraphicsImageRenderer(size: bounds.size, format: format).image { _ in
            source.withRenderingMode(.alwaysOriginal).draw(in: bounds)
        }

        guard strokeWidth < sourceStrokeWidth,
              let input = CIImage(image: rendered),
              let filter = CIFilter(name: "CIMorphologyMinimum") else {
            let template = rendered.withRenderingMode(.alwaysTemplate)
            cache.setObject(template, forKey: key)
            return template
        }

        // Lucide strokes scale with the icon. Erode the alpha mask by half of
        // the unwanted stroke so a 1.25-unit source line replaces the default 2.
        let currentStrokeInPixels = (sourceStrokeWidth / 24) * size * scale
        let targetStrokeInPixels = (strokeWidth / 24) * size * scale
        let erosionRadius = max(0, (currentStrokeInPixels - targetStrokeInPixels) / 2)

        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(erosionRadius, forKey: kCIInputRadiusKey)

        guard let output = filter.outputImage,
              let cgImage = context.createCGImage(output, from: input.extent) else {
            let template = rendered.withRenderingMode(.alwaysTemplate)
            cache.setObject(template, forKey: key)
            return template
        }

        let template = UIImage(cgImage: cgImage, scale: scale, orientation: .up)
            .withRenderingMode(.alwaysTemplate)
        cache.setObject(template, forKey: key)
        return template
    }
}

struct LucideLabel: View {
    let title: String
    let icon: String
    var iconSize: CGFloat = 17
    var spacing: CGFloat = InboxDesign.Spacing.small

    var body: some View {
        Label {
            Text(title)
        } icon: {
            LucideIcon(name: icon, size: iconSize)
        }
        .labelStyle(.titleAndIcon)
    }
}
