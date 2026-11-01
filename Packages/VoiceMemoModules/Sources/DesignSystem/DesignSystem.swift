import SwiftUI

/// Semantic colors from Atmospheric Graphite 1.0.
public enum YoinTheme {
    public static func background(_ scheme: ColorScheme) -> Color { scheme == .dark ? color(0x221C2C) : color(0xEAF3F6) }
    public static func surface(_ scheme: ColorScheme) -> Color { scheme == .dark ? color(0x302838) : color(0xFFFFFF) }
    public static func raised(_ scheme: ColorScheme) -> Color { scheme == .dark ? color(0x3B3444) : color(0xF4F7F6) }
    public static func text(_ scheme: ColorScheme) -> Color { scheme == .dark ? color(0xF6F0EB) : color(0x20282B) }
    public static func secondary(_ scheme: ColorScheme) -> Color { scheme == .dark ? color(0xCAC0D4) : color(0x4F626B) }
    public static func action(_ scheme: ColorScheme) -> Color { scheme == .dark ? color(0xB9A1DE) : color(0x235F75) }
    public static func onAction(_ scheme: ColorScheme) -> Color { scheme == .dark ? color(0x221C2C) : color(0xFFFFFF) }
    public static let accent = color(0xD8F15A)

    private static func color(_ hex: UInt) -> Color {
        Color(red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255, blue: Double(hex & 0xff) / 255)
    }
}

/// Resolves the tint inside the view hierarchy so appearance changes are observed.
public struct YoinTint: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    public init() {}
    public func body(content: Content) -> some View {
        content.tint(YoinTheme.action(scheme))
    }
}
