import AppKit
import SwiftUI

/// Official marks are bundled as vector PDFs so macOS can render them at any scale.
/// Original fills and proportions are retained; OpenAI's supplied clear space stays intact.
struct BrandLogo: View {
    let asset: String
    let size: CGFloat

    private static let images: [String: NSImage] = {
        var result: [String: NSImage] = [:]
        for name in ["claude", "openai", "github", "gitlab"] {
            if let url = Bundle.main.url(forResource: name, withExtension: "pdf"),
               let image = NSImage(contentsOf: url) {
                image.isTemplate = false
                result[name] = image
            }
        }
        return result
    }()

    var body: some View {
        if let image = Self.images[asset] {
            Image(nsImage: image)
                .renderingMode(.original)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        }
    }
}
