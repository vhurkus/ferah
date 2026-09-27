import SwiftUI

// Liquid Glass on macOS 26 and later, the equivalent system materials before.
// Glass is only for the control layer (toolbar, floating action bar); content sits on plain surfaces.

extension View {
    /// A rounded content surface: cards, notices, grouped rows.
    func surface(cornerRadius: CGFloat = Metrics.cardRadius, isHighlighted: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return background(.cardFill, in: shape)
            .overlay(shape.fill(isHighlighted ? Color.rowHover : .clear))
            .overlay(shape.strokeBorder(.separator.opacity(0.6)))
    }

    /// Floating bar that holds a screen's primary action.
    @ViewBuilder func floatingBar() -> some View {
        if #available(macOS 26, *) {
            padding(.horizontal, Space.l)
                .padding(.vertical, Space.s)
                .glassEffect(.regular, in: .capsule)
                .padding(.horizontal, Metrics.windowPadding)
                .padding(.bottom, Space.l)
                .padding(.top, Space.xl)
                // Fades the list out under the bar so its text never competes with the bar's.
                .background {
                    LinearGradient(
                        stops: [.init(color: .clear, location: 0), .init(color: .windowBackground, location: 0.55)],
                        startPoint: .top, endPoint: .bottom
                    )
                    .allowsHitTesting(false)
                }
        } else {
            padding(.horizontal, Metrics.windowPadding)
                .padding(.vertical, Space.m)
                .background(.bar)
                .overlay(alignment: .top) { Divider() }
        }
    }

    @ViewBuilder func prominentButtonStyle() -> some View {
        if #available(macOS 26, *) {
            buttonStyle(.glassProminent)
        } else {
            buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder func secondaryButtonStyle() -> some View {
        if #available(macOS 26, *) {
            buttonStyle(.glass)
        } else {
            buttonStyle(.bordered)
        }
    }
}

/// A symbol on a tinted rounded square, like System Settings' sidebar icons.
struct IconTile: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 28

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(tint.gradient, in: RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// Big figures (sizes) in the rounded system design, animating as they change.
struct FigureText: View {
    let text: Text
    var size: CGFloat = 34

    var body: some View {
        text
            .font(.system(size: size, weight: .bold, design: .rounded))
            .monospacedDigit()
            .contentTransition(.numericText())
    }
}
