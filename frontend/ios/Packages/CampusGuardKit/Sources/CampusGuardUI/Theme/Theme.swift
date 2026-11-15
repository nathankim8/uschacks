import SwiftUI
import CoreText

/// Campus Guard visual language (from the Figma frames 1-6 and the design build): warm white
/// page, cardinal red, Charis SIL for display type and DM Sans for text. Both fonts ship in
/// this package (Resources/Fonts) and are registered on first use. If registration ever
/// fails, SwiftUI falls back to the system font, so nothing breaks.
public enum CG {
    public static let page = Color(red: 1, green: 0.98, blue: 0.98)                 // #FFFAFA
    public static let cardinal = Color(red: 0.478, green: 0.051, blue: 0.051)       // #7A0D0D
    public static let crimson = Color(red: 0.608, green: 0.110, blue: 0.122)        // #9B1C1F
    public static let alarm = Color(red: 0.690, green: 0.149, blue: 0.125)          // #B02620
    public static let alarmBright = Color(red: 1, green: 0.102, blue: 0.071)        // #FF1A12
    public static let alarmRing = Color(red: 0.831, green: 0.102, blue: 0.086)      // #D41A16
    public static let ink = Color(red: 0.090, green: 0.078, blue: 0.078)            // #171414
    public static let muted = Color(red: 0.420, green: 0.388, blue: 0.388)          // #6B6363
    public static let hairline = Color(red: 0.902, green: 0.875, blue: 0.863)       // #E6DFDC
    public static let blush = Color(red: 0.984, green: 0.945, blue: 0.941)          // #FBF1F0
    public static let rose = Color(red: 0.804, green: 0.624, blue: 0.620)           // #CD9F9E
    public static let ok = Color(red: 0.184, green: 0.561, blue: 0.306)             // #2F8F4E
    public static let amber = Color(red: 0.761, green: 0.486, blue: 0.055)          // #C27C0E

    /// Charis SIL. `.bold()` / `.italic()` on a Text pick the matching face.
    public static func display(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        registerFonts()
        return .custom(isHeavy(weight) ? "CharisSIL-Bold" : "CharisSIL", size: size, relativeTo: .largeTitle)
    }

    /// Charis SIL italic, for the text links ("It's me", "passive ⟶", "play nearby sound").
    public static func serifItalic(_ size: CGFloat, bold: Bool = false) -> Font {
        registerFonts()
        return .custom(bold ? "CharisSIL-BoldItalic" : "CharisSIL-Italic", size: size, relativeTo: .title2)
    }

    /// Scales with Dynamic Type while keeping the Figma proportions.
    public static func displayStyle(_ style: Font.TextStyle, weight: Font.Weight = .bold) -> Font {
        display(defaultSize(style), weight: weight)
    }

    /// DM Sans, the design's text face.
    public static func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        registerFonts()
        let name: String
        switch weight {
        case .medium: name = "DMSans9pt-Medium"
        case .semibold: name = "DMSans9pt-SemiBold"
        case .bold, .heavy, .black: name = "DMSans9pt-Bold"
        default: name = "DMSans9pt-Regular"
        }
        return .custom(name, size: size, relativeTo: size >= 17 ? .body : size >= 14 ? .subheadline : .caption)
    }

    private static func isHeavy(_ w: Font.Weight) -> Bool {
        w == .bold || w == .semibold || w == .heavy || w == .black
    }

    private static func defaultSize(_ style: Font.TextStyle) -> CGFloat {
        switch style {
        case .largeTitle: 34
        case .title: 28
        case .title2: 22
        case .title3: 20
        default: 17
        }
    }

    /// Registers the bundled fonts once per process (thread-safe lazy static).
    public static func registerFonts() { _ = fontRegistration }

    private static let fontRegistration: Bool = {
        let urls = (Bundle.module.urls(forResourcesWithExtension: "ttf", subdirectory: nil) ?? [])
            + (Bundle.module.urls(forResourcesWithExtension: "ttf", subdirectory: "Fonts") ?? [])
        for url in urls {
            _ = CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
        return !urls.isEmpty
    }()
}

/// Multi-line display title at the design's line height (1.12 em). Charis SIL's own line height
/// is 1.64 em and SwiftUI can't set a negative line spacing, so the lines are stacked instead.
struct DisplayTitle: View {
    let lines: [Text]
    let size: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: size * (1.12 - 1.64)) {
            ForEach(lines.indices, id: \.self) { lines[$0] }
        }
        .accessibilityElement(children: .combine)
    }
}

struct CardStyle: ViewModifier {
    var tint: Color? = nil
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint ?? .clear, in: .rect(cornerRadius: 28))
            .overlay(RoundedRectangle(cornerRadius: 28).strokeBorder(CG.hairline))
    }
}

extension View {
    func cgCard(tint: Color? = nil) -> some View { modifier(CardStyle(tint: tint)) }
}

/// Filled pill button (primary action).
struct PillButtonStyle: ButtonStyle {
    var fill: Color = CG.cardinal
    var foreground: Color = .white
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(CG.sans(15, .semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .background(fill.opacity(configuration.isPressed ? 0.85 : 1), in: .capsule)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

/// Italic serif text link ("It's me", "passive ⟶").
struct SerifLinkStyle: ButtonStyle {
    var underline = true
    var size: CGFloat = 26
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(CG.serifItalic(size))
            .underline(underline)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .contentShape(.rect)
    }
}
