import CoreText
import SwiftUI

/// Spacing on a 4-pt grid. Use these instead of literals (DESIGN.md › Tokens).
public enum Space {
    public static let xxs: CGFloat = 2
    public static let xs: CGFloat = 4
    public static let s: CGFloat = 8
    public static let m: CGFloat = 12
    public static let l: CGFloat = 16
    public static let xl: CGFloat = 24
    public static let xxl: CGFloat = 32
    public static let xxxl: CGFloat = 48
}

/// Corner radii (6/8/12/16/24). Always continuous ("squircle") corners.
public enum Radius {
    /// Chips, small badges.
    public static let s: CGFloat = 6
    /// Buttons, fields, thumbnails, rows.
    public static let m: CGFloat = 8
    /// Cards.
    public static let l: CGFloat = 12
    /// Sheets, panels, illustrations.
    public static let xl: CGFloat = 16
    /// The nub's prompt card.
    public static let xxl: CGFloat = 24

    public static func shape(_ radius: CGFloat) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
    }
}

/// Motion. Only an active recording animates continuously; everything else is a one-shot spring.
public enum Motion {
    public static let snappy = Animation.spring(response: 0.3, dampingFraction: 0.82)
    public static let smooth = Animation.spring(response: 0.45, dampingFraction: 0.9)
    public static let recordPulse = Animation.easeInOut(duration: 1.4)
}

/// Sizes that have to stay fixed regardless of text size.
public enum Size {
    /// Minimum tap/click target.
    public static let hitTarget: CGFloat = 44
    /// Readable line length for documents.
    public static let readableWidth: CGFloat = 720
    /// Room left under a scrolling page so its end clears the floating bottom bar (Ask, Stop, export progress).
    public static let floatingBarInset: CGFloat = 90
}

/// IBM Plex Serif for titles and Hanken Grotesk for everything else. Both are bundled under
/// the SIL Open Font License (see `Fonts/`). The Watch keeps the system font, which reads better at that size.
public enum Typeface {
    public static let display = "IBM Plex Serif"
    public static let text = "Hanken Grotesk"

    /// Registers the bundled fonts for this process, once. Every font token touches this first, so no app wiring is
    /// needed. If a file fails to register, `Font.custom` falls back to the system font at the same size.
    static let registered: Bool = {
        #if os(watchOS)
        return false
        #else
        let urls = Bundle.module.urls(forResourcesWithExtension: "ttf", subdirectory: "Fonts") ?? []
        return urls.allSatisfy { CTFontManagerRegisterFontsForURL($0 as CFURL, .process, nil) }
        #endif
    }()

    /// iPhone text sits a step larger than the Mac's (17 pt is its body size).
    #if os(iOS)
    static let scale: CGFloat = 1.15
    #else
    static let scale: CGFloat = 1
    #endif
}

/// The type scale (DESIGN.md › Type). Pick by role; weights are added at the call site (`.weight(.medium)`).
public extension Font {
    // Titles: regular-weight serif, never bold.
    /// Meeting titles and onboarding (36).
    static let displayLarge = display(36, .largeTitle)
    /// Page titles (h2, 28).
    static let displayMedium = display(28, .title)
    /// Section headers such as "Today" and "Coming up" (h3, 24).
    static let displaySmall = display(24, .title2)

    // Text: the sans face.
    /// Headings inside notes and cards (18).
    static let heading = text(18, .title3).weight(.semibold)
    /// The notes editor and generated notes (16).
    static let editor = text(16, .body)
    /// The default for UI text (14).
    static let base = text(14, .body)
    /// Secondary UI text and metadata (13).
    static let small = text(13, .callout)
    /// Captions, chips and badges (12).
    static let label = text(12, .footnote)
    /// The smallest text: counters and fine print (11).
    static let micro = text(11, .caption)
    static let mono = Font.system(size: 13 * Typeface.scale, design: .monospaced)

    /// List rows.
    static let rowTitle = base.weight(.medium)
    /// Quiet metadata under titles.
    static let meta = small
    /// Timers: fixed-width digits so they don't jitter.
    static let timer = text(28, .title).weight(.medium).monospacedDigit()

    private static func display(_ size: CGFloat, _ style: Font.TextStyle) -> Font {
        #if os(watchOS)
        .system(style, design: .serif)
        #else
        _ = Typeface.registered
        return .custom(Typeface.display, size: size, relativeTo: style)
        #endif
    }

    private static func text(_ size: CGFloat, _ style: Font.TextStyle) -> Font {
        #if os(watchOS)
        .system(style)
        #else
        _ = Typeface.registered
        return .custom(Typeface.text, size: (size * Typeface.scale).rounded(), relativeTo: style)
        #endif
    }
}

public extension View {
    /// A raised card on paper: hairline border, no heavy shadow.
    func card(padding: CGFloat = Space.l, radius: CGFloat = Radius.l) -> some View {
        self
            .padding(padding)
            .background(Theme.paperRaised, in: Radius.shape(radius))
            .overlay(Radius.shape(radius).strokeBorder(Theme.hairline, lineWidth: 1))
    }

    /// The page background used behind documents and lists.
    func paperBackground() -> some View {
        background(Theme.paper.ignoresSafeArea())
    }
}
