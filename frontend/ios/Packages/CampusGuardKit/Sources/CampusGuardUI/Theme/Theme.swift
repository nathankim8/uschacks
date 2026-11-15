import SwiftUI

/// Campus Guard visual language (from the Figma frames 1-6): warm white page, cardinal red,
/// serif display type (Charis SIL on the web; the system serif here) and SF for body text.
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

    public static func display(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }

    /// Scales with Dynamic Type while keeping the Figma proportions.
    public static func displayStyle(_ style: Font.TextStyle, weight: Font.Weight = .bold) -> Font {
        .system(style, design: .serif).weight(weight)
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
            .font(.subheadline.weight(.semibold))
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
            .font(.system(size: size, design: .serif).italic())
            .underline(underline)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .contentShape(.rect)
    }
}
