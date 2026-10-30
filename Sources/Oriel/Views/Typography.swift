import AppKit
import SwiftUI

extension Font {
    /// A system text style whose Arabic glyphs come from IBM Plex Sans Arabic.
    /// Latin text keeps the system font, so mixed strings such as "جهاز Windows 11" use each script's own face.
    static func oriel(_ style: NSFont.TextStyle, weight: NSFont.Weight? = nil) -> Font {
        let base = NSFont.preferredFont(forTextStyle: style)
        let weight = weight ?? base.weight
        let latin = NSFont.systemFont(ofSize: base.pointSize, weight: weight)
        let arabic = NSFontDescriptor(fontAttributes: [
            .family: "IBM Plex Sans Arabic",
            .traits: [NSFontDescriptor.TraitKey.weight: weight],
        ])
        let descriptor = latin.fontDescriptor.addingAttributes([.cascadeList: [arabic]])
        return Font(NSFont(descriptor: descriptor, size: base.pointSize) ?? latin)
    }
}

private extension NSFont {
    var weight: NSFont.Weight {
        let traits = fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any]
        return (traits?[.weight] as? CGFloat).map { NSFont.Weight($0) } ?? .regular
    }
}
