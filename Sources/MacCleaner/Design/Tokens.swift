import AppKit
import SwiftUI

// Design tokens. Views use these names only.

extension ShapeStyle where Self == Color {
    static var bgContent: Color { Color(nsColor: .controlBackgroundColor) }
    static var windowBackground: Color { Color(nsColor: .windowBackgroundColor) }
    /// Cards: a light gray lift in light mode (the window is white there), the control background in dark mode.
    static var cardFill: Color {
        .dynamic(light: NSColor.black.withAlphaComponent(0.035), dark: .controlBackgroundColor)
    }

    static var textPrimary: Color { Color(nsColor: .labelColor) }
    /// System secondaryLabel is ~3.9:1 in light mode; black 60% reaches 4.9:1 on the window background.
    static var textSecondary: Color {
        .dynamic(light: NSColor.black.withAlphaComponent(0.6), dark: .secondaryLabelColor)
    }

    static var safeIcon: Color { .dynamic(light: NSColor(hex: 0x1F7A36), dark: NSColor(hex: 0x4CD964)) }
    static var reviewIcon: Color { .dynamic(light: NSColor(hex: 0xA65A00), dark: NSColor(hex: 0xFFB340)) }
    static var regenIcon: Color { .textSecondary }

    static var barUsed: Color {
        .dynamic(light: NSColor.black.withAlphaComponent(0.55), dark: NSColor.white.withAlphaComponent(0.55))
    }
    static var barFree: Color { Color(nsColor: .quaternaryLabelColor) }
    static var rowHover: Color { Color.primary.opacity(0.05) }
    /// Selected row in a custom list; text stays textPrimary on top of it.
    static var rowSelected: Color { Color.accentColor.opacity(0.18) }
}

enum Space {
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 20
    static let xxl: CGFloat = 28
}

enum Metrics {
    static let windowPadding = Space.xl
    static let rowHeight: CGFloat = 44
    /// Cards and grouped surfaces; macOS 26 uses rounder, more concentric corners.
    static var cardRadius: CGFloat {
        if #available(macOS 26, *) { 18 } else { 10 }
    }
    static var groupRadius: CGFloat { cardRadius }
    static let rowRadius: CGFloat = 8
    static let barHeight: CGFloat = 14
    static let barRadius: CGFloat = 4
    /// Segments are separated by a gap, so adjacent fills never rely on color contrast alone.
    static let barGap: CGFloat = 2
    static let swatchSize: CGFloat = 10
    static let swatchRadius: CGFloat = 2
    /// Size and count columns in overview rows, so figures line up across rows.
    static let sizeColumnMin: CGFloat = 72
    static let countColumnMin: CGFloat = 96
    /// Tables otherwise report all their rows as minimum height and push the window past the screen.
    static let tableMinHeight: CGFloat = 160
    static let searchFieldWidth: CGFloat = 220
    static let appListWidth: CGFloat = 240
    static let appIconSmall: CGFloat = 24
    static let appIconLarge: CGFloat = 64
    static let itemIcon: CGFloat = 28
    static let sidebarIcon: CGFloat = 22
    static let moduleCardMinWidth: CGFloat = 190
    static let moduleCardMinHeight: CGFloat = 150
    static let contentMaxWidth: CGFloat = 880
    static let minWindow = CGSize(width: 900, height: 600)
}

enum Motion {
    static let barResize = Animation.easeInOut(duration: 0.35)
    /// Opacity of figures that are being recalculated.
    static let staleOpacity = 0.4
}

private extension Color {
    static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }
}

private extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: 1)
    }
}
