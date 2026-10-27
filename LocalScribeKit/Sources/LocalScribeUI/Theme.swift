import SwiftUI

/// LocalScribe's palette: cool paper, an ink-blue accent, and red reserved for recording. Every colour is semantic: pick
/// by meaning ("danger", "cloud"), never by hue. See DESIGN.md.
public enum Theme {
    // LocalScribe's own palette: cool neutrals and ink blue.

    // Surfaces
    /// The page: cool off-white / near-black. Behind documents and lists.
    public static let paper = Color(light: 0xFAFAFB, dark: 0x18191D)
    /// Cards, rows, menus and the chat bar that sit on paper.
    public static let paperRaised = Color(light: 0xFFFFFF, dark: 0x212227)
    /// Wells, inputs, the sidebar and illustration backdrops.
    public static let paperSunken = Color(light: 0xF1F2F5, dark: 0x131417)
    /// Quiet borders and dividers.
    public static let hairline = Color(light: 0xE7E8EC, dark: 0x2C2E35)
    /// Field outlines and dividers that must read.
    public static let hairlineStrong = Color(light: 0xD5D7DF, dark: 0x3A3D46)

    // Ink
    public static let ink = Color(light: 0x1F2128, dark: 0xF3F4F7)
    public static let inkSecondary = Color(light: 0x5F6370, dark: 0x9EA2AE)
    public static let inkTertiary = Color(light: 0x9A9DA8, dark: 0x6F7380)

    // Meaning
    /// Selection, links, the active state. Ink blue, dark enough to read as text on paper.
    public static let accent = Color(light: 0x3B4FD8, dark: 0x8C9BFF)
    /// Ink blue at about 12 %: selection, hover and "your" caption bubbles.
    public static let accentWash = Color(light: 0xE8EBFB, dark: 0x23284A)
    /// The periwinkle of the nub's "Meeting detected" card and highlights. Takes dark ink in both appearances.
    public static let highlight = Color(light: 0xC9D0FF, dark: 0xC9D0FF)
    /// Recording only.
    public static let record = Color(light: 0xD93F3A, dark: 0xFF6159)
    /// Errors and destructive outcomes. Distinct from recording red and from cloud amber.
    public static let danger = Color(light: 0xBD4A30, dark: 0xEC7558)
    public static let success = Color(light: 0x2F7D4F, dark: 0x6FCB93)
    /// "Uses the cloud": always paired with text, never colour alone.
    public static let cloud = Color(light: 0xA35F00, dark: 0xF0B35A)
    /// The nub's dancing bars while they hear you.
    public static let listening = Color(light: 0x6E8BFF, dark: 0x6E8BFF)

    /// The only gradient: gives the record button its depth.
    public static var recordGradient: LinearGradient {
        LinearGradient(colors: [Color(light: 0xEE5A54, dark: 0xFF7A72), record], startPoint: .top, endPoint: .bottom)
    }

    /// Muted, ink-friendly hues; ordered so the first few speakers (the common case) are the most distinct.
    public static let speakerPalette: [Color] = [
        Color(light: 0x3B5B9A, dark: 0x8FAAE0),  // ink blue
        Color(light: 0xB4602D, dark: 0xE7A06C),  // terracotta
        Color(light: 0x3C7F5F, dark: 0x79C29C),  // sage
        Color(light: 0x7A548F, dark: 0xBD99D3),  // plum
        Color(light: 0xA84867, dark: 0xE38BA6),  // rose
        Color(light: 0x2F7C85, dark: 0x6EC1CA),  // teal
        Color(light: 0x8C7330, dark: 0xD2B76A),  // ochre
        Color(light: 0x5E6670, dark: 0xA4ACB6),  // slate
    ]

    public static func speakerColor(_ index: Int) -> Color {
        speakerPalette[((index % speakerPalette.count) + speakerPalette.count) % speakerPalette.count]
    }

    /// Folder tints reuse the speaker palette so the app has one set of hues.
    public static func folderColor(_ index: Int) -> Color { speakerColor(index) }
}

public extension Color {
    /// A colour that adapts to light/dark appearance. watchOS is always dark.
    init(light: UInt32, dark: UInt32) {
        #if os(macOS)
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua]) != nil
                ? NSColor(hex: dark) : NSColor(hex: light)
        })
        #elseif os(watchOS)
        self.init(uiColor: UIColor(hex: dark))
        #else
        self.init(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) })
        #endif
    }
}

#if os(macOS)
import AppKit
extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
#else
import UIKit
extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
#endif
