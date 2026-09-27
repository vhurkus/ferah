import CleanerCore
import SwiftUI

/// One module on the overview. The whole card opens the module.
struct ModuleCard: View {
    let kind: ModuleKind
    let result: ModuleResult?
    let isScanning: Bool
    let open: () -> Void

    @ViewState private var isHovered = false

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: Space.m) {
                HStack(alignment: .top) {
                    IconTile(symbol: kind.symbol, tint: kind.tint, size: 36)
                    Spacer()
                    if isScanning {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel(Text("Scanning"))
                    } else {
                        Image(systemName: "chevron.forward")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.textSecondary)
                            .accessibilityHidden(true)
                    }
                }
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text(kind.title)
                        .font(.headline)
                        .foregroundStyle(.textPrimary)
                    figures
                }
                Spacer(minLength: 0)
                SafetyLabelSummary(kind: kind, result: result, axis: .vertical)
            }
            .padding(Space.l)
            .frame(maxWidth: .infinity, minHeight: Metrics.moduleCardMinHeight, alignment: .topLeading)
            .contentShape(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
            .surface(isHighlighted: isHovered)
            .scaleEffect(isHovered ? 1.015 : 1)
            .animation(.snappy(duration: 0.2), value: isHovered)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder private var figures: some View {
        if let result, result.items.isEmpty {
            Text("Nothing found").foregroundStyle(.textSecondary)
        } else if let result {
            HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                if kind.isSized {
                    FigureText(text: Text(result.totalBytes.byteString), size: 22)
                        .foregroundStyle(.textPrimary)
                }
                kind.countText(result.items.count)
                    .foregroundStyle(.textSecondary)
            }
            .opacity(isScanning ? Motion.staleOpacity : 1)
        } else {
            Text("Not scanned").foregroundStyle(.textSecondary)
        }
    }
}
