import CleanerCore
import SwiftUI

/// First-run screen of a module: what it looks at, how safe that is, and one clear way to start.
/// A glass card over a soft glow in the module's color (a plain material card before macOS 26).
struct EmptyStateHero: View {
    let symbol: String
    let tint: Color
    let title: Text
    let message: Text
    /// Where the module looks, shown as chips.
    var places: [LocalizedStringKey] = []
    var labels: [SafetyLabel] = []
    let actionTitle: LocalizedStringKey
    var isWorking = false
    let action: () -> Void

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack {
            if !reduceTransparency {
                AmbientGlow(tint: tint)
            }
            card
                .padding(Metrics.windowPadding)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var card: some View {
        VStack(spacing: Space.l) {
            IconTile(symbol: symbol, tint: tint, size: 72)
                .shadow(color: tint.opacity(0.45), radius: 18, y: 8)
            VStack(spacing: Space.s) {
                title
                    .font(.system(.title, design: .rounded, weight: .bold))
                message
                    .font(.body)
                    .foregroundStyle(.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
            if !places.isEmpty {
                ChipFlow(places: places)
            }
            if !labels.isEmpty {
                HStack(spacing: Space.l) {
                    ForEach(labels, id: \.self) { SafetyLabelView(label: $0) }
                }
            }
            Button(action: action) {
                HStack(spacing: Space.s) {
                    if isWorking {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "sparkle.magnifyingglass")
                    }
                    Text(actionTitle)
                }
                .padding(.horizontal, Space.l)
            }
            .prominentButtonStyle()
            .controlSize(.extraLarge)
            .disabled(isWorking)
            .padding(.top, Space.xs)
        }
        .padding(.horizontal, Space.xxl + Space.l)
        .padding(.vertical, Space.xxl + Space.s)
        .frame(maxWidth: 560)
        .heroCard()
    }
}

/// Soft, blurred color behind the card, so the glass has something to refract.
private struct AmbientGlow: View {
    let tint: Color

    /// A second hue next to the tint on the color wheel, so the glow never reads as one flat color.
    static func companion(of tint: Color) -> Color {
        switch tint {
        case .blue: .purple
        case .purple: .pink
        case .orange: .pink
        case .teal: .blue
        case .indigo: .teal
        case .green: .teal
        default: .accentColor
        }
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(tint.opacity(0.6))
                .frame(width: 420, height: 420)
                .offset(x: -180, y: -90)
            Circle()
                .fill(Self.companion(of: tint).opacity(0.45))
                .frame(width: 380, height: 380)
                .offset(x: 200, y: 110)
            Circle()
                .fill(tint.opacity(0.35))
                .frame(width: 260, height: 260)
                .offset(x: 140, y: -160)
        }
        .blur(radius: 80)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Where a module looks, as small capsules that wrap onto more lines when needed.
private struct ChipFlow: View {
    let places: [LocalizedStringKey]

    var body: some View {
        FlowLayout(spacing: Space.s) {
            ForEach(Array(places.enumerated()), id: \.offset) { _, place in
                Text(place)
                    .font(.callout)
                    .padding(.horizontal, Space.m)
                    .padding(.vertical, Space.xs + Space.xxs)
                    .background(Color.primary.opacity(0.07), in: Capsule())
            }
        }
        .frame(maxWidth: 460)
    }
}

/// Lays children out left to right, wrapping to a new centered line when a row is full.
private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(for: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(rows.count - 1, 0))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(for: bounds.width, subviews: subviews) {
            var x = bounds.midX - row.width / 2
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: .unspecified)
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(for maxWidth: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let extra = rows[rows.count - 1].indices.isEmpty ? size.width : size.width + spacing
            if rows[rows.count - 1].width + extra > maxWidth, !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
            }
            let isFirst = rows[rows.count - 1].indices.isEmpty
            rows[rows.count - 1].indices.append(index)
            rows[rows.count - 1].width += isFirst ? size.width : size.width + spacing
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
        }
        return rows
    }
}

extension View {
    /// The hero card: Liquid Glass on macOS 26+, a thick blurred material before.
    @ViewBuilder func heroCard() -> some View {
        let shape = RoundedRectangle(cornerRadius: 28, style: .continuous)
        if #available(macOS 26, *) {
            glassEffect(.regular, in: shape)
        } else {
            background(.regularMaterial, in: shape)
                .overlay(shape.strokeBorder(.separator.opacity(0.6)))
                .shadow(color: .black.opacity(0.15), radius: 24, y: 12)
        }
    }
}
