import UIKit

/// Simgenin bildirim görseli: uygulamadaki yer rozetinin aynısı.
///
/// Hem bildirim uzantısı (sunucu push'u) hem uygulamanın yerel yedek
/// bildirimi kullanır; iki yol aynı görseli üretir.
enum PlaceIconArtwork {
    static func writePNG(for icon: PlaceIcon) -> URL? {
        let side: CGFloat = 120
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side))
        let image = renderer.image { _ in
            let rect = CGRect(x: 0, y: 0, width: side, height: side)
            let (r, g, b) = icon.rgb
            UIColor(red: r, green: g, blue: b, alpha: 1).setFill()
            UIBezierPath(roundedRect: rect, cornerRadius: side * 0.26).fill()

            let config = UIImage.SymbolConfiguration(pointSize: side * 0.5, weight: .semibold)
            guard let symbol = UIImage(systemName: icon.symbolName, withConfiguration: config)?
                .withTintColor(.white, renderingMode: .alwaysOriginal) else { return }
            let size = symbol.size
            symbol.draw(in: CGRect(
                x: (side - size.width) / 2,
                y: (side - size.height) / 2,
                width: size.width,
                height: size.height
            ))
        }
        guard let data = image.pngData() else { return nil }
        // iOS eki kendi alanına TAŞIR; her bildirim kendi dosyasını kullanır.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("place-\(icon.rawValue)-\(UUID().uuidString).png")
        do {
            try data.write(to: url)
            return url
        } catch {
            return nil
        }
    }
}
