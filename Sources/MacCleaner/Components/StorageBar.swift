import CleanerCore
import SwiftUI

/// Used / removable / free, drawn to scale. `removable` is nil until a scan finishes and
/// only covers items that are rebuilt automatically or safe; review items are never counted.
struct StorageBar: View {
    let volume: VolumeInfo
    let removable: Int64?
    /// A rescan is running, so the removable figure is out of date.
    var isStale = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    private var removableBytes: Int64 { min(removable ?? 0, volume.usedBytes) }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            bar
            legend
        }
        .opacity(isStale ? Motion.staleOpacity : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isImage)
        .accessibilityLabel(Text("Storage"))
        .accessibilityValue(accessibilityValue)
    }

    private var bar: some View {
        GeometryReader { proxy in
            let total = Double(max(volume.totalBytes, 1))
            let gaps = Metrics.barGap * (removableBytes > 0 ? 2 : 1)
            let width = max(0, proxy.size.width - gaps)
            HStack(spacing: Metrics.barGap) {
                segment(.barUsed, width: width * Double(volume.usedBytes - removableBytes) / total)
                if removableBytes > 0 {
                    segment(.accentColor, width: width * Double(removableBytes) / total)
                }
                segment(.barFree, width: nil)
            }
        }
        .frame(height: Metrics.barHeight)
        .animation(reduceMotion ? nil : Motion.barResize, value: removableBytes)
    }

    private func segment(_ color: Color, width: CGFloat?) -> some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.barRadius)
        return shape
            .fill(color)
            // Increase Contrast: outline every segment so edges don't depend on fill contrast.
            .overlay(shape.strokeBorder(contrast == .increased ? Color.primary : .clear, lineWidth: 1))
            .frame(width: width.map { max($0, 0) })
            .frame(maxWidth: width == nil ? .infinity : nil)
    }

    private var legend: some View {
        HStack(spacing: Space.l) {
            LegendItem(color: .barUsed, text: Text("Used"))
            if let removable {
                LegendItem(color: .accentColor, text: Text("Removable \(removable.byteString)"))
            }
            LegendItem(color: .barFree, text: Text("Free \(volume.availableBytes.byteString)"))
        }
        .font(.callout)
        .monospacedDigit()
    }

    private var accessibilityValue: Text {
        let used = volume.usedBytes.byteString, free = volume.availableBytes.byteString
        if let removable {
            return Text("\(used) used, \(free) free, \(removable.byteString) removable")
        }
        return Text("\(used) used, \(free) free")
    }
}

private struct LegendItem: View {
    let color: Color
    let text: Text

    var body: some View {
        HStack(spacing: Space.s) {
            RoundedRectangle(cornerRadius: Metrics.swatchRadius)
                .fill(color)
                .frame(width: Metrics.swatchSize, height: Metrics.swatchSize)
            text.foregroundStyle(.textSecondary)
        }
    }
}
